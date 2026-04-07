#!/usr/bin/env bash
# claude-code-harness installer
#
# Idempotent local install. Copies harness hooks into the user's Claude Code
# config tree, then merges hook entries into settings.json without clobbering
# existing hooks.
#
# v0.0 ships exactly one hook: secret-guard (PreToolUse Bash).
#
# Usage:
#   ./install.sh             Install or repair (idempotent — safe to re-run).
#   ./install.sh --uninstall Remove installed hooks. Preserves user state.
#   ./install.sh --help      Show this message.
#
# Scope: pure local install. No network, no telemetry, no auto-update.
#
# Safety:
#   - set -euo pipefail
#   - settings.json is backed up to settings.json.bak.<unix-ts> before any edit
#   - jq merges are written to a temp file then atomically renamed
#   - Any failure mid-write rolls back to the latest backup
#   - Re-running is a no-op (string-equal dedupe on the hook command)

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────────

readonly KIT_NAME="claude-code-harness"
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Respect XDG-style relocation if user set CLAUDE_CONFIG_DIR.
CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
readonly CLAUDE_HOME

readonly INSTALL_DIR="${CLAUDE_HOME}/scripts/${KIT_NAME}"
readonly SETTINGS_FILE="${CLAUDE_HOME}/settings.json"
readonly LOG_DIR="${CLAUDE_HOME}/logs"

# Hook definitions: each entry = "EVENT|MATCHER|HOOK_FILENAME|INSTALL_NAME"
# v0.0 ships one hook. Add more here as their validation cards reach
# SHIPPING_READY (see evidence/ for the audit method).
HOOKS=(
  "PreToolUse|Bash|secret-guard.sh|secret-guard.sh"
)

# ──────────────────────────────────────────────────────────────────────────────
# Pretty output
# ──────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""; C_RESET=""
fi
readonly C_RED C_GREEN C_YELLOW C_BLUE C_DIM C_RESET

