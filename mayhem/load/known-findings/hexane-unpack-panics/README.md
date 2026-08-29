# Panics in `hexane`'s columnar decoder on malformed `Automerge::load()` input

Found during integration (fork-mode fuzzing of the `load` target over ~35s, coverage still
climbing across every one of these — a healthy, actively-exploring target, not one stuck
rediscovering a single bug). `Automerge::load()` is a public API meant to be called on
**untrusted** document bytes (that's the whole point of the fuzz target); all three reproducers
below make it panic instead of returning `Err(AutomergeError)`, which is a denial-of-service class
bug in any process that calls `load()` on attacker-supplied data.

Root cause (shared): `hexane`'s `RleValue`/`RawColumnIter` decoders have an internal contract that
column data has already been *structurally* validated by an earlier pass, and use `.unwrap()` /
`.expect()` / `assert!()` on that assumption (see the doc comment on
`RleValue::unpack` in `rust/hexane/src/lib.rs`: "Decode a non-null value from slab bytes that have
already been validated during load."). All three reproducers show a case where that earlier
validation pass did not actually catch the malformed encoding, so the assumption is violated and
the decoder panics deep inside `automerge::change_graph::ChangeGraphCols::load` /
`automerge::storage::document::Document::reconstruct`.

## repro-rlevalue-unpack-unwrap (154111 bytes)
```
thread '<unnamed>' panicked at rust/hexane/src/lib.rs:354:37:
called `Result::unwrap()` on an `Err` value: InvalidNumber(IoError(Error { kind: UnexpectedEof,
message: "failed to fill whole buffer" }))
```
`RleValue::unpack` (`rust/hexane/src/lib.rs:353-355`) calls `Self::try_unpack::<C>(data).unwrap()`
unconditionally. A truncated RLE/Delta-encoded column (via
`DeltaDecoder::next` -> `RleDecoder::next` -> `RleValue::unpack`, reached from
`ChangeGraphCols::load` at `rust/automerge/src/change_graph.rs:931`) makes `try_unpack` return
`Err(InvalidNumber(..))`, and the `unwrap()` turns that into a panic.

**Suggested upstream fix:** either make the pre-load structural validation pass actually reject
this case, or change `unpack` callers reachable from `load()` to use `try_unpack` and propagate the
error instead of relying on the "already validated" invariant.

## repro-get-null-panic (154111 bytes)
```
thread '<unnamed>' panicked at rust/hexane/src/lib.rs:364:9:
unexpected null in non-nullable column
```
`RleValue::get_null` (`rust/hexane/src/lib.rs:361-365`) explicitly `panic!`s by default ("correct
for non-nullable types" per its own doc comment) -- but a malformed document can encode a null
run in a column typed non-nullable, and nothing upstream of this call rejects that before the
decoder reaches it.

## repro-slab-boundary-assert (196 bytes -- small, not minimized further)
```
thread '<unnamed>' panicked at rust/hexane/src/raw.rs:622:9:
RawColumnIter::take would cross slab boundary: want N, have M
```
`RawColumnIter::take` (`rust/hexane/src/raw.rs`) `assert!`s that the requested read fits in the
remaining slab bytes. A malformed length field in the raw column stream requests more bytes than
the slab has, tripping the assert instead of surfacing a decode error.

## Reproduce
```
cargo +nightly-2025-10-15 fuzz build --fuzz-dir mayhem/fuzz -O --debug-assertions load
mayhem/fuzz/target/x86_64-unknown-linux-gnu/release/load \
    mayhem/load/known-findings/hexane-unpack-panics/repro-rlevalue-unpack-unwrap
```
(or against the built `/mayhem/load` binary inside the commit image). All three are deterministic,
fast (well under a second), single-input panics -- not hangs -- so they are safe to keep as
standalone reproducers here. They are deliberately NOT in `mayhem/load/testsuite/`: seeds are
replayed on every Mayhem run, and a seed that panics on load is fine (crashes are exactly what the
target should find) but keeping the *known* reproducers separate keeps the starter corpus focused
on format-valid documents for coverage exploration.

The two 154111-byte reproducers are exactly `mayhem/load/testsuite/monday-meeting-notes.seed`
(minus a few mutated bytes deep in the encoded change graph) -- `-minimize_crash=1` could not
shrink them further within 20000 runs, which itself says something about how deep in the parse the
sensitive state is.
