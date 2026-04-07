#!/usr/bin/env bash
# registry.sh — package registry for claude-code-harness
#
# This is the SOURCE OF TRUTH for install.sh. It lists every installable
# package in the kit, along with its metadata and install targets.
#
# Format: shell-source (no YAML dependencies). bash 3.2 compatible.
# v0.1 intentionally uses scalar vars + indexed arrays; no associative arrays.
# v0.2 may add a YAML variant and a converter.
#
# Install-target line format (pipe-delimited):
#   hook_script|SOURCE|DEST_NAME|EVENT|MATCHER
#       copies SOURCE (pkg-relative) to $CLAUDE_HOME/scripts/claude-code-harness/DEST_NAME,
#       merges a $EVENT hook with $MATCHER matcher into settings.json
#
#   copy_file|SOURCE|DEST_REL
#       copies SOURCE (pkg-relative) to $CLAUDE_HOME/scripts/$DEST_REL
#
#   copy_dir|SOURCE_DIR|DEST_SUBDIR
#       copies SOURCE_DIR contents (pkg-relative) to $CLAUDE_HOME/scripts/$DEST_SUBDIR/
#
#   symlink_bin|SOURCE_IN_SCRIPTS|BIN_NAME
#       symlinks $CLAUDE_HOME/scripts/$SOURCE_IN_SCRIPTS to $BIN_DIR/$BIN_NAME
#       (note: SOURCE_IN_SCRIPTS is NOT pkg-relative; it's the post-copy path)
#
#   skill_install|SOURCE|SKILL_NAME
#       copies SOURCE (pkg-relative) to $CLAUDE_HOME/skills/$SKILL_NAME/SKILL.md
#
# Order matters: copy_file/copy_dir should come BEFORE symlink_bin that points at them.

KIT_NAME="claude-code-harness"
KIT_VERSION="0.1.0"

# Ordered list of packages (ensures deterministic install order)
PACKAGES=()

# ── secret-guard ──────────────────────────────────────────────────────────
PACKAGES+=(secret-guard)
PKG_secret_guard_type="hook"
PKG_secret_guard_path="packages/secret-guard"
PKG_secret_guard_description="Blocks commands that expose secrets (API keys, credentials, env dumps) at the PreToolUse boundary"
PKG_secret_guard_verdict="SHIPPING_READY"
PKG_secret_guard_confidence="4/5"
PKG_secret_guard_default_install="true"
PKG_secret_guard_validation="validation.md"
PKG_secret_guard_installs=(
  "hook_script|hook.sh|secret-guard.sh|PreToolUse|Bash"
)

# ── remote ────────────────────────────────────────────────────────────────
PACKAGES+=(remote)
PKG_remote_type="tool"
PKG_remote_path="packages/remote"
PKG_remote_description="Delegate Claude Code tasks to a remote machine; survives laptop sleep. Installs CLI + skill so Claude can use it smoothly."
PKG_remote_verdict="SHIPPING_READY"
PKG_remote_confidence="4/5"
PKG_remote_default_install="true"
PKG_remote_validation="validation.md"
PKG_remote_installs=(
  "copy_file|bin/claude-code-remote|claude-code-harness/remote/bin/claude-code-remote"
  "copy_dir|lib|claude-code-harness/remote/lib"
  "symlink_bin|claude-code-harness/remote/bin/claude-code-remote|claude-code-remote"
  "skill_install|skill/SKILL.md|claude-code-remote"
)

# ── Helpers install.sh uses to read package data ─────────────────────────
# Usage: pkg_get secret-guard type  → "hook"
pkg_get() {
  local id="$1" field="$2"
  # Normalize id for var name (dashes → underscores)
  local safe_id="${id//-/_}"
  local var="PKG_${safe_id}_${field}"
  printf '%s' "${!var:-}"
}

# Usage: pkg_get_installs secret-guard  → prints pipe-delimited install targets
pkg_get_installs() {
  local id="$1"
  local safe_id="${id//-/_}"
  local array_name="PKG_${safe_id}_installs[@]"
  local entry
  for entry in "${!array_name}"; do
    printf '%s\n' "$entry"
  done
}
