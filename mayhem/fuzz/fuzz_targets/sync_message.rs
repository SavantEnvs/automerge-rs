#![no_main]
// MAYHEM: additive harness (not part of upstream's own fuzz/, which ships only `load`).
// Fuzzes automerge::sync::Message::decode — the wire-format parser for the sync protocol
// messages peers exchange over the network (untrusted input, distinct attack surface from
// the on-disk document format that `load` exercises: length-prefixed vecs of ChangeHash,
// a bloom filter, a ChunkList of Change chunks, and an optional flags byte — see
// rust/automerge/src/sync.rs Message::parse).
use automerge::sync::Message;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = Message::decode(data);
});
