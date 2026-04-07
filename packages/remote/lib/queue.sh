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
#   claude-code-remote pull-queue [--remote remote-host] [--auto]
#
#     --remote <name>   Override REMOTE (default: read from REMOTE env or
#                       fall back to "remote-host")
#     --auto            Quiet mode: no prompts, exit 0 if nothing to pull
#                       (suitable for cron / launchd)

# Helper: queue path resolution
_queue_path_remote() {
  # Returns the queue path string suitable for use inside _ccr_run "..." (the
  # remote shell will expand $HOME if REMOTE != local; locally we pass the
  # already-expanded path)
  if [[ "${REMOTE:-}" == "local" ]]; then
    echo "$HOME/cc-remote-output/.completion-queue.jsonl"
  else
    echo '$HOME/cc-remote-output/.completion-queue.jsonl'
  fi
}

# Helper: pull the queue file from the remote to a local temp file.
# Echoes the local temp path on success, returns nonzero if the queue is empty
# or missing.
_queue_pull_to_temp() {
  local remote_path="$1"
  local local_tmp
  local_tmp=$(mktemp -t cc-queue-XXXXXX)
  if ! _ccr_run "test -f $remote_path && cat $remote_path" > "$local_tmp" 2>/dev/null; then
    rm -f "$local_tmp"
    return 1
  fi
  if [[ ! -s "$local_tmp" ]]; then
    rm -f "$local_tmp"
    return 1
  fi
  echo "$local_tmp"
}

# Helper: push a local file to the remote queue path (overwrite).
_queue_push_from_temp() {
  local local_tmp="$1"
  local remote_path="$2"
  cat "$local_tmp" | _ccr_write "${remote_path#\$HOME/}"
}

# Helper: mark a queue entry pulled=true. Safe against any name (jq runs
# locally with proper --arg, no shell quoting in the filter).
_queue_mark_pulled() {
  local name="$1"
  local rpath
  rpath=$(_queue_path_remote)
  local local_tmp
  local_tmp=$(_queue_pull_to_temp "$rpath") || return 0  # nothing to mark
  local out_tmp
  out_tmp=$(mktemp -t cc-queue-out-XXXXXX)
  jq -c --arg n "$name" 'if .name == $n then .pulled = true else . end' \
    "$local_tmp" > "$out_tmp"
  _queue_push_from_temp "$out_tmp" "$rpath"
  rm -f "$local_tmp" "$out_tmp"
}

# Helper: remove all queue entries matching a given name. Used by recover.sh
# before retrying a task to prevent duplicate entries from accumulating.
_queue_remove_name() {
  local name="$1"
  local rpath
  rpath=$(_queue_path_remote)
  local local_tmp
  local_tmp=$(_queue_pull_to_temp "$rpath") || return 0
  local out_tmp
  out_tmp=$(mktemp -t cc-queue-out-XXXXXX)
  jq -c --arg n "$name" 'select(.name != $n)' "$local_tmp" > "$out_tmp"
  _queue_push_from_temp "$out_tmp" "$rpath"
  rm -f "$local_tmp" "$out_tmp"
}

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

  REMOTE="${remote_override:-${REMOTE:-remote-host}}"
  local rpath
  rpath=$(_queue_path_remote)

  # Pull the queue file to a local temp for safe processing
  local local_tmp
  if ! local_tmp=$(_queue_pull_to_temp "$rpath"); then
    if ! $auto_mode; then
      echo "[pull-queue] empty queue on $REMOTE — nothing to pull"
    fi
    return 0
  fi

  # Find entries with pulled=false (jq runs locally on the temp file)
  local unpulled_names
  unpulled_names=$(jq -r 'select(.pulled == false) | .name' "$local_tmp" 2>/dev/null)

  if [[ -z "$unpulled_names" ]]; then
    if ! $auto_mode; then
      echo "[pull-queue] all entries already pulled — nothing to do"
    fi
    rm -f "$local_tmp"
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
      _queue_mark_pulled "$n"
    else
      failed_count=$((failed_count + 1))
      echo "[pull-queue]   FAILED $n (will retry next pull-queue)"
    fi
  done <<< "$unpulled_names"

  rm -f "$local_tmp"
  echo "[pull-queue] done — $pulled_count pulled, $failed_count failed"
  return 0
}
