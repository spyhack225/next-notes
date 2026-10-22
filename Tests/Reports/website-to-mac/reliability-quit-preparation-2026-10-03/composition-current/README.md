# Native quit owner composition: source-only preparation

**Status: HELD, UNCOMPILED, NATIVE UNRUN.** This is a patch composition over copied current source, not a source change or a release verdict. The file hashes and patch hashes in `manifest.json` are admission pins; `source-only-replay.json` records exact copy-only patch/postimage checks, not a compiler or runtime test. No model asset was read or copied.

## Scope and ownership

The union COMMON combines the existing S1 formatter cancellation fixture and additive Cocoa quit fixture, the frozen direct-dictation quit fixture rebased to current source, and the **independent Pocket57** playback fixture. It includes only their private diagnostic seams, flags and startup routing. `late19`, the late-start owned-cleanup revision and the combined Kokoro pair are excluded. It does not claim to solve all native teardown or stale dictation delivery.

The three FIXED patches are separate producer candidates: S1 formatter/Cocoa quit entry, direct dictation capture owner, and independent Pocket playback owner. They must be measured one owner at a time against the same admitted COMMON before their fixed bytes are accepted. The serial order below demonstrates source composition only; it is not permission to release a combined native change without each owner's original/fixed qualification.

## Exact patch stages

Start with a disposable copy of the current canonical source at `manifest.json` `sourcePreimages`. Use patch paths relative to the copy's repository root. The union is `union-COMMON-current.patch.txt`. Then each owner can be tested independently from that same union:

1. `fixed-S1-from-union.patch.txt` → `s1OnlyFixed`.
2. `fixed-direct33-from-union.patch.txt` → `directOnlyFixed`.
3. `fixed-Pocket57-from-union.patch.txt` → `pocketOnlyFixed`.

For a serial composition check only, apply S1, then `fixed-direct33-after-S1.patch.txt`, then `fixed-Pocket57-after-S1-direct33.patch.txt`. These produce `s1Fixed`, `s1DirectFixed`, and `allFixed` in the manifest. The independent direct patch and ordered direct patch have identical bytes. The ordered Pocket patch has different App context after S1, so use its explicitly pinned version. All seven copy-only paths match all 14 expected postimages in `source-only-replay.json`.

The input patches were rebased mechanically except for one COMMON context collision in `NativeStartupTerminationSelfTest.swift`: direct and Pocket both extend the private mode allowlist and dispatcher. The union retains **both** mode sets and places Pocket routing after direct and final-transcript routing, before ASR queue routing. The direct fixture remains parakeet-only without other-Llama startup; the added Pocket fixture requires its own loaded or injected playback tuple. The `Package.swift` diagnostic conditional stays confined to the Pocket fixture; the ordinary build must still be checked separately.

## Required original/fixed native admission

Run in a disposable, isolated environment with the relevant private fixture and asset guards; never use the owner's task store or installed app in daily use. The root owner controls compiler, build, native runs and installation. A source-only replay is insufficient for these gates.

- **S1:** Keep the frozen original 30-case formatter cancellation input and additive actual `AppDelegate.applicationShouldTerminate` Cocoa callback fixture byte-identical. The original must exhibit the targeted outstanding formatter-at-quit failure, while the fixed candidate must synchronously close admission and drain its actual native owner before the real final reply. The diagnostic first-reply/final-reply veto remains, including the existing other-Llama safety drain. Do not call a callback gate proof of a paused or interrupted C kernel.
- **Direct33:** Preserve the frozen two-partial/no-audio fixture (`NativeDirectDictationQuitSelfTest.swift` SHA `1734893ddca0f8a32c89c9e44466b502aea4f67080d8199459182f5e22fb508b`). Qualify the actual Cocoa quit entry with the synthetic first completed and second pending native partial, the current no-audio result before predecessor return, the first positive quit proposal, and the original F01/F02/F03 failures before testing the same fixed input. The fixture's final reply must remain a veto until `drained` **and** every other owner condition is true, with the same one-shot `safetyDrain`. Physical capture, a spoken tail, typed text and final insertion remain unverified; S1 empty-format evidence alone does not prove no stale final insertion.
- **Pocket57:** Preserve the independent conditional fixture (`PocketPlaybackTerminationSelfTest.swift` SHA `61a69fa27e2265f4a92919a7808452477bf8695995f6d91fca49635675e2add5`). Qualify active, predecessor, factory and closed input boundaries with the actual Cocoa `.terminateLater`/final reply callbacks and native/session/consumer counts. The diagnostic final callback retains the real proposed verdict before vetoing exit and calling its safe cleanup. A missing `NEXTNOTES_POCKET_OBSERVATION` build must fail early as unavailable before model asset/owner access. The separate Kokoro owner remains held.

Preserve the existing App recording, Notes, final-transcript, diarization, ASR, other-Llama and shared safety-drain paths during native qualification. Confirm ordinary build behavior and the related quit/selftest flags after each admitted owner. A combined fixed run, crash-free observation or source-level hash replay alone cannot promote a native owner.

## Source-only evidence and limits

`source-only-replay.json` records seven exact patch/postimage copy replays plus static preservation checks: single recording approval, captured Notes/final/diarization/ASR callbacks, other-Llama and direct veto/drain, synchronous S1/direct/Pocket begin paths, Pocket early unavailable guard, and both startup dispatchers. Those checks inspect source text only. They do not establish Swift compilation, private fixture qualification, timeout behavior, actual native return, no SIGSEGV, a safe process exit, or product latency. `manifest.json` pins every touched preimage and postimage, the frozen input patches, and the three exclusions.
