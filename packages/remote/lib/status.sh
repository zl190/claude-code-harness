#!/usr/bin/env bash
# status.sh — one-line per running task

cmd_status() {
  local REMOTE="${REMOTE:-remote-host}"
  local REMOTE_OUTPUT_DIR="${REMOTE_OUTPUT_DIR:-cc-remote-output}"

  ssh "$REMOTE" bash -s <<REMOTE_SCRIPT
set -uo pipefail
shopt -s nullglob 2>/dev/null || true

if [ ! -d "\$HOME/$REMOTE_OUTPUT_DIR" ]; then
  echo "(no tasks — output dir not yet created)"
  exit 0
fi

cd "\$HOME/$REMOTE_OUTPUT_DIR"
found=0
for d in */; do
  found=1
  name="\${d%/}"
  log="\$d/run.log"
  done_marker=0
  log_size=0
  if [ -f "\$log" ]; then
    done_marker=\$(grep -c '^DONE' "\$log" 2>/dev/null || echo 0)
    log_size=\$(wc -c < "\$log" 2>/dev/null | tr -d ' ')
  fi
  tmux_state=DEAD
  if tmux has -t "ccr-\$name" 2>/dev/null; then
    tmux_state=LIVE
  fi
  status=PENDING
  if [ "\$done_marker" -gt 0 ]; then status=DONE
  elif [ "\$tmux_state" = LIVE ]; then status=RUNNING
  fi
  printf '%-30s %s tmux=%-4s log=%sB\n' "\$name" "\$status" "\$tmux_state" "\$log_size"
done

if [ \$found -eq 0 ]; then
  echo "(no tasks in \$HOME/$REMOTE_OUTPUT_DIR)"
fi
REMOTE_SCRIPT
}
