# Settings eager availability producer remedy review

**SOURCE-ONLY CANDIDATE / NOT APPLIED / HELD for original-flow verification.** Root is sole Source/build/native/assets/install/owner-quit owner. This packet grants none of those actions. No compiler, interpreter, app, preferences, filesystem model metadata, weights or native runtime was executed/read. Original full-process crash, native parent contracts, 5 ms lifecycle and aggregate readiness remain open.

## Confirmed source contract and one-line candidate

Settings.init reads `diarizeChoice` from its existing defaults object, then eagerly evaluates `MeetingDiarizer.isDownloaded` as an argument of `diarizationDefault`. The helper returns `stored ?? modelsPresent`. Even a stored true/false therefore causes an availability filesystem check whose result cannot affect the answer. Actual Native Notes setup reaches this initializer via `LlamaBackend.initialize → Settings.shared.llmMetalEnabled`; NotesService.notesBrief also reaches it.

The proposed relative FIXED patch repairs that producer call site directly:

```swift
meetingsDiarize = diarizeChoice ?? MeetingDiarizer.isDownloaded
```

Swift's existing nil-coalescing operator evaluates its right autoclosure only when needed. No new helper, abstraction, store, Settings instance, constructor escape, asynchronous hop, confirmation, flag-based model availability fake or permanent global override is added. The existing helper/onboarding tests may remain as pure answer checks; they are insufficient to verify this actual initializer boundary.

Semantics to preserve: explicit true stays true whether models exist or not; explicit false stays false; no stored choice still uses the actual model presence; a non-Bool stored value stays equivalent to absent choice. meetingsDiarizeChoice remains the same original read, and no stored choice is written by Settings.init. applyDiarizationDefaultIfUnchosen keeps its existing real check only after its nil guard; chooseDiarization remains the sole ordinary preference writer. No MeetingDiarizer loader or actual native runtime is changed by this candidate.

## Notes bootstrap through the existing preference domain

A future byte-identical Notes COMMON fixture may, after immutable exact flag/path/public-asset admission and before NSApplication/AppDelegate or any Settings.shared use, seed `Settings.Keys.meetingsDiarize = false` in the **existing** `SelfTestHarnessDefaults.suite`. This is an explicit synthetic diagnostic choice in the already existing per-process domain, not another Settings/defaults store or constructor bypass. Require exact SelfTest mode and `allowsSavedModelSelection == false` before touching the suite, and prove the domain is the existing suiteName rather than the owner's domain. Do not read owner dictionaryRepresentation for a negative control here. The suite's existing cleanup removes only its own domain. After actual Settings initialization, require its actual `usesHarnessPreferencesForTesting`, explicit false choice and false resolved result. The valid private seed is identical before both producer versions.

That seed alone does not fix the old eager producer. It becomes effective only through the actual lazy producer change. Source-only inspection cannot certify that initialization occurs after seeding on every real launch; a fresh owned subprocess with the actual standalone entry and Settings singleton must prove ordering. Do not use a custom Settings constructor, reset static singleton, private clone or precomputed helper to replace the real path.

## Actual producer qualification still required

Original/FIXED comparisons need the same COMMON instrumentation at the **actual initializer RHS entry**, not a test of diarizationDefault or a standalone `??` expression. A nil-default bounded scalar observer can count whether that RHS executes. The actual first initialization must occur in fresh owned subprocesses for explicit true, explicit false and absent choice; one singleton cannot be reinitialized by mutating defaults later. Optional wrong-type behavior needs an actual typed-defaults read, not an invented Bool result. Existing onboarding assertions check resolution semantics, while the actual Notes setup checks ordering and real consumers.

**Unresolved original-run safety:** the old producer executes the owner-root availability read despite an explicit private false. An observer alone does not prevent that read. No original run is authorized here. Before executing it, the serial runtime owner must review a byte-identical COMMON confinement of the existing MeetingDiarizer availability metadata route into validated supplied temporary filesystem assets (through the existing root-selection seam), or explicitly qualify the required metadata read within its ownership contract. This must still exercise actual filesystem checks; a stub return, simulated native event or helper-only test cannot establish the original Notes path. Do not blanket-disable all SelfTest availability or change actual diarization copied-asset diagnostics. No concrete confinement patch is supplied by this candidate; that prerequisite remains HELD for review.

For the fixed explicit false Notes case, verify no availability-RHS entry and no model-root metadata access before the genuine real copied GGUF load; actual native entry/return and Cocoa votes remain separate required evidence. The nil-choice controls must continue to run actual availability through an appropriately admitted filesystem route. Missing safe COMMON confinement is INVALID/unavailable input, not producer RED. No before/after run or product fix is claimed by this packet.

## Handoff

Relative candidate contains one producer hunk and only that hunk. Preserve unrelated moving root work; do not transplant a whole Settings snapshot. Required gates: actual initializer before/after regression, original Notes bootstrap and downstream runtime consumer, existing onboarding/settings/store isolation, actual copied-model Notes/native/Cocoa qualification and unchanged relevant voice/permission/latency checks. Compilation and original/fixed native verdicts are UNRUN. Root review precedes canonical implementation.
