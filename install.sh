#!/usr/bin/env bash
# claude-code-harness installer
#
# Reads registry.sh (package manifest), installs the selected packages.
#
# Modes:
#   ./install.sh                       Install all default packages
#   ./install.sh --all                 Same as default
#   ./install.sh --interactive         Prompt per-package
#   ./install.sh --packages=X,Y        Explicit list
#   ./install.sh --list                Show available packages, exit
#   ./install.sh --uninstall           Remove all installed packages
#   ./install.sh --uninstall --packages=X   Remove specific package
#   ./install.sh --help                Show this message
#
# Scope: pure local install. No network, no telemetry.
#
# Safety:
#   - set -euo pipefail
#   - settings.json backed up before any edit
#   - jq merges written to temp file, validated, then atomically renamed
#   - Any failure rolls back to the latest backup

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
readonly CLAUDE_HOME BIN_DIR

readonly SETTINGS_FILE="${CLAUDE_HOME}/settings.json"
readonly SCRIPTS_BASE="${CLAUDE_HOME}/scripts"
readonly SKILLS_BASE="${CLAUDE_HOME}/skills"
readonly LOG_DIR="${CLAUDE_HOME}/logs"

# Source the package registry (shell-source format, no YAML deps)
if [[ ! -f "$REPO_DIR/registry.sh" ]]; then
  echo "FATAL: registry.sh not found at $REPO_DIR/registry.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source "$REPO_DIR/registry.sh"

# ──────────────────────────────────────────────────────────────────────────
# Pretty output
# ──────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────
# Rollback state
# ──────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────
# Prerequisite checks
# ──────────────────────────────────────────────────────────────────────────
check_prereqs() {
  case "$(uname -s)" in
    Darwin|Linux) ;;
    *) fatal "Unsupported OS: $(uname -s). claude-code-harness supports macOS and Linux. On Windows, use WSL." ;;
  esac

  command -v jq    >/dev/null 2>&1 || fatal "jq is required but not found. Install with: brew install jq  (macOS) or apt install jq (Debian/Ubuntu)"
  command -v ssh   >/dev/null 2>&1 || warn "ssh not found — the 'remote' package needs it"
  command -v rsync >/dev/null 2>&1 || warn "rsync not found — the 'remote' package needs it"

  if [[ ! -d "$CLAUDE_HOME" ]]; then
    fatal "Claude Code config directory not found at ${CLAUDE_HOME}. Install Claude Code first: https://claude.com/claude-code"
  fi

  mkdir -p "$SCRIPTS_BASE" "$SKILLS_BASE" "$LOG_DIR"

  ok "prereqs OK"
}

# ──────────────────────────────────────────────────────────────────────────
# Backup
# ──────────────────────────────────────────────────────────────────────────
backup_settings() {
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    info "No existing ${SETTINGS_FILE} — creating empty"
    echo '{}' > "$SETTINGS_FILE"
    return
  fi

  local ts
  ts="$(date +%s)"
  LATEST_BACKUP="${SETTINGS_FILE}.bak.${ts}"
  cp "$SETTINGS_FILE" "$LATEST_BACKUP"
  ok "Backed up settings.json -> $(basename "$LATEST_BACKUP")"
}

