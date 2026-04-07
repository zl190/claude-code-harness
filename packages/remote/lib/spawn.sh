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
  if [[ -z "${PROMPT:-}" && -z "${PROMPT_FILE:-}" ]]; then
    echo "[spawn] ERROR: task.conf must set PROMPT (string) or PROMPT_FILE (path)" >&2
    return 1
  fi
  # Optional extra args passed to `claude -p` (e.g. "--bare --permission-mode bypassPermissions")
  local CLAUDE_ARGS="${CLAUDE_ARGS:-}"
  # Optional: path to a settings.json that will be the SOLE config the bg
  # `claude -p` sees. Implemented via HOME= override.
  local ISOLATE_HOOKS_FILE="${ISOLATE_HOOKS_FILE:-}"
  # Optional: webhook URL fired on task completion. Posts JSON with status +
  # tail of log. Use Discord webhook URL or any HTTP endpoint accepting JSON.
  local NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
  # When to fire NOTIFY_WEBHOOK_URL: success | failure | both. Default: both.
  local NOTIFY_ON="${NOTIFY_ON:-both}"
  # Optional: append a one-line completion record to a JSONL queue file on the
  # remote. macbook can later run `claude-code-remote pull-queue` to drain
  # unrecovered entries. Default queue path is ~/cc-remote-output/.completion-queue.jsonl
  local QUEUE_ENABLE="${QUEUE_ENABLE:-true}"

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

  # If ISOLATE_HOOKS_FILE set, push it to the remote-input dir. The runner
  # builds an isolated HOME by SYMLINKING every entry in real ~/.claude/*
  # except settings.json (which it overlays with the iso file). This is
  # auth-scheme agnostic: file creds, macOS Keychain (system-level, reachable
  # from any HOME), env var (inherited), and any future state files all
  # work without enumerating their names. HOME override is OS-level so it
  # doesn't drift between claude CLI versions like --setting-sources does.
  local iso_remote=""
  if [[ -n "$ISOLATE_HOOKS_FILE" ]]; then
    if [[ ! -f "$ISOLATE_HOOKS_FILE" ]]; then
      echo "[spawn] ERROR: ISOLATE_HOOKS_FILE not found: $ISOLATE_HOOKS_FILE" >&2
      return 1
    fi
    iso_remote="$REMOTE_INPUT_DIR/_iso_settings.json"
    _ccr_copy "$REMOTE_INPUT_DIR" "$ISOLATE_HOOKS_FILE"
    local src_base
    src_base="$(basename "$ISOLATE_HOOKS_FILE")"
    _ccr_run "mv ~/$REMOTE_INPUT_DIR/$src_base ~/$iso_remote"
  fi

  # Build the runner script (lives in output dir alongside the run.log)
  local runner_remote="$REMOTE_OUTPUT_DIR/_runner.sh"
  _ccr_write "$runner_remote" <<RUNNER_EOF
#!/usr/bin/env bash
set -uo pipefail
ORIG_HOME="\$HOME"
LOG="\$ORIG_HOME/$REMOTE_OUTPUT_DIR/run.log"
echo "=== START \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "\$LOG"
echo "task: $NAME" >> "\$LOG"
if [[ -n "$iso_remote" && -f "\$ORIG_HOME/$iso_remote" ]]; then
  ISO_HOME="\$ORIG_HOME/.cache/claude-code-remote/iso/$NAME"
  rm -rf "\$ISO_HOME"
  mkdir -p "\$ISO_HOME/.claude"
  # Overlay the isolated settings.json (the only thing we want different)
  cp "\$ORIG_HOME/$iso_remote" "\$ISO_HOME/.claude/settings.json"
  # Curated symlinks of auth-related state from real ~/.claude/. We do NOT
  # symlink everything because empirically (verified via bisect on Linux
  # claude 2.1.90) symlinking ~/.claude/scripts/ causes claude to load the
  # USER's full settings.json — likely a parent-dir walk from scripts/
  # finds the real settings.json and merges it, defeating isolation. The
  # safe set is auth + minimal session state; hook-script directories
  # (scripts/, plugins/, agents/, skills/) are NEVER symlinked.
  for f in .credentials.json .credentials .credentials.json.backup mcp-needs-auth-cache.json policy-limits.json; do
    if [[ -e "\$ORIG_HOME/.claude/\$f" ]]; then
      ln -sf "\$ORIG_HOME/.claude/\$f" "\$ISO_HOME/.claude/\$f"
    fi
  done
  # Top-level ~/.claude.json (project metadata, separate from .claude/ dir).
  # Without this, claude warns about missing config (no functional impact
  # but spams the run log).
  for f in .claude.json .claude.json.backup; do
    if [[ -e "\$ORIG_HOME/\$f" ]]; then
      ln -sf "\$ORIG_HOME/\$f" "\$ISO_HOME/\$f"
    fi
  done
  echo "isolated HOME: \$ISO_HOME (settings overlaid, auth-only symlinks)" >> "\$LOG"
  HOME="\$ISO_HOME" claude -p $CLAUDE_ARGS "\$(cat \$ORIG_HOME/$prompt_file_remote)" >> "\$LOG" 2>&1
  CLAUDE_EXIT=\$?
else
  claude -p $CLAUDE_ARGS "\$(cat \$ORIG_HOME/$prompt_file_remote)" >> "\$LOG" 2>&1
  CLAUDE_EXIT=\$?
fi
echo "=== END \$(date -u +%Y-%m-%dT%H:%M:%SZ) (claude exit: \$CLAUDE_EXIT) ===" >> "\$LOG"
echo DONE >> "\$LOG"

# === Phase F: Discord webhook notification ===
NOTIFY_URL="$NOTIFY_WEBHOOK_URL"
NOTIFY_ON="$NOTIFY_ON"
if [[ -n "\$NOTIFY_URL" ]]; then
  if [[ \$CLAUDE_EXIT -eq 0 ]]; then status="success"; else status="failure"; fi
  fire="false"
  case "\$NOTIFY_ON" in
    success) [[ "\$status" == "success" ]] && fire="true" ;;
    failure) [[ "\$status" == "failure" ]] && fire="true" ;;
    both)    fire="true" ;;
  esac
  if [[ "\$fire" == "true" ]]; then
    tail_log=\$(tail -25 "\$LOG" 2>/dev/null || echo "(log unavailable)")
    payload=\$(jq -cn --arg n "$NAME" --arg s "\$status" --arg t "\$tail_log" \\
      '{content: ("**" + \$n + "** " + \$s + "\\n\`\`\`\\n" + \$t + "\\n\`\`\`")}' 2>/dev/null || echo "")
    if [[ -n "\$payload" ]]; then
      curl -fsS -X POST -H "Content-Type: application/json" \\
        -d "\$payload" "\$NOTIFY_URL" >/dev/null 2>&1 || true
    fi
  fi
fi

# === Phase G: completion-queue append ===
QUEUE_ENABLE="$QUEUE_ENABLE"
if [[ "\$QUEUE_ENABLE" == "true" ]]; then
  QUEUE="\$ORIG_HOME/cc-remote-output/.completion-queue.jsonl"
  if [[ \$CLAUDE_EXIT -eq 0 ]]; then status="success"; else status="failure"; fi
  { jq -cn --arg n "$NAME" --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
       --arg dir "\$ORIG_HOME/$REMOTE_OUTPUT_DIR" --arg s "\$status" \\
       '{name:\$n, completed_at:\$ts, output_dir:\$dir, status:\$s, pulled:false}' \\
       >> "\$QUEUE"; } 2>/dev/null
fi
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
