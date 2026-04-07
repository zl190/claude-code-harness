#!/usr/bin/env bash
# secret-guard-smoke.sh — minimum viable smoke test
#
# Runs the secret-guard hook directly against 4 inputs and confirms the
# expected verdicts. Does NOT touch your Claude Code installation. Safe to run
# without installing claude-code-harness — uses the in-repo copy of the hook.
#
# Exits 0 on all-pass, 1 on any failure.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_DIR}/hooks/secret-guard.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable at $HOOK" >&2
  exit 1
fi

PASS=0
FAIL=0

assert_deny() {
  local label="$1"
  local cmd="$2"
  local input
  input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")
  local out
  out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s — expected deny, got: %s\n' "$label" "$out"
    FAIL=$((FAIL+1))
  fi
}

assert_pass() {
  local label="$1"
  local cmd="$2"
  local input
  input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")
  local out
  out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf '  FAIL  %s — expected pass, got deny\n' "$label"
    FAIL=$((FAIL+1))
  else
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  fi
}

assert_warn() {
  local label="$1"
  local cmd="$2"
  local input
  input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")
  local out
  out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | jq -e '(.hookSpecificOutput.additionalContext // "") | contains("Secret guard WARNING")' >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s — expected WARN, got: %s\n' "$label" "${out:-<empty>}"
    FAIL=$((FAIL+1))
  fi
}

assert_no_warn() {
  local label="$1"
  local cmd="$2"
  local input
  input=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$cmd" | jq -Rs .)")
  local out
  out=$(printf '%s' "$input" | "$HOOK" 2>/dev/null)
  # Pass if output is empty OR has no additionalContext OR additionalContext is empty
  local has_warn
  has_warn=$(printf '%s' "$out" | jq -e '(.hookSpecificOutput.additionalContext // "") | contains("Secret guard WARNING")' 2>/dev/null && echo yes || echo no)
  if [[ "$has_warn" == "no" ]]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s — expected no WARN, got WARN\n' "$label"
    FAIL=$((FAIL+1))
  fi
}

echo "claude-code-harness secret-guard smoke test"
echo "================================="
echo

# Should DENY
assert_deny "echo of API key env var" 'echo $ANTHROPIC_API_KEY'
assert_deny "cat .env file"            'cat ~/.env'
assert_deny "printenv with no args"    'printenv'
assert_deny "export -p dump"           'export -p'

# Should PASS (not block)
assert_pass "harmless ls"              'ls -la /tmp'
assert_pass "git status"               'git status'

# WARN tier
assert_warn    "cat shell rc file (legit WARN)" 'cat ~/.bashrc'
assert_no_warn "grep on .jsonl log file (FP fix)" 'grep "secret" /tmp/foo.jsonl'

# Idempotency: same input twice = same verdict
echo
echo "idempotency check"
echo "-----------------"
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo $API_KEY"}}'
R1=$(printf '%s' "$INPUT" | "$HOOK" 2>/dev/null)
R2=$(printf '%s' "$INPUT" | "$HOOK" 2>/dev/null)
if [[ "$R1" == "$R2" ]]; then
  printf '  PASS  same input -> same verdict\n'
  PASS=$((PASS+1))
else
  printf '  FAIL  idempotency violation\n'
  FAIL=$((FAIL+1))
fi

echo
echo "================================="
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