# ──────────────────────────────────────────────────────────────────────────
# jq merge (for hook_script install type)
# ──────────────────────────────────────────────────────────────────────────
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
    .hooks //= {} |
    .hooks[$event] //= [] |
    if (.hooks[$event] | map(select(.matcher == $matcher)) | length) == 0 then
      .hooks[$event] += [{"matcher": $matcher, "hooks": []}]
    else . end |
    .hooks[$event] |= map(
      if .matcher == $matcher then
        .hooks = ((.hooks // []) | map(select(.command != $cmd)) + [{"type": "command", "command": $cmd}])
      else . end
    )
    ' "$SETTINGS_FILE" > "$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fatal "jq merge produced invalid JSON. Aborting before write."
  fi

  mv "$tmp" "$SETTINGS_FILE"
}

remove_hook_from_settings() {
  local event="$1"
  local matcher="$2"
  local hook_command="$3"

  [[ -f "$SETTINGS_FILE" ]] || return

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

# ──────────────────────────────────────────────────────────────────────────
# Install handlers (one per install-target type in registry.sh)
# ──────────────────────────────────────────────────────────────────────────
install_hook_script() {
  local pkg_path="$1" source="$2" dest_name="$3" event="$4" matcher="$5"
  local install_dir="$SCRIPTS_BASE/claude-code-harness"
  mkdir -p "$install_dir"
  cp "$REPO_DIR/$pkg_path/$source" "$install_dir/$dest_name"
  chmod +x "$install_dir/$dest_name"
  local hook_cmd="\$HOME/.claude/scripts/claude-code-harness/$dest_name"
  merge_hook_into_settings "$event" "$matcher" "$hook_cmd"
  ok "  hook: $dest_name (${event}/${matcher})"
}

install_copy_file() {
  local pkg_path="$1" source="$2" dest_rel="$3"
  local dest="$SCRIPTS_BASE/$dest_rel"
  mkdir -p "$(dirname "$dest")"
  cp "$REPO_DIR/$pkg_path/$source" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  ok "  file: $dest_rel"
}

install_copy_dir() {
  local pkg_path="$1" source_dir="$2" dest_subdir="$3"
  local dest="$SCRIPTS_BASE/$dest_subdir"
  mkdir -p "$dest"
  cp -a "$REPO_DIR/$pkg_path/$source_dir/." "$dest/"
  ok "  dir:  $dest_subdir/"
}

install_symlink_bin() {
  local source_in_scripts="$1" bin_name="$2"
  mkdir -p "$BIN_DIR"
  local real_target="$SCRIPTS_BASE/$source_in_scripts"
  if [[ ! -f "$real_target" ]]; then
    warn "symlink target missing: $real_target — did you list copy_file/copy_dir first?"
  fi
  ln -sf "$real_target" "$BIN_DIR/$bin_name"
  ok "  bin:  $BIN_DIR/$bin_name -> $real_target"
}

install_skill_install() {
  local pkg_path="$1" source="$2" skill_name="$3"
  local skill_dir="$SKILLS_BASE/$skill_name"
  mkdir -p "$skill_dir"
  cp "$REPO_DIR/$pkg_path/$source" "$skill_dir/SKILL.md"
  ok "  skill: $SKILLS_BASE/$skill_name/SKILL.md"
}

# ──────────────────────────────────────────────────────────────────────────
# Uninstall handlers
# ──────────────────────────────────────────────────────────────────────────
uninstall_hook_script() {
  local pkg_path="$1" source="$2" dest_name="$3" event="$4" matcher="$5"
  local installed="$SCRIPTS_BASE/claude-code-harness/$dest_name"
  local hook_cmd="\$HOME/.claude/scripts/claude-code-harness/$dest_name"
  remove_hook_from_settings "$event" "$matcher" "$hook_cmd"
  [[ -f "$installed" ]] && rm -f "$installed"
  ok "  removed hook: $dest_name"
}

uninstall_copy_file() {
  local pkg_path="$1" source="$2" dest_rel="$3"
  local dest="$SCRIPTS_BASE/$dest_rel"
  [[ -f "$dest" ]] && rm -f "$dest"
  ok "  removed file: $dest_rel"
}

uninstall_copy_dir() {
  local pkg_path="$1" source_dir="$2" dest_subdir="$3"
  local dest="$SCRIPTS_BASE/$dest_subdir"
  [[ -d "$dest" ]] && rm -rf "$dest"
  ok "  removed dir:  $dest_subdir/"
}

uninstall_symlink_bin() {
  local source_in_scripts="$1" bin_name="$2"
  local link="$BIN_DIR/$bin_name"
  [[ -L "$link" || -f "$link" ]] && rm -f "$link"
  ok "  removed bin:  $BIN_DIR/$bin_name"
}

uninstall_skill_install() {
  local pkg_path="$1" source="$2" skill_name="$3"
  local skill_dir="$SKILLS_BASE/$skill_name"
  [[ -d "$skill_dir" ]] && rm -rf "$skill_dir"
  ok "  removed skill: $skill_name"
}

# ──────────────────────────────────────────────────────────────────────────
# Package dispatch (install + uninstall)
# ──────────────────────────────────────────────────────────────────────────
dispatch_install_target() {
  local action="$1" pkg_path="$2" entry="$3"
  local type f1 f2 f3 f4
  IFS='|' read -r type f1 f2 f3 f4 <<< "$entry"

  case "$action:$type" in
    install:hook_script)       install_hook_script       "$pkg_path" "$f1" "$f2" "$f3" "$f4" ;;
    install:copy_file)         install_copy_file         "$pkg_path" "$f1" "$f2" ;;
    install:copy_dir)          install_copy_dir          "$pkg_path" "$f1" "$f2" ;;
    install:symlink_bin)       install_symlink_bin       "$f1" "$f2" ;;
    install:skill_install)     install_skill_install     "$pkg_path" "$f1" "$f2" ;;
    uninstall:hook_script)     uninstall_hook_script     "$pkg_path" "$f1" "$f2" "$f3" "$f4" ;;
    uninstall:copy_file)       uninstall_copy_file       "$pkg_path" "$f1" "$f2" ;;
    uninstall:copy_dir)        uninstall_copy_dir        "$pkg_path" "$f1" "$f2" ;;
    uninstall:symlink_bin)     uninstall_symlink_bin     "$f1" "$f2" ;;
    uninstall:skill_install)   uninstall_skill_install   "$pkg_path" "$f1" "$f2" ;;
    *) warn "unknown $action type: $type" ;;
  esac
}

