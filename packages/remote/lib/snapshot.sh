#!/usr/bin/env bash
# snapshot.sh — mirror local state files to a remote workspace
#
# Why this exists: Mac log files (~/.claude/logs/*.jsonl, ~/.noglaze/audit.jsonl)
# are NOT in dotfiles git sync. A remote validator agent reading them must use
# a snapshot. This rsyncs the configured paths to <remote>:~/cc-remote-state/.
#
# Configurable via task.conf SNAPSHOT_PATHS array, with sensible defaults.

cmd_snapshot() {
  local task_conf="${1:-}"

  # Defaults (work without a task.conf for the basic case)
  local REMOTE="${REMOTE:-remote-host}"
  local REMOTE_STATE_DIR="${REMOTE_STATE_DIR:-cc-remote-state}"
  local SNAPSHOT_PATHS=(
    "$HOME/.claude/logs/hook-fires.jsonl"
    "$HOME/.claude/logs/enforcement.jsonl"
    "$HOME/.claude/logs/cc-live-brief.log"
    "$HOME/.noglaze/audit.jsonl"
  )

  if [[ -n "$task_conf" && -f "$task_conf" ]]; then
    # shellcheck disable=SC1090
    source "$task_conf"
  fi

  # Filter to existing files only — missing logs are not errors
  local existing=()
  local p
  for p in "${SNAPSHOT_PATHS[@]}"; do
    [[ -f "$p" ]] && existing+=("$p")
  done

  if [[ "${#existing[@]}" -eq 0 ]]; then
    echo "[snapshot] no source files found — skipping" >&2
    return 0
  fi

  ssh "$REMOTE" "mkdir -p ~/$REMOTE_STATE_DIR" || {
    echo "[snapshot] ERROR: cannot reach $REMOTE" >&2
    return 1
  }

  rsync -avz --no-perms --no-owner --no-group \
    "${existing[@]}" \
    "$REMOTE:$REMOTE_STATE_DIR/" 2>&1 | tail -5

  echo "[snapshot] OK — ${#existing[@]} file(s) mirrored to $REMOTE:~/$REMOTE_STATE_DIR/"
}
