# Quit owner composition after Controller helper change

**Status: HELD, source-only, uncompiled, native unrun.** This packet mechanically rebases the frozen [composition-current](../../reliability-quit-preparation-2026-10-03/composition-current/README.md) patches onto the current source copies. It changes no canonical or frozen source. `manifest.json` pins ten current preimages, six relative patches and every copied-source stage. `source-only-replay.json` records patch application and hash checks on disposable copies only.

## Why this rebase exists

Of the ten frozen composition preimages, only `Sources/NextNotes/Core/DictationController.swift` changed. Its current `withBoundedWait` has `joinCancelledWork: Bool = false` and, only when explicitly selected after cancellation, awaits the **same** job's value. The current Core preimage is SHA-256 `971b783422d52841cf3115862943fc68fc5ff548fa717cd5a15744ee5f35fb6b`. All seven replayed stages preserve the complete helper function byte-for-byte; no new foreground join or independent wait is introduced here. The other nine current preimages still match the frozen composition pins.

## Relative patch map

Apply patches at the copied repository root, starting only from the pinned `currentPreimages`:

1. `union-COMMON-current.patch.txt` creates `unionCommon`: frozen S1 cancellation and Cocoa entry, direct33, and independent Pocket57 fixtures/private seams. It excludes Kokoro and `late19` owned-cleanup.
2. From that same COMMON, apply **one** independent candidate: `fixed-S1-from-union.patch.txt`, `fixed-direct33-from-union.patch.txt`, or `fixed-Pocket57-from-union.patch.txt`. Their pinned results are `s1OnlyFixed`, `directOnlyFixed`, and `pocketOnlyFixed`.
3. For a source composition check only, apply S1, then `fixed-direct33-after-S1.patch.txt`, then `fixed-Pocket57-after-S1-direct33.patch.txt`. Results are `s1Fixed`, `s1DirectFixed`, and `allFixed`. The ordered Pocket patch carries the App context after S1.

`source-only-replay.json` verifies all eight copied stages (including `canonical`) against the exact postimage hashes, all six patch hashes, the four unchanged frozen fixture hashes, and the identical Core helper body. The frozen input fixtures, public asset guards, startup dispatcher order and existing `drained &&` all-final-reply veto remain source-level inputs. No fixture assertion was relaxed to make this rebase apply.

## Native admission still required

The serial owner must first qualify each original failure with the same private fixture and then its corresponding fixed producer on isolated native runs. S1 requires the real Cocoa should-terminate callback and native formatter return/final reply. Direct33 requires the frozen two-partial/no-audio case, original F01/F02/F03 failures, real quit entry and consumer-state checks; it does not prove physical capture, a spoken tail or final typed insertion. Pocket57 requires its actual loaded/injected playback tuple, early unavailable guard, native/session/consumer counts and final reply. The ordinary build without the private Pocket observer must remain valid. Preserve recording, Notes, final-transcript, diarization, ASR, other-Llama and the same one-shot safety drain.

The combined fixed stage is **not** a release verdict. No compiler, model, native test, installed quit, latency or crash check was run for this packet. It establishes neither safe process exit nor absence of SIGSEGV. The dependent late-input `late19` cleanup and combined Kokoro owner remain held separately.