install_package() {
  local pkg_id="$1"
  local pkg_path
  pkg_path=$(pkg_get "$pkg_id" path)
  info "Installing package: $pkg_id"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && dispatch_install_target "install" "$pkg_path" "$entry"
  done < <(pkg_get_installs "$pkg_id")
}

uninstall_package() {
  local pkg_id="$1"
  local pkg_path
  pkg_path=$(pkg_get "$pkg_id" path)
  info "Uninstalling package: $pkg_id"
  # Collect entries forward, then iterate in reverse.
  # Bash 3.2 + set -u: can't safely prepend to an empty array via
  # ("$x" "${arr[@]}") — expansion of empty arr is unbound.
  local entries=()
  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && entries+=("$entry")
  done < <(pkg_get_installs "$pkg_id")
  local i
  for (( i = ${#entries[@]} - 1; i >= 0; i-- )); do
    dispatch_install_target "uninstall" "$pkg_path" "${entries[i]}"
  done
}

# ──────────────────────────────────────────────────────────────────────────
# Selection modes
# ──────────────────────────────────────────────────────────────────────────
SELECTED_PACKAGES=()

select_default_packages() {
  SELECTED_PACKAGES=()
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if [[ "$(pkg_get "$pkg" default_install)" == "true" ]]; then
      SELECTED_PACKAGES+=("$pkg")
    fi
  done
}

prompt_interactive() {
  SELECTED_PACKAGES=()
  local pkg
  echo
  info "Interactive install — answer y/N per package:"
  echo
  for pkg in "${PACKAGES[@]}"; do
    local desc type verdict
    desc=$(pkg_get "$pkg" description)
    type=$(pkg_get "$pkg" type)
    verdict=$(pkg_get "$pkg" verdict)
    printf '  %s [%s, %s]\n' "$pkg" "$type" "$verdict"
    printf '    %s\n' "$desc"
    local ans=""
    read -r -p "    Install '$pkg'? [Y/n] " ans </dev/tty || ans=""
    ans="${ans:-y}"
    if [[ "$ans" =~ ^[Yy] ]]; then
      SELECTED_PACKAGES+=("$pkg")
      echo
    else
      info "    skipped"
      echo
    fi
  done
}

select_from_csv() {
  local csv="$1"
  SELECTED_PACKAGES=()
  local old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2206
  local list=($csv)
  IFS="$old_ifs"
  local p
  for p in "${list[@]}"; do
    local exists=false
    local known
    for known in "${PACKAGES[@]}"; do
      [[ "$known" == "$p" ]] && { exists=true; break; }
    done
    if $exists; then
      SELECTED_PACKAGES+=("$p")
    else
      fatal "unknown package: $p (known: ${PACKAGES[*]})"
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────
# --list mode
# ──────────────────────────────────────────────────────────────────────────
show_list() {
  printf '%s%s %s%s\n' "$C_BLUE" "$KIT_NAME" "$KIT_VERSION" "$C_RESET"
  echo "Available packages:"
  echo
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    local type verdict conf desc default
    type=$(pkg_get "$pkg" type)
    verdict=$(pkg_get "$pkg" verdict)
    conf=$(pkg_get "$pkg" confidence)
    desc=$(pkg_get "$pkg" description)
    default=$(pkg_get "$pkg" default_install)
    printf '  %s%-15s%s [%s, %s, confidence %s]\n' "$C_GREEN" "$pkg" "$C_RESET" "$type" "$verdict" "$conf"
    printf '                  %s\n' "$desc"
    printf '                  default_install: %s\n' "$default"
    echo
  done
}

# ──────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────
print_usage() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
}

print_success_banner() {
  echo
  ok "Installation complete."
  echo
  info "Installed packages: ${SELECTED_PACKAGES[*]}"
  [[ -n "${LATEST_BACKUP:-}" ]] && info "settings.json backup: ${LATEST_BACKUP}"
  echo
  info "Next steps:"
  local pkg
  for pkg in "${SELECTED_PACKAGES[@]}"; do
    case "$pkg" in
      secret-guard)
        echo "    # Verify secret-guard blocks secret-leak commands (in a CC session):"
        echo "    echo \$ANTHROPIC_API_KEY"
        echo "    # Expected: 'Secret guard BLOCKED'"
        ;;
      remote)
        echo "    # Verify claude-code-remote CLI is on PATH:"
        echo "    claude-code-remote help"
        echo "    # Run the smoke test round trip:"
        echo "    claude-code-remote run $REPO_DIR/packages/remote/examples/hello-world.conf"
        ;;
    esac
  done
  echo
  info "Uninstall any time: ${REPO_DIR}/install.sh --uninstall"
}

main() {
  local mode="install"
  local interactive=false
  local explicit_packages=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)             mode="list"; shift ;;
      --uninstall|-u)     mode="uninstall"; shift ;;
      --all)              shift ;;
      --interactive|-i)   interactive=true; shift ;;
      --packages=*)       explicit_packages="${1#--packages=}"; shift ;;
      --help|-h)          print_usage; exit 0 ;;
      *) err "unknown arg: $1"; print_usage; exit 1 ;;
    esac
  done

  case "$mode" in
    list)
      show_list
      exit 0
      ;;
    uninstall)
      trap on_error ERR
      backup_settings
      if [[ -n "$explicit_packages" ]]; then
        select_from_csv "$explicit_packages"
      else
        SELECTED_PACKAGES=("${PACKAGES[@]}")
      fi
      local pkg
      for pkg in "${SELECTED_PACKAGES[@]}"; do
        uninstall_package "$pkg"
      done
      # Clean up empty parent dirs left behind by copy_file/copy_dir removal
      if [[ -d "$SCRIPTS_BASE/claude-code-harness" ]]; then
        find "$SCRIPTS_BASE/claude-code-harness" -type d -empty -delete 2>/dev/null || true
      fi
      trap - ERR
      echo
      ok "${KIT_NAME} uninstalled (packages: ${SELECTED_PACKAGES[*]})"
      info "User state preserved: ${LOG_DIR} and installed skills/scripts dirs for OTHER kits are untouched."
      ;;
    install)
      printf '%s══════════════════════════════════════════════════════%s\n' "$C_BLUE" "$C_RESET"
      printf '%s  %s %s installer — pure local%s\n' "$C_BLUE" "$KIT_NAME" "$KIT_VERSION" "$C_RESET"
      printf '%s══════════════════════════════════════════════════════%s\n' "$C_BLUE" "$C_RESET"
      echo

      trap on_error ERR
      check_prereqs
      backup_settings

      if [[ -n "$explicit_packages" ]]; then
        select_from_csv "$explicit_packages"
      elif $interactive; then
        prompt_interactive
      else
        select_default_packages
      fi

      if [[ "${#SELECTED_PACKAGES[@]}" -eq 0 ]]; then
        warn "No packages selected — nothing to install."
        exit 0
      fi

      local pkg
      for pkg in "${SELECTED_PACKAGES[@]}"; do
        install_package "$pkg"
      done

      trap - ERR
      print_success_banner
      ;;
  esac
}

main "$@"
