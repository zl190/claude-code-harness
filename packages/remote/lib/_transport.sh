#!/usr/bin/env bash
# _transport.sh — shared transport helpers (ssh + local)
#
# All other lib/*.sh files use these helpers instead of bare ssh/rsync so that
# REMOTE=local mode can short-circuit the network round trip and run the same
# pipeline against the local machine. Used by Phase-2 wrappers (cc-live-brief)
# that want spawn/wait/recover/qc without paying ssh cost.

_ccr_run() {
  # Run a shell command "remotely". For REMOTE=local, executes locally.
  if [[ "${REMOTE:-}" == "local" ]]; then bash -c "$1"; else ssh "$REMOTE" "$1"; fi
}

_ccr_write() {
  # Write stdin to a "remote" path (relative to remote $HOME).
  local target="$1"
  if [[ "${REMOTE:-}" == "local" ]]; then
    mkdir -p "$(dirname "$HOME/$target")" && cat > "$HOME/$target"
  else
    ssh "$REMOTE" "cat > ~/$target"
  fi
}

_ccr_write_append() {
  # Append stdin to a "remote" path (relative to remote $HOME).
  local target="$1"
  if [[ "${REMOTE:-}" == "local" ]]; then
    mkdir -p "$(dirname "$HOME/$target")" && cat >> "$HOME/$target"
  else
    ssh "$REMOTE" "cat >> ~/$target"
  fi
}

_ccr_copy() {
  # Copy local files into a "remote" directory (relative to remote $HOME).
  # Args: <dest_dir> <file>...
  local dest="$1"; shift
  if [[ "${REMOTE:-}" == "local" ]]; then
    mkdir -p "$HOME/$dest" && cp -- "$@" "$HOME/$dest/"
  else
    rsync -avz --no-perms --no-owner --no-group "$@" "$REMOTE:$dest/" 2>&1 | tail -3
  fi
}

_ccr_pull() {
  # Pull a "remote" directory back to a local staging dir.
  # Args: <remote_relative_dir> <local_dest>
  local src="$1"
  local dest="$2"
  if [[ "${REMOTE:-}" == "local" ]]; then
    mkdir -p "$dest"
    # Local mode: cp is simpler and avoids macOS rsync protocol quirks.
    if [[ -d "$HOME/$src" ]]; then
      ( cd "$HOME/$src" && find . -mindepth 1 -maxdepth 1 -print0 \
        | xargs -0 -I{} cp -R {} "$dest/" ) 2>&1 | tail -3
    fi
  else
    rsync -avz --no-perms --no-owner --no-group "$REMOTE:$src/" "$dest/" 2>&1 | tail -3
  fi
}
