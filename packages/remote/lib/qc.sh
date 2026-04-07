#!/usr/bin/env bash
# qc.sh — quality checks for recovered task outputs
#
# Two layers in v0.0:
#   L1 — schema: file exists, size > 0, required sections/fields present
#   L2 — content: no TODO / [placeholder] / "<undefined>" markers
#
# qc_check returns 0 = pass, 1 = schema fail, 2 = content fail.
# qc_reason prints why.

QC_LAST_REASON=""

qc_check() {
  local file="$1"
  local required_sections="${2:-}"  # space-separated, e.g. "§1 §2 §3 §4 §5 §6"
  local required_frontmatter="${3:-}"  # space-separated, e.g. "verdict confidence"
  local min_size="${QC_MIN_SIZE:-100}"  # overridable per-task via task.conf

  QC_LAST_REASON=""

  # L1.1: file exists and non-empty
  if [[ ! -f "$file" ]]; then
    QC_LAST_REASON="file missing: $file"
    return 1
  fi
  local size
  size=$(wc -c < "$file" | tr -d ' ')
  if [[ "$size" -eq 0 ]]; then
    QC_LAST_REASON="file empty: $file"
    return 1
  fi
  if [[ "$size" -lt "$min_size" ]]; then
    QC_LAST_REASON="file too small ($size bytes, need $min_size): $file"
    return 1
  fi

  # L1.2: required sections present
  if [[ -n "$required_sections" ]]; then
    local sec
    for sec in $required_sections; do
      if ! grep -qF "$sec" "$file"; then
        QC_LAST_REASON="missing required section: $sec"
        return 1
      fi
    done
  fi

  # L1.3: required frontmatter fields present
  if [[ -n "$required_frontmatter" ]]; then
    local field
    for field in $required_frontmatter; do
      if ! grep -qE "^${field}:" "$file"; then
        QC_LAST_REASON="missing frontmatter field: $field"
        return 1
      fi
    done
  fi

  # L2: content placeholders
  if grep -qE '\bTODO\b|\[placeholder\]|<undefined>|<TBD>|XXX' "$file"; then
    local marker
    marker=$(grep -oE 'TODO|\[placeholder\]|<undefined>|<TBD>|XXX' "$file" | head -1)
    QC_LAST_REASON="content placeholder present: $marker"
    return 2
  fi

  return 0
}

qc_reason() {
  printf '%s' "$QC_LAST_REASON"
}
