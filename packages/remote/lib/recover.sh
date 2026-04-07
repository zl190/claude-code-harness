#!/usr/bin/env bash
# recover.sh — pull task results back to local, run QC, retry on failure
#
# Flow:
#   1. rsync remote output dir to a local staging dir
#   2. find OUTPUT files (matching task.conf OUTPUT_PATTERN, default *.md)
#   3. run qc_check on each
#   4. if any fails: retry the task (max RETRY_MAX, default 2) with the
#      QC failure reason injected as additional context
#   5. on final pass: rsync to RECOVER_TO destination
#   6. on final fail: leave in staging with .INCOMPLETE marker

cmd_recover() {
  local target="${1:-all}"
  local REMOTE="${REMOTE:-remote-host}"

  if [[ "$target" == "all" ]]; then
    # Recover every task in cc-remote-output
    local names
    names=$(_ccr_run "ls cc-remote-output/ 2>/dev/null || true")
    if [[ -z "$names" ]]; then
      echo "[recover] no tasks to recover"
      return 0
    fi
    local n
    for n in $names; do
      _recover_one "$n"
    done
  else
    _recover_one "$target"
  fi
}

_recover_one() {
  local name="$1"
  local REMOTE="${REMOTE:-remote-host}"
  local REMOTE_OUTPUT_DIR="cc-remote-output/$name"
  local STAGING="$HOME/.cache/claude-code-remote/staging/$name"
  local RECOVER_TO="${RECOVER_TO:-$HOME/.cache/claude-code-remote/recovered/$name}"
  local OUTPUT_PATTERN="${OUTPUT_PATTERN:-*.md}"
  local QC_REQUIRED_SECTIONS="${QC_REQUIRED_SECTIONS:-}"
  local QC_REQUIRED_FRONTMATTER="${QC_REQUIRED_FRONTMATTER:-}"
  local RETRY_MAX="${RETRY_MAX:-2}"
  local RETRY_WAIT_TIMEOUT="${RETRY_WAIT_TIMEOUT:-$((${TIMEOUT:-1800} / 2))}"

  mkdir -p "$STAGING" "$RECOVER_TO"

  local retry_count=0
  while true; do
    # Step 1: rsync remote output to local staging
    _ccr_pull "$REMOTE_OUTPUT_DIR" "$STAGING" || {
      echo "[recover] ERROR: pull failed for $name" >&2
      return 1
    }

    # Step 2: find candidate output files (skip the runner + log + prompt)
    local outputs=()
    local f
    for f in "$STAGING"/$OUTPUT_PATTERN; do
      [[ -f "$f" ]] || continue
      case "$(basename "$f")" in
        _runner.sh|run.log|_prompt.txt) continue ;;
      esac
      outputs+=("$f")
    done

    # Step 3: QC
    local qc_pass=true
    local qc_fail_reasons=()
    if [[ "${#outputs[@]}" -eq 0 ]]; then
      qc_pass=false
      qc_fail_reasons+=("no output files matched pattern '$OUTPUT_PATTERN'")
    else
      for f in "${outputs[@]}"; do
        if ! qc_check "$f" "$QC_REQUIRED_SECTIONS" "$QC_REQUIRED_FRONTMATTER"; then
          qc_pass=false
          qc_fail_reasons+=("$(basename "$f"): $(qc_reason)")
        fi
      done
    fi

    if $qc_pass; then
      cp "${outputs[@]}" "$RECOVER_TO/"
      cp "$STAGING/run.log" "$RECOVER_TO/${name}.run.log" 2>/dev/null || true
      if [[ $retry_count -gt 0 ]]; then
        echo "[recover] $name: OK after $retry_count retry(ies) — ${#outputs[@]} file(s) -> $RECOVER_TO/"
      else
        echo "[recover] $name: OK — ${#outputs[@]} file(s) -> $RECOVER_TO/"
      fi
      return 0
    fi

    # QC failed — retry?
    if [[ "$retry_count" -ge "$RETRY_MAX" ]]; then
      touch "$STAGING/.INCOMPLETE"
      echo "[recover] $name: INCOMPLETE — exhausted $RETRY_MAX retries" >&2
      printf '[recover]   reason: %s\n' "${qc_fail_reasons[@]}" >&2
      echo "[recover]   staging: $STAGING (manual review needed)" >&2
      return 1
    fi

    # Build retry context
    local retry_context
    retry_context="Your previous attempt was incomplete. Quality check failed:
$(printf '  - %s\n' "${qc_fail_reasons[@]}")

Re-produce the output at the SAME file path. Read what you already wrote and
complete the missing parts. Do NOT start over. Preserve any sections that
already passed QC."

    retry_count=$((retry_count + 1))
    echo "[recover] $name: QC failed, retry $retry_count/$RETRY_MAX"
    printf '[recover]   %s\n' "${qc_fail_reasons[@]}"

    # Append retry context to remote prompt and restart the runner
    local prompt_remote="cc-remote-input/$name/_prompt.txt"
    cat <<RETRY_EOF | _ccr_write_append "$prompt_remote"

---
RETRY ATTEMPT $retry_count of $RETRY_MAX:
$retry_context
RETRY_EOF

    _ccr_run "tmux kill-session -t ccr-$name 2>/dev/null; \
              : > ~/cc-remote-output/$name/run.log; \
              tmux new-session -d -s ccr-$name '~/cc-remote-output/$name/_runner.sh'"

    # Wait for the new DONE marker before looping back to rsync
    local elapsed=0
    local interval=5
    while [[ $elapsed -lt $RETRY_WAIT_TIMEOUT ]]; do
      if _ccr_run "grep -q '^DONE' ~/$REMOTE_OUTPUT_DIR/run.log 2>/dev/null"; then
        break
      fi
      sleep $interval
      elapsed=$((elapsed + interval))
    done

    if [[ $elapsed -ge $RETRY_WAIT_TIMEOUT ]]; then
      echo "[recover] $name: retry timed out after ${RETRY_WAIT_TIMEOUT}s" >&2
      return 1
    fi

    # Loop back to rsync + QC the retry output
  done
}

cmd_wait_then_recover() {
  local task_conf="${1:-}"
  [[ -f "$task_conf" ]] || { echo "task.conf required" >&2; return 1; }
  # shellcheck disable=SC1090
  source "$task_conf"
  : "${NAME:?task.conf must set NAME}"
  local REMOTE="${REMOTE:-remote-host}"

  # Poll status until DONE marker appears or timeout
  local TIMEOUT="${TIMEOUT:-1800}"  # 30 min default
  local elapsed=0
  local interval=5
  while [[ $elapsed -lt $TIMEOUT ]]; do
    if _ccr_run "grep -q '^DONE' ~/cc-remote-output/$NAME/run.log 2>/dev/null"; then
      _recover_one "$NAME"
      return $?
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "[recover] $NAME: TIMEOUT after ${TIMEOUT}s" >&2
  return 1
}
