#!/usr/bin/env bash
# spawn.sh — start a remote task in a detached tmux session running `claude -p`
#
# Reads a task.conf (shell-source format, no YAML deps). Creates a remote
# input directory, scps prompt + attached files, then starts tmux running
# claude -p with the prompt. Records bookkeeping for status/recover.
#
# REMOTE=local mode: runs the same pipeline in a local tmux session instead
# of going over ssh. Transport helpers live in lib/_transport.sh.

cmd_spawn() {
  local task_conf="${1:-}"
  if [[ -z "$task_conf" || ! -f "$task_conf" ]]; then
    echo "[spawn] ERROR: task.conf path required and must exist" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$task_conf"

  : "${NAME:?task.conf must set NAME}"
  : "${REMOTE:=remote-host}"
  : "${PROMPT:?task.conf must set PROMPT (string) or PROMPT_FILE (path)}"
  # Optional extra args passed to `claude -p` (e.g. "--bare --permission-mode bypassPermissions")
  local CLAUDE_ARGS="${CLAUDE_ARGS:-}"

  local REMOTE_INPUT_DIR="${REMOTE_INPUT_DIR:-cc-remote-input/$NAME}"
  local REMOTE_OUTPUT_DIR="${REMOTE_OUTPUT_DIR:-cc-remote-output/$NAME}"
  local INPUTS=("${INPUTS[@]:-}")

  # If PROMPT_FILE set, read its content; otherwise use PROMPT inline.
  local effective_prompt
  if [[ -n "${PROMPT_FILE:-}" && -f "${PROMPT_FILE}" ]]; then
    effective_prompt="$(cat "$PROMPT_FILE")"
  else
    effective_prompt="$PROMPT"
  fi

  # Prepare remote dirs
  _ccr_run "mkdir -p ~/$REMOTE_INPUT_DIR ~/$REMOTE_OUTPUT_DIR" || {
    echo "[spawn] ERROR: cannot reach $REMOTE" >&2
    return 1
  }

  # Push input files
  if [[ "${#INPUTS[@]}" -gt 0 && -n "${INPUTS[0]}" ]]; then
    local existing=()
    local f
    for f in "${INPUTS[@]}"; do
      [[ -f "$f" ]] && existing+=("$f")
    done
    if [[ "${#existing[@]}" -gt 0 ]]; then
      _ccr_copy "$REMOTE_INPUT_DIR" "${existing[@]}"
    fi
  fi

  # Write the prompt to a file remote so we don't deal with shell quoting hell
  local prompt_file_remote="$REMOTE_INPUT_DIR/_prompt.txt"
  printf '%s' "$effective_prompt" | _ccr_write "$prompt_file_remote"

  # Build the runner script (lives in output dir alongside the run.log)
  local runner_remote="$REMOTE_OUTPUT_DIR/_runner.sh"
  _ccr_write "$runner_remote" <<RUNNER_EOF
#!/usr/bin/env bash
set -uo pipefail
LOG=\$HOME/$REMOTE_OUTPUT_DIR/run.log
echo "=== START \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "\$LOG"
echo "task: $NAME" >> "\$LOG"
claude -p $CLAUDE_ARGS "\$(cat \$HOME/$prompt_file_remote)" >> "\$LOG" 2>&1
echo "=== END \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "\$LOG"
echo DONE >> "\$LOG"
RUNNER_EOF
  _ccr_run "chmod +x ~/$runner_remote"

  # Start the tmux session
  _ccr_run "tmux new-session -d -s 'ccr-$NAME' '~/$runner_remote'" || {
    echo "[spawn] ERROR: tmux session start failed for ccr-$NAME" >&2
    return 1
  }

  echo "[spawn] OK — task '$NAME' started on $REMOTE (session: ccr-$NAME)"
  echo "[spawn]      monitor: claude-code-remote status"
  if [[ "$REMOTE" == "local" ]]; then
    echo "[spawn]      log:     tail -f ~/$REMOTE_OUTPUT_DIR/run.log"
  else
    echo "[spawn]      log:     ssh $REMOTE 'tail -f ~/$REMOTE_OUTPUT_DIR/run.log'"
  fi
}

cmd_attach() {
  local name="${1:-}"
  : "${name:?task name required}"
  local REMOTE="${REMOTE:-remote-host}"
  if [[ "$REMOTE" == "local" ]]; then
    tmux attach -t "ccr-$name"
  else
    ssh -t "$REMOTE" "tmux attach -t ccr-$name"
  fi
}
