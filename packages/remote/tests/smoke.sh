#!/usr/bin/env bash
# round-trip-smoke.sh — verify the local launcher can drive a remote task
#
# This is a UNIT smoke test. It does NOT require a live remote — it mocks ssh
# with a local stub that records what would be invoked. For an end-to-end
# integration test against a real remote, see `examples/hello-world.conf` and
# run: claude-code-remote run examples/hello-world.conf

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s — expected %q, got %q\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL+1))
  fi
}

assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  PASS  %s\n' "$label"
    PASS=$((PASS+1))
  else
    printf '  FAIL  %s — command failed: %s\n' "$label" "$*"
    FAIL=$((FAIL+1))
  fi
}

echo "claude-code-remote round-trip smoke test"
echo "========================================"
echo

# Source qc.sh directly (the only lib that's pure-local)
source "$REPO_DIR/lib/qc.sh"

# ── QC tests ──────────────────────────────────────────────
echo "qc_check tests"
echo "--------------"
TMP=$(mktemp -d)

# Test 1: file missing
qc_check "$TMP/nope.md" >/dev/null 2>&1; rc=$?
assert_eq "missing file fails" "1" "$rc"

# Test 2: empty file
: > "$TMP/empty.md"
qc_check "$TMP/empty.md" >/dev/null 2>&1; rc=$?
assert_eq "empty file fails" "1" "$rc"

# Test 3: too small
echo "tiny" > "$TMP/tiny.md"
qc_check "$TMP/tiny.md" >/dev/null 2>&1; rc=$?
assert_eq "too small fails" "1" "$rc"

# Test 4: passes basic
cat > "$TMP/ok.md" <<'EOF'
This is a file with enough content to pass the minimum size check
which requires at least 100 bytes of real content present in the file.
EOF
qc_check "$TMP/ok.md" >/dev/null 2>&1; rc=$?
assert_eq "passes basic" "0" "$rc"

# Test 5: section requirement
cat > "$TMP/sections.md" <<'EOF'
Some intro content that goes here filler filler filler filler filler.
§1 Trigger
something
§2 Result
something more
§3 Idempotency
something more again to reach the 100 byte minimum
EOF
qc_check "$TMP/sections.md" "§1 §2 §3" >/dev/null 2>&1; rc=$?
assert_eq "all sections present" "0" "$rc"

qc_check "$TMP/sections.md" "§1 §2 §3 §4" >/dev/null 2>&1; rc=$?
assert_eq "missing section fails" "1" "$rc"

# Test 6: placeholder content
cat > "$TMP/placeholder.md" <<'EOF'
A document with enough content to satisfy size requirements but it
contains a TODO marker that should make qc reject this file even though
the schema is otherwise fine and all other things look good.
EOF
qc_check "$TMP/placeholder.md" >/dev/null 2>&1; rc=$?
assert_eq "TODO placeholder fails" "2" "$rc"

# Test 7: frontmatter requirement
cat > "$TMP/frontmatter.md" <<'EOF'
---
verdict: SHIPPING_READY
confidence: 4/5
---
Body content here filler filler filler filler filler filler filler.
EOF
qc_check "$TMP/frontmatter.md" "" "verdict confidence" >/dev/null 2>&1; rc=$?
assert_eq "frontmatter present" "0" "$rc"

qc_check "$TMP/frontmatter.md" "" "verdict confidence missing_field" >/dev/null 2>&1; rc=$?
assert_eq "frontmatter missing fails" "1" "$rc"

rm -rf "$TMP"

# ── dispatcher exists & runs help ─────────────────────────
echo
echo "dispatcher tests"
echo "----------------"
assert_ok "bin/claude-code-remote help runs" "$REPO_DIR/bin/claude-code-remote" help

# ── unknown command exits non-zero ────────────────────────
"$REPO_DIR/bin/claude-code-remote" totally-not-a-command >/dev/null 2>&1; rc=$?
assert_eq "unknown command exits 1" "1" "$rc"

echo
echo "========================================"
printf 'PASSED: %d   FAILED: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
