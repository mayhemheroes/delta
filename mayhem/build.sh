#!/usr/bin/env bash
#
# delta/mayhem/build.sh — build dandavison/delta's `delta` binary twice:
#   1. FUZZ target (debug assertions on, full DWARF-2 debug info) → /mayhem/delta —
#      the Mayhem target. delta is a diff-processing CLI that reads a unified/git
#      diff on stdin (the historical mayhemheroes target `delta` fuzzed exactly this
#      stdin path with 29k+ edges and real findings; the target name, input mode and
#      build flavor — -g + -Cdebug-assertions=on, unsanitized — are preserved).
#      ASan (-Zsanitizer=address) was tried and reverted: Mayhem's coverage tracer
#      reports edges_covered=0 for the ASan-instrumented Rust binary (run #13,
#      otherwise healthy), which hard-fails the edges>0 integration gate, while the
#      historical unsanitized flavor measured 29,259 edges and 83 defects.
#      -Cdebug-assertions=on still turns arithmetic overflow / debug asserts into
#      crashes — the source of the historical findings.
#   2. NORMAL flags (plain `cargo build --release`) → ./target/release/delta, plus
#      `cargo test --no-run` — the pre-built test suite that mayhem/test.sh RUNS
#      (upstream's full `make test` = cargo test + three end-to-end scripts).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): this first (online) build populates the cargo
# registry under $CARGO_HOME=/opt/toolchains/rust/cargo (fixed, $HOME-independent).
# The PATCH tier re-runs this script OFFLINE with CARGO_NET_OFFLINE=true exported by
# the runtime — every crate resolves from that in-image cache (do NOT pass --offline
# here; it would break this first build).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (cargo's
# cc-built C deps — onig_sys, libgit2-sys, libz-sys — invoke the C compiler).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── DWARF < 4 debug-info contract (§6.2 item 10) ──────────────────────────────────
# The rlenv runtime may export RUST_DEBUG_FLAGS before the offline re-run; default
# forces DWARF 2 so Mayhem triage / gdb resolve project source lines.
# -C strip=none: modern cargo strips debuginfo from release binaries by default
# (profile strip=debuginfo); RUSTFLAGS come after the profile flags, so this wins.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C strip=none -C force-frame-pointers=yes -C llvm-args=--dwarf-version=2}"

# Rust's prebuilt ASan runtime (librustc-nightly_rt.asan.a) carries DWARF 5 CUs and is
# linked before project code. Strip its debug sections once so it contributes none.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
    echo "Stripping debug info from Rust ASan runtime to enforce DWARF < 4: $ASAN_RT"
    objcopy --strip-debug "$ASAN_RT"
fi

# C deps compiled by the cc crate (onig_sys, libgit2-sys, libz-sys) respect
# CFLAGS/CXXFLAGS — force DWARF 3 for those CUs too. Stable across the offline
# re-run, so cargo's fingerprints stay valid (no recompilation).
export CFLAGS="${CFLAGS:+$CFLAGS }-gdwarf-3"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }-gdwarf-3"

TRIPLE="x86_64-unknown-linux-gnu"

# ── 1. Fuzz-target build (historical flavor: debug assertions, unsanitized) ───────
# Rust sanitizer instrumentation would be driven via RUSTFLAGS, NOT clang's
# $SANITIZER_FLAGS (rustc ignores those; the base's $SANITIZER_FLAGS ENV default —
# ASan+UBSan, halting — still applies to any clang-driven compiles).
# -Zsanitizer=address was validated end-to-end but reverted — Mayhem's coverage
# tracer measures 0 edges on the ASan Rust binary (see header) — so the target keeps
# the historical productive flavor: -Cdebug-assertions=on (arithmetic overflow /
# debug asserts crash). The explicit --target keeps build scripts / proc-macros
# (host artifacts) on plain flags.
#
# Baked default ASan options (detect_leaks=0 — allocate-and-exit batch CLI) via
# __asan_default_options remain linked (inert without ASan, correct for a future
# re-sanitized build; Mayhem owns the runtime ASAN_OPTIONS, which overrides these).
ASAN_DEFAULTS_OBJ="$SRC/target/asan_default_options.o"
mkdir -p "$SRC/target"
"${CC:-cc}" -c -gdwarf-3 mayhem/asan_default_options.c -o "$ASAN_DEFAULTS_OBJ"

FUZZ_RUSTFLAGS="${RUSTFLAGS:-} -Cdebug-assertions=on -Clink-arg=$ASAN_DEFAULTS_OBJ ${RUST_DEBUG_FLAGS}"
echo "=== cargo build --release --target $TRIPLE (fuzz target: debug-assertions) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo build --release --target "$TRIPLE"

bin="$SRC/target/$TRIPLE/release/delta"
[ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
cp "$bin" /mayhem/delta
echo "built /mayhem/delta (debug-assertions, DWARF-2 debug info)"

# ── 2. Normal-flags build: release binary for the end-to-end scripts + unit suite ──
# Separate default target dir (target/$TRIPLE vs target/) keeps the two builds from
# thrashing each other's caches; test.sh only RUNS these, never compiles.
echo "=== cargo build --release (normal flags, for tests/test_*) ==="
RUSTFLAGS="" cargo build --release
[ -x "$SRC/target/release/delta" ] || { echo "ERROR: normal release binary missing" >&2; exit 1; }

echo "=== cargo test --no-run (normal flags, pre-building the unit/integration suite) ==="
RUSTFLAGS="" cargo test --no-run --jobs "$MAYHEM_JOBS"

echo "build.sh complete:"
ls -la /mayhem/delta
