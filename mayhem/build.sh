#!/usr/bin/env bash
#
# automerge-rs/mayhem/build.sh — build the cargo-fuzz libFuzzer target(s), then precompile
# the `automerge` crate's own test suite for mayhem/test.sh to run.
#
# Two fuzz targets live in the additive mayhem/fuzz/ crate (see mayhem/fuzz/Cargo.toml for
# why upstream's own rust/automerge/fuzz/ -- which ships only `load` -- isn't used directly:
# adding a second [[bin]] there would modify a file upstream tracks):
#   - load.rs         byte-for-byte copy of upstream's fuzz_targets/load.rs (Automerge::load,
#                      the on-disk document-chunk format)
#   - sync_message.rs new harness for automerge::sync::Message::decode (the sync-protocol
#                      wire format -- untrusted network input, a distinct parser)
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE. This first
# (online) build populates the cargo registry under $CARGO_HOME (pinned, $HOME-independent
# -- see the Dockerfile). Do NOT pass --offline here; the rlenv runtime exports
# CARGO_NET_OFFLINE=true for the re-run.
#
# TOOLCHAIN: rust/rust-toolchain.toml pins stable 1.90 for the WHOLE rust/ subtree, which
# would silently hijack any bare `cargo` invocation under it (SPEC net-new brief §6, the
# gluesql trap). Every invocation below is therefore explicit: `cargo +$RUST_CHANNEL` for
# the sanitized fuzz build (needs nightly for -Zsanitizer=address), `cargo +$RUST_STABLE`
# for the oracle build (matches upstream's own pin / the automerge crate's MSRV).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

: "${RUST_CHANNEL:=nightly-2025-10-15}"
: "${RUST_STABLE:=1.90}"

cd "$SRC"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# ASan on by default; an explicitly EMPTY $SANITIZER_FLAGS disables it (build contract
# parity -- $SANITIZER_FLAGS itself is a set of clang flags rustc can't consume directly,
# so translate its on/off intent instead of passing it through verbatim).
RUST_SAN="-Zsanitizer=address"
[ -z "${SANITIZER_FLAGS+x}" ] || [ -n "${SANITIZER_FLAGS}" ] || RUST_SAN=""
# DWARF <= 3 debug info for triage (SPEC §6.2 item 10) -- threaded via RUST_DEBUG_FLAGS.
RUST_DEBUG_FLAGS="${RUST_DEBUG_FLAGS:--Cdebuginfo=1 -Zdwarf-version=3}"
# Fleet policy: disable LeakSanitizer (only) at build time via the __lsan_is_turned_off() hook in
# mayhem/lsan_off.c, linked into every fuzz binary. -g0 keeps the TU free of DWARF-5 CUs.
LSAN_OFF_OBJ="${TMPDIR:-/tmp}/lsan_off.o"
clang -O1 -g0 -c "$SRC/mayhem/lsan_off.c" -o "$LSAN_OFF_OBJ"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_SAN $RUST_DEBUG_FLAGS -Cforce-frame-pointers -Clink-arg=$LSAN_OFF_OBJ"
# libfuzzer-sys's build.rs, by default, compiles libFuzzer's own C++ sources from source via
# the `cc` crate at build time -- that build ignores CFLAGS/CXXFLAGS (cc::Build's own flags
# win) and links in DWARF-5 CUs from the base image's clang, which -Zdwarf-version=3 (a
# rustc-only flag) never touches. Point it at the base's prebuilt libFuzzer runtime instead
# (the same one the C/C++ side gets via $LIB_FUZZING_ENGINE) -- it ships with NO debug info
# at all, so it contributes zero DWARF-5 CUs, and libfuzzer-sys skips its from-source
# compile entirely.
export CUSTOM_LIBFUZZER_PATH=/usr/lib/llvm-19/lib/clang/19/lib/linux/libclang_rt.fuzzer-x86_64.a

# rustc's prebuilt sanitizer runtimes (compiler-rt) ship DWARF-5 CUs -- strip their debug
# info BEFORE linking, not after: the linker COPIES the relevant debug sections into the
# final binary at link time, so stripping the source .a afterward does nothing for a binary
# already linked against it. Idempotent: stripping an already-stripped archive is a no-op.
find "$RUSTUP_HOME"/toolchains/*/lib/rustlib/"$TRIPLE"/lib \
  -name 'librustc-*_rt.*.a' -exec objcopy --strip-debug {} \; 2>/dev/null || true

echo "=== cargo +$RUST_CHANNEL fuzz build (ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# cargo-fuzz's `find_package()` walks UP from the CURRENT DIR looking for the first non-fuzz
# Cargo.toml (the crate under test) -- it ignores --fuzz-dir for this purpose. $SRC (the repo
# root) has no Cargo.toml at all (the workspace lives at rust/), so cwd must be inside the
# automerge crate's own tree; --fuzz-dir then points (absolute, so it's cwd-independent) at our
# additive fuzz crate.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  ( cd "$SRC/rust/automerge" && cargo "+$RUST_CHANNEL" fuzz build --fuzz-dir "$SRC/$FUZZ_DIR" -O --debug-assertions "$t" )
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  # Regression guard: a Rust fuzz binary is dynamically linked by default (no cgo-style
  # trick needed, unlike Go) -- assert it so a target that somehow ends up static (and thus
  # invisible to LD_PRELOAD-based sabotage detection) fails the build loudly.
  file "/mayhem/$t" | grep -q 'dynamically linked' || { echo "ERROR: /mayhem/$t is not dynamically linked" >&2; exit 1; }
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la "${FUZZ_TARGETS[@]/#//mayhem/}"

# rust/Cargo.lock is gitignored upstream, so a cleaned tree loses it and an OFFLINE re-resolve of
# the whole rust/ workspace then fails ("failed to select a version for anyhow": automerge-cli's
# crates were never fetched). Seed it from the additive pinned copy so only the crates the
# automerge package actually needs are resolved, all already in the cargo cache.
[ -f "$SRC/rust/Cargo.lock" ] || cp "$SRC/mayhem/rust.Cargo.lock" "$SRC/rust/Cargo.lock"

echo "=== precompile the automerge crate's own test suite (hermetic, +$RUST_STABLE, normal non-sanitized flags) ==="
# Scope to the `automerge` package only: the rust/ workspace also has automerge-c
# (needs a C header toolchain) and automerge-wasm (needs wasm-bindgen + a JS toolchain),
# neither of which the fuzzed code (or this repo's commit image) needs.
( cd "$SRC/rust" && RUSTFLAGS="" cargo "+$RUST_STABLE" test -p automerge --lib --tests \
    --no-run --no-fail-fast --jobs "$MAYHEM_JOBS" )

echo "build.sh: done"