info()  { printf '%s[info]%s    %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[ok]%s      %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[warn]%s    %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[error]%s   %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
fatal() { err "$*"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Rollback state
# ──────────────────────────────────────────────────────────────────────────────

LATEST_BACKUP=""

rollback_settings() {
  if [[ -n "$LATEST_BACKUP" && -f "$LATEST_BACKUP" ]]; then
    warn "Rolling back settings.json from ${LATEST_BACKUP}"
    cp "$LATEST_BACKUP" "$SETTINGS_FILE"
  fi
}

on_error() {
  local exit_code=$?
  err "Operation failed (exit ${exit_code}). See messages above."
  rollback_settings
  exit "$exit_code"
}

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────────

check_prereqs() {
  case "$(uname -s)" in
    Darwin|Linux) ;;
    *) fatal "Unsupported OS: $(uname -s). claude-code-harness supports macOS and Linux. On Windows, use WSL." ;;
  esac

  command -v jq >/dev/null 2>&1 || fatal "jq is required but not found. Install with: brew install jq  (macOS) or apt install jq (Debian/Ubuntu)"

  # Bash 3.2 (macOS default) is sufficient — install.sh uses only POSIX-ish
  # features (indexed arrays, herestrings, [[ ]], (( )), case/esac).
  # Earlier versions of this script required bash 4+ defensively; that
  # requirement was wrong and made the installer fail on stock macOS.
  # If you add features that need 4+, gate them and re-add a version check.

  if [[ ! -d "$CLAUDE_HOME" ]]; then
    fatal "Claude Code config directory not found at ${CLAUDE_HOME}. Install Claude Code first: https://claude.com/claude-code"
  fi

  ok "prereqs OK (OS, jq, bash, claude config dir)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Backup
# ──────────────────────────────────────────────────────────────────────────────

backup_settings() {
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    info "No existing ${SETTINGS_FILE} — will create a fresh one"
    echo '{}' > "$SETTINGS_FILE"
    return
  fi

  local ts
  ts="$(date +%s)"
  LATEST_BACKUP="${SETTINGS_FILE}.bak.${ts}"
  cp "$SETTINGS_FILE" "$LATEST_BACKUP"
  ok "Backed up settings.json -> $(basename "$LATEST_BACKUP")"
}

# ──────────────────────────────────────────────────────────────────────────────
# Install hook scripts
# ──────────────────────────────────────────────────────────────────────────────

install_scripts() {
  mkdir -p "$INSTALL_DIR" "$LOG_DIR"

  local entry event matcher src dst
  for entry in "${HOOKS[@]}"; do
    IFS='|' read -r event matcher src dst <<< "$entry"
    local src_path="${REPO_DIR}/hooks/${src}"
    local dst_path="${INSTALL_DIR}/${dst}"

    if [[ ! -f "$src_path" ]]; then
      fatal "Source hook missing: ${src_path}"
    fi

    cp "$src_path" "$dst_path"
    chmod +x "$dst_path"
    ok "Installed ${dst} -> ${dst_path}"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Merge hooks into settings.json (jq-based, idempotent)
# ──────────────────────────────────────────────────────────────────────────────

merge_hook_into_settings() {
  local event="$1"
  local matcher="$2"
  local hook_command="$3"

  local tmp
  tmp="$(mktemp "${SETTINGS_FILE}.tmp.XXXXXX")"

  jq \
    --arg event "$event" \
    --arg matcher "$matcher" \
    --arg cmd "$hook_command" \
    '
    # Default .hooks and the event array if missing
    .hooks //= {} |
    .hooks[$event] //= [] |
    # Find the matcher group; create one if absent
    if (.hooks[$event] | map(select(.matcher == $matcher)) | length) == 0 then
      .hooks[$event] += [{"matcher": $matcher, "hooks": []}]
    else . end |
    # Within the matching group, dedupe by command and append
    .hooks[$event] |= map(
      if .matcher == $matcher then
        .hooks = ((.hooks // []) | map(select(.command != $cmd)) + [{"type": "command", "command": $cmd}])
      else . end
    )
    ' "$SETTINGS_FILE" > "$tmp"

  # Validate the result is parseable JSON before swap
  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fatal "jq merge produced invalid JSON. Aborting before write."
  fi

  mv "$tmp" "$SETTINGS_FILE"
}

merge_all_hooks() {
  local entry event matcher src dst hook_cmd
  for entry in "${HOOKS[@]}"; do
    IFS='|' read -r event matcher src dst <<< "$entry"
    hook_cmd="\$HOME/.claude/scripts/${KIT_NAME}/${dst}"
    merge_hook_into_settings "$event" "$matcher" "$hook_cmd"
    ok "Merged ${event}/${matcher} hook -> ${dst}"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# Uninstall
# ──────────────────────────────────────────────────────────────────────────────

remove_hook_from_settings() {
  local event="$1"
  local matcher="$2"
  local hook_command="$3"

  if [[ ! -f "$SETTINGS_FILE" ]]; then
    return
  fi

  local tmp
  tmp="$(mktemp "${SETTINGS_FILE}.tmp.XXXXXX")"

  jq \
    --arg event "$event" \
    --arg matcher "$matcher" \
    --arg cmd "$hook_command" \
    '
    if (.hooks // {})[$event] then
      .hooks[$event] |= (
        map(
          if .matcher == $matcher then
            .hooks = ((.hooks // []) | map(select(.command != $cmd)))
          else . end
        )
        # Drop matcher groups whose hooks list is now empty AND matcher is the v0 one we added
        | map(select(.matcher != $matcher or (.hooks | length) > 0))
      )
    else . end
    ' "$SETTINGS_FILE" > "$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fatal "jq removal produced invalid JSON. Aborting before write."
  fi

  mv "$tmp" "$SETTINGS_FILE"
}

uninstall() {
  info "Uninstalling ${KIT_NAME}…"
  trap on_error ERR
  backup_settings

  local entry event matcher src dst hook_cmd
  for entry in "${HOOKS[@]}"; do
    IFS='|' read -r event matcher src dst <<< "$entry"
    hook_cmd="\$HOME/.claude/scripts/${KIT_NAME}/${dst}"
    remove_hook_from_settings "$event" "$matcher" "$hook_cmd"
    ok "Removed ${event}/${matcher} hook entry"
  done

  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    ok "Removed installed scripts at ${INSTALL_DIR}"
  fi

  trap - ERR
  ok "${KIT_NAME} uninstalled"
  echo
  info "User state preserved: ${LOG_DIR} and ${SETTINGS_FILE} are untouched apart from the removed hook entry."
  info "If you want to remove the backup files: rm ${SETTINGS_FILE}.bak.*"
}

# ──────────────────────────────────────────────────────────────────────────────
# Install (main flow)
# ──────────────────────────────────────────────────────────────────────────────

install() {
  echo "${C_BLUE}══════════════════════════════════════════════════════${C_RESET}"
  echo "${C_BLUE}  claude-code-harness installer — pure local, no telemetry${C_RESET}"
  echo "${C_BLUE}══════════════════════════════════════════════════════${C_RESET}"
  echo

  trap on_error ERR

  check_prereqs
  backup_settings
  install_scripts
  merge_all_hooks

  trap - ERR
  echo
  ok "Installation complete."
  echo
  info "Hook installed: ${INSTALL_DIR}/secret-guard.sh"
  info "Backup at:      ${LATEST_BACKUP:-(no prior settings.json)}"
  info "Logs go to:     ${LOG_DIR}/ (existing dir, no new logs created)"
  echo
  info "Smoke test (in a Claude Code session):"
  echo "    echo \$ANTHROPIC_API_KEY"
  info "    Expected: PreToolUse blocks with a 'Secret guard BLOCKED' message."
  echo
  info "Read the evidence for the published precision number:"
  echo "    ${REPO_DIR}/evidence/secret-guard-validation.md"
  echo
  info "Uninstall any time:"
  echo "    ${REPO_DIR}/install.sh --uninstall"
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
  --uninstall|-u) uninstall ;;
  --help|-h)
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    ;;
  ""|--install|-i) install ;;
  *)
    err "Unknown argument: $1"
    err "Usage: $0 [--install|--uninstall|--help]"
    exit 1
    ;;
esac
