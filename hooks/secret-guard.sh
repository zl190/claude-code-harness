#!/usr/bin/env bash
# secret-guard.sh — PreToolUse hook: blocks commands that would expose secrets
# Tier 1: deny (permissionDecision). Tier 2: additionalContext warning.
# Session 20: created after repeated API key leaks via tail/cat/ssh on rc files.
set -uo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# Log fire
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg tool "$TOOL_NAME" \
  '{ts: $ts, hook: "secret-guard", tool: $tool}' \
  >> ~/.claude/logs/hook-fires.jsonl 2>/dev/null

# Guard: only Bash, must have command
[[ "$TOOL_NAME" != "Bash" ]] && exit 0
[[ -z "$COMMAND" ]] && exit 0

# ── TIER 1: Deny patterns (high confidence leak) ──
deny_reason=""

# Direct env var echo: echo $API_KEY, echo $TOKEN, etc.
if echo "$COMMAND" | grep -qiE 'echo[[:space:]].*\$[A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD|PASS|API_KEY|AUTH|CREDENTIAL)'; then
  deny_reason="echo of secret env var would display its value"

# cat/tail/head on dotenv and credential files
elif echo "$COMMAND" | grep -qE '(cat|tail|head|less|more|bat)[[:space:]].*(/\.env(\.[a-z]+)?$|/credentials|/\.netrc|/\.pgpass|\.aws/credentials|\.aws/config|/api_key|\.ssh/id_(rsa|ed25519|ecdsa)([^.]|$)|/\.npmrc|/\.pypirc|docker/config\.json)'; then
  deny_reason="reading a credential file would expose secrets"

# printenv or env with no args (full env dump)
elif echo "$COMMAND" | grep -qE '(^|;|&&|\|\|)[[:space:]]*(printenv|env)[[:space:]]*($|\||;|&&)'; then
  deny_reason="env/printenv dumps all variables including secrets"

# env/printenv piped to grep for key-like terms
elif echo "$COMMAND" | grep -qiE '(printenv|env)[[:space:]]*\|.*grep.*(KEY|TOKEN|SECRET|API|AUTH|PASS)'; then
  deny_reason="piping env to grep for secrets would display their values"

# export -p
elif echo "$COMMAND" | grep -qE 'export[[:space:]]+-p'; then
  deny_reason="export -p dumps all exported variables including secrets"

# diff on .env files
elif echo "$COMMAND" | grep -qE 'diff[[:space:]].*\.env'; then
  deny_reason="diff on .env files would display all secrets"

# SSH remote commands reading env/dotenv/credentials
elif echo "$COMMAND" | grep -qE "ssh[[:space:]].*['\"].*((cat|tail|head)[[:space:]].*(\\.env|\\.bashrc|\\.zshrc|api_key|credentials)|echo[[:space:]]*\\\$|printenv|env[[:space:]]*\|)"; then
  deny_reason="SSH remote command would expose secrets from remote host"

# Python/Node env dumps
elif echo "$COMMAND" | grep -qE '(python|python3|node)[[:space:]]+-[ce][[:space:]].*(\bos\.environ\b|\bprocess\.env\b)'; then
  deny_reason="language one-liner would dump all environment variables"
fi

if [[ -n "$deny_reason" ]]; then
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$deny_reason" \
    '{ts: $ts, hook: "secret-guard", verdict: "DENY", reason: $reason}' \
    >> ~/.claude/logs/enforcement.jsonl 2>/dev/null

  jq -n --arg reason "$deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Secret guard BLOCKED: " + $reason + ". Safe alternatives: [ -n \"$VAR\" ] && echo \"set (${#VAR} chars)\"; grep -c PATTERN file; ls -la path.")
    }
  }'
  exit 0
fi

# ── TIER 2: Warn but allow ──
warn_msg=""

# grep for key-like patterns in config files
if echo "$COMMAND" | grep -qiE 'grep[[:space:]]+.*(KEY|TOKEN|SECRET|API).*(\.env|\.cfg|\.conf|\.ini|\.json($|[^l])|\.ya?ml)'; then
  warn_msg="grep may display secret values — use grep -c to count or grep -l to list files"

# Reading shell rc files (often contain exported secrets)
elif echo "$COMMAND" | grep -qE '(cat|tail|head)[[:space:]].*(\.bashrc|\.zshrc|\.bash_profile|\.zprofile|\.profile)'; then
  warn_msg="shell RC files often contain exported secrets — use specific grep instead of reading full file"
fi

if [[ -n "$warn_msg" ]]; then
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{ts: $ts, hook: "secret-guard", verdict: "WARN"}' \
    >> ~/.claude/logs/enforcement.jsonl 2>/dev/null

  jq -n --arg msg "$warn_msg" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: ("Secret guard WARNING: " + $msg)
    }
  }'
fi

exit 0
