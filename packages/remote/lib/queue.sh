#!/usr/bin/env bash
# queue.sh — completion queue management
#
# Phase G of v0.5: when a delegated task finishes on remote, the runner appends
# a record to ~/cc-remote-output/.completion-queue.jsonl. This lets the local
# machine drain unrecovered results on demand (e.g., after waking from sleep,
# reconnecting from offline) without polling each task individually.
#
# Lifecycle:
#   - runner appends:    {"name":"X", "completed_at":..., "status":"success",
#                          "output_dir":"...", "pulled":false}
#   - cmd_pull_queue:    reads queue, finds entries with pulled=false, runs
#                        cmd_recover for each, marks pulled=true via in-place
#                        rewrite (using jq + atomic mv)
#   - prune (manual):    user can `claude-code-remote prune-queue` to drop
#                        old pulled entries (not implemented v0.5; manual jq)
#
# Usage:
#   claude-code-remote pull-queue [--remote myserver] [--auto]
#
#     --remote <name>   Override REMOTE (default: read from REMOTE env or
#                       fall back to "remote-host")
#     --auto            Quiet mode: no prompts, exit 0 if nothing to pull
#                       (suitable for cron / launchd)

cmd_pull_queue() {
  local remote_override=""
  local auto_mode=false

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) remote_override="$2"; shift 2 ;;
      --auto)   auto_mode=true; shift ;;
      *)        echo "[pull-queue] unknown arg: $1" >&2; return 1 ;;
    esac
  done

  local REMOTE="${remote_override:-${REMOTE:-remote-host}}"

  # Read the queue file from the remote
  local queue_path
  if [[ "$REMOTE" == "local" ]]; then
    queue_path="$HOME/cc-remote-output/.completion-queue.jsonl"
  else
    queue_path='$HOME/cc-remote-output/.completion-queue.jsonl'
  fi

  local queue_content
  queue_content=$(_ccr_run "test -f $queue_path && cat $queue_path || echo")

  if [[ -z "$queue_content" ]]; then
    if ! $auto_mode; then
      echo "[pull-queue] empty queue on $REMOTE — nothing to pull"
    fi
    return 0
  fi

  # Find entries with pulled=false
  local unpulled_names
  unpulled_names=$(echo "$queue_content" | jq -r 'select(.pulled == false) | .name' 2>/dev/null)

  if [[ -z "$unpulled_names" ]]; then
    if ! $auto_mode; then
      echo "[pull-queue] all entries already pulled — nothing to do"
    fi
    return 0
  fi

  local total_unpulled
  total_unpulled=$(echo "$unpulled_names" | wc -l | tr -d ' ')
  echo "[pull-queue] $total_unpulled entry(ies) to pull from $REMOTE"

  local pulled_count=0
  local failed_count=0
  local n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    echo "[pull-queue]   pulling $n..."
    if cmd_recover "$n"; then
      pulled_count=$((pulled_count + 1))
      # Mark as pulled in the remote queue file (in-place rewrite via jq)
      _ccr_run "jq -c --arg n '$n' 'if .name == \$n then .pulled = true else . end' $queue_path > $queue_path.tmp && mv $queue_path.tmp $queue_path"
    else
      failed_count=$((failed_count + 1))
      echo "[pull-queue]   FAILED $n (will retry next pull-queue)"
    fi
  done <<< "$unpulled_names"

  echo "[pull-queue] done — $pulled_count pulled, $failed_count failed"
  return 0
}
