#!/usr/bin/env bash
#
# delta/mayhem/test.sh — RUN upstream's ENTIRE test suite (`make test` = unit-test +
# end-to-end-test) and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle — delta ships a real assertion suite:
#   - `cargo test`: 500+ unit/integration tests inside src/ (ansi, cli, config,
#     handlers, paint, parse_styles, wrapping, …) asserting exact rendered output,
#     parsed structures and config values against literal expected strings;
#   - tests/test_raw_output_matches_git_on_full_repo_history: golden-output diff —
#     `git log --patch --stat --numstat` over the repo's full history must byte-match
#     delta's --raw output after ANSI filtering (a neutered/exit(0) binary fails it);
#   - tests/test_deprecated_options: deprecated-option compatibility runs;
#   - tests/test_navigate_less_history_file: asserts delta creates/updates its less
#     history file correctly (behavioral file-existence + content assertions).
# build.sh pre-built both the test suite (cargo test --no-run) and the normal release
# binary the end-to-end scripts drive; this script only RUNS them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not available — cannot run the test suite" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi
if [ ! -x ./target/release/delta ]; then
  echo "./target/release/delta missing — build.sh did not pre-build the normal binary" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 2
fi

# ── 1. Upstream unit/integration suite: cargo test (Makefile `unit-test`) ─────────
# Image-default nightly toolchain; RUSTFLAGS cleared so nothing leaks in from the
# sanitizer build (matches the --no-run pre-build, so no recompilation happens here).
echo "=== cargo test (upstream unit/integration suite) ==="
out="$(RUSTFLAGS="" cargo test --no-fail-fast --jobs "$MAYHEM_JOBS" 2>&1)"; rc=$?
echo "$out"

# libtest prints one line per test binary:
#   test result: ok. 500 passed; 0 failed; 2 ignored; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' lines; treating as failure (cargo rc=$rc)" >&2
  emit_ctrf "cargo-test" 0 1 0; exit 1
fi

# ── 2. Upstream end-to-end scripts (Makefile `end-to-end-test`) ───────────────────
# Each drives the pre-built release binary and asserts behavior (golden git-output
# diff, deprecated-option runs, less-history-file semantics). Count one test per script.
export HOME="${HOME:-/tmp}"
DELTA_BIN="$SRC/target/release/delta"

# test_raw_output_matches_git_on_full_repo_history: golden diff of `git log --patch
# --stat --numstat` vs delta --raw over the checked-out history. Upstream CI runs it
# on an actions/checkout depth-1 clone; replicate that environment with a local
# depth-1 clone (offline: file:// from $SRC) — over the full multi-year history delta
# elides "Binary files ... differ" lines for .bin assets, a pre-existing upstream
# rendering difference upstream CI never exercises.
echo "=== tests/test_raw_output_matches_git_on_full_repo_history (depth-1, as upstream CI) ==="
rm -rf /tmp/delta-e2e && git clone -q --depth 1 "file://$SRC" /tmp/delta-e2e
if (cd /tmp/delta-e2e && bash "$SRC/tests/test_raw_output_matches_git_on_full_repo_history" "$DELTA_BIN") > /tmp/e2e.out 2>&1; then
  echo "PASS: test_raw_output_matches_git_on_full_repo_history"; PASSED=$(( PASSED + 1 ))
else
  echo "FAIL: test_raw_output_matches_git_on_full_repo_history"; tail -50 /tmp/e2e.out; FAILED=$(( FAILED + 1 ))
fi

echo "=== tests/test_deprecated_options ==="
if bash tests/test_deprecated_options "$DELTA_BIN" > /tmp/e2e.out 2>&1; then
  echo "PASS: test_deprecated_options"; PASSED=$(( PASSED + 1 ))
else
  echo "FAIL: test_deprecated_options"; tail -50 /tmp/e2e.out; FAILED=$(( FAILED + 1 ))
fi

# test_navigate_less_history_file asserts delta creates/updates its less history file;
# git only spawns delta's pager on a tty, so give the script a pty via util-linux
# `script` (upstream runs this from `make test` on developer terminals; their CI's
# darwin branch uses the same `script` trick).
echo "=== tests/test_navigate_less_history_file (under a pty) ==="
if script -qec "bash tests/test_navigate_less_history_file $DELTA_BIN" /dev/null > /tmp/e2e.out 2>&1; then
  echo "PASS: test_navigate_less_history_file"; PASSED=$(( PASSED + 1 ))
else
  echo "FAIL: test_navigate_less_history_file"; tail -50 /tmp/e2e.out; FAILED=$(( FAILED + 1 ))
fi

emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$IGNORED"
