#!/usr/bin/env bash
# libcbor/mayhem/test.sh — RUN libcbor's OWN cmocka unit-test suite (built by mayhem/build.sh with the
# project's normal flags, no sanitizers) via ctest → CTRF. PATCH-grade oracle: it never compiles the
# fuzz build, and it asserts BEHAVIOR, not just exit status.
#
# Each test/*_test.c is a cmocka program that decodes/encodes CBOR and assert()s the EXACT results
# (decoded integer/string/array/map/tag values, serialization round-trips, cbor_load error codes,
# pretty-printer output, etc.), aborting on any mismatch. A no-op / exit(0) "patch" to the parser
# makes those asserted values wrong and fails the corresponding cmocka test, so this oracle cannot be
# reward-hacked by "ran without crashing".
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

TEST_BUILD="$SRC/mayhem-test-build"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d "$TEST_BUILD" ] || { echo "missing $TEST_BUILD — build.sh did not build the test suite?" >&2; emit_ctrf "cmake-ctest" 0 1; exit 2; }

# Run the cmocka suite via ctest. Parse the summary line:
#   "100% tests passed, 0 tests failed out of 33"
LOG="$(mktemp)"
echo "test.sh: running libcbor cmocka suite via ctest" >&2
ctest --test-dir "$TEST_BUILD" -j"$MAYHEM_JOBS" --output-on-failure >"$LOG" 2>&1
status=$?
cat "$LOG" >&2

# Extract counts from ctest's summary ("... X tests failed out of Y").
TOTAL=$(grep -oE 'out of [0-9]+' "$LOG" | tail -1 | grep -oE '[0-9]+' || echo 0)
FAILED=$(grep -oE '[0-9]+ tests failed' "$LOG" | tail -1 | grep -oE '[0-9]+' || echo "")
if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ]; then
  echo "test.sh: could not parse ctest output / no tests ran" >&2
  emit_ctrf "cmake-ctest" 0 1
  exit 2
fi
[ -n "$FAILED" ] || FAILED=$(( status == 0 ? 0 : TOTAL ))
PASSED=$(( TOTAL - FAILED ))

if [ "$status" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  echo "test.sh: all $TOTAL cmocka tests passed" >&2
else
  echo "test.sh: $FAILED of $TOTAL cmocka tests FAILED" >&2
fi
emit_ctrf "cmake-ctest" "$PASSED" "$FAILED"
