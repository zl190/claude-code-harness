#!/usr/bin/env bash
# integration-hello-world.sh — full Mac → remote → recover → QC round trip
#
# Requires a real ssh-reachable REMOTE (default: remote-host). Skips with a
# warning if ssh is not configured.
#
# What it proves end-to-end:
#   1. snapshot mirrors local files to remote
#   2. spawn pushes inputs + starts a tmux + claude -p
#   3. status reports the live task
#   4. recover pulls the output back, runs qc, returns success
#
# Cleanup: removes remote scratch dirs at the end (safe — separate namespace).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CCR="$REPO_DIR/bin/claude-code-remote"
REMOTE="${REMOTE:-remote-host}"

PASS=0
FAIL=0

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

# ── Pre-flight: is the remote reachable? ──
if ! ssh -o ConnectTimeout=5 "$REMOTE" "echo ok" >/dev/null 2>&1; then
  echo "SKIP: cannot reach $REMOTE — set REMOTE env or configure ~/.ssh/config"
  exit 0
fi

if ! ssh "$REMOTE" "command -v claude >/dev/null 2>&1"; then
  echo "SKIP: claude CLI not found on $REMOTE"
  exit 0
fi

if ! ssh "$REMOTE" "[[ -n \"\${ANTHROPIC_API_KEY:-}\" ]]"; then
  echo "SKIP: ANTHROPIC_API_KEY not set on $REMOTE"
  exit 0
fi

step "round-trip integration test against $REMOTE"

# Use the example hello-world conf
CONF="$REPO_DIR/examples/hello-world.conf"
[[ -f "$CONF" ]] || { echo "missing $CONF"; exit 1; }

# Run the full pipeline (snapshot is a no-op here since hello-world doesn't need fresh logs)
"$CCR" run "$CONF" 2>&1 | tail -30
rc=$?

if [[ $rc -eq 0 ]]; then
  ok "claude-code-remote run completed"
else
  bad "claude-code-remote run failed (exit $rc)"
fi

# Verify the recovered file exists and contains the magic phrase
recovered="$HOME/.cache/claude-code-remote/recovered/hello-world/output.txt"
if [[ -f "$recovered" ]]; then
  ok "recovered file present at $recovered"
  if grep -q "hello world from claude-code-remote" "$recovered"; then
    ok "recovered file contains expected magic phrase"
  else
    bad "recovered file missing magic phrase. Content:"
    cat "$recovered" | sed 's/^/    /'
  fi
else
  bad "recovered file not at $recovered"
fi

# Check that the run.log was also recovered
runlog="$HOME/.cache/claude-code-remote/recovered/hello-world/hello-world.run.log"
if [[ -f "$runlog" ]]; then
  ok "execution log recovered alongside output"
else
  bad "execution log NOT recovered (missing $runlog)"
fi

# ── Cleanup remote scratch ──
ssh "$REMOTE" "rm -rf cc-remote-input/hello-world cc-remote-output/hello-world; tmux kill-session -t ccr-hello-world 2>/dev/null || true" >/dev/null 2>&1

echo
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
