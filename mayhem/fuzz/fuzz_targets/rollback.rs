#![no_main]
// MAYHEM (mining branch): drives a few documents through put / empty commit / merge / rollback /
// save+load, three bytes per step: (opcode, doc a, arg b). Reaches the transaction rollback and the
// document save path that upstream commit f109811 changed.
use automerge::transaction::Transactable;
use automerge::{ActorId, Automerge, ReadDoc, ROOT};
use libfuzzer_sys::fuzz_target;

const DOCS: usize = 3;

fn new_doc(i: usize) -> Automerge {
    Automerge::new().with_actor(ActorId::from(vec![i as u8 + 1]))
}

fuzz_target!(|data: &[u8]| {
    let mut docs: Vec<Automerge> = (0..DOCS).map(new_doc).collect();
    for step in data.chunks_exact(3).take(64) {
        let a = step[1] as usize % DOCS;
        let b = step[2] as usize;
        let key = format!("k{}", b % 4);
        match step[0] % 5 {
            0 => {
                let mut tx = docs[a].transaction();
                tx.put(ROOT, key, b as i64).unwrap();
                tx.commit();
            }
            1 => {
                docs[a].transaction().commit();
            }
            2 => {
                let other = b % DOCS;
                if other != a {
                    let mut src = docs[other].clone();
                    docs[a].merge(&mut src).unwrap();
                }
            }
            3 => {
                let mut tx = docs[a].transaction();
                if b % 2 == 1 {
                    tx.put(ROOT, key, b as i64).unwrap();
                }
                tx.rollback();
            }
            _ => {
                let saved = docs[a].save();
                let loaded = Automerge::load(&saved).unwrap();
                assert_eq!(loaded.keys(ROOT).count(), docs[a].keys(ROOT).count());
                docs[a] = loaded.with_actor(ActorId::from(vec![a as u8 + 1]));
            }
        }
    }
});
