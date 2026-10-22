# Settings initializer metadata evaluation — paired source preparation

**HELD, off-source only, uncompiled/native UNRUN.** Canonical Sources, frozen packets, defaults, assets, models, compiler, index and processes were untouched. This package contains relative COMMON and producer FIXED patches and readable proposed copies. Disposable two-file git-apply replay checks text composition only; it is not a typecheck or native original/fixed verdict.

## Confirmed producer and bounded change

Current `Settings.init` reads `diarizeChoice` from its existing defaults instance, then calls `Self.diarizationDefault(stored: diarizeChoice, modelsPresent: MeetingDiarizer.isDownloaded)`. The helper correctly uses `stored ?? modelsPresent`; **the actual caller eagerly evaluates the Bool modelsPresent argument** even when true/false is already stored. This is an unnecessary metadata evaluation, not evidence of stored false becoming true. Existing helper truth-table checks cannot qualify the actual singleton initializer's evaluation behavior.

COMMON retains that exact helper call and its eager evaluation. It wraps only the real RHS in an inline closure: scalar observer, then actual `MeetingDiarizer.isDownloaded`. The optional observer is nil in production and cannot replace the result. FIXED changes only the actual constructor expression to `diarizeChoice ?? { same observer; same actual getter }()`. Explicit true/false therefore suppress RHS evaluation; absent choice still reaches the real metadata getter. `diarizationDefault`, `initialDiarize`, later default refresh, stored key, Bool choices and all writers remain unchanged. No await, save, timer, second owner or cache is introduced.

## COMMON Settings configuration contract

Exact API (class is already MainActor):

```swift
static func configureNativeNotesAvailabilityProbe(_ probe: @escaping @MainActor () -> Void) throws
```

Configuration requires SelfTest running, exact `--selftest-native-termination`, the raw new Notes-settings mode, peer's admitted pre-owner binding predicate, no prior actual init entry and no prior probe installation. It reads no `Settings.shared` and never creates another Settings owner. The callback is a default-nil private static scalar observer. A private init-entry Bool is set only in the exact diagnostic mode at the first initializer body statement; production does not write it. This latch prevents accepting a too-late configuration as a fresh-singleton proof. The existing stored defaults member initializer precedes the body; it selects the existing harness suite under SelfTest, and the peer must seed that suite before any Settings access. There is no async/reentrant construction seam or constructor escape added.

The latch is diagnostic evidence only, not a production lifecycle registry. Peer must install the observer in `prepareBeforeOwnersIfRequested` before AppDelegate/DictationController or any actual Settings singleton access. Original/fixed processes use the same COMMON scalar observation and actual singleton getter; they do not construct Settings directly or use `initialDiarize` as a substitute.

## COMMON nonisolated metadata getter contract

Peer supplies the agreed APIs:

```swift
@MainActor enum NativeNotesSettingsSelfTest {
    nonisolated static var isRequested: Bool { /* raw --native-notes-settings-case presence */ }
    @MainActor static var isProbeConfigurationAdmitted: Bool { /* SAME trace, admitted preparation only */ }
    nonisolated static func metadataRootForGetter() -> URL?
}
```

The pseudocode bodies above are API requirements, **not implementations or a second fixture**. Agent_baseline owns their executable fixture. It must use typed immutable binding, exact accepted flags and pre-owner confinement; validate a real canonical EMPTY directory. Its nonisolated root getter rechecks the actual directory and sets sticky INVALID on the SAME trace on failure. No new mutable admission global/store is needed.

`MeetingDiarizer.isDownloaded` retains the current NativeDiarization branch first. The new exact Notes-settings branch then calls `metadataRootForGetter`; nil immediately returns false and **never falls through to modelsRoot**. The production path remains the existing modelsRoot. Its required-file `fileExists` checks and partial-download enumerator are unchanged: this remains actual metadata evaluation, not a mocked availability Bool. Empty-root validation belongs before owners and again in the peer getter; if that prerequisite is absent, do not execute this partial package or call false a passing fixture. Invalid directory/flag/binding/late init must be INVALID, never an owner-cache fallback.

## Pairing and qualification

Apply `COMMON.patch.txt` to the two exact current preimages pinned in manifest. Combine it with the peer's byte-identical executable `NativeNotesSettingsSelfTest` COMMON and parent-owned allowed flags/App native callback fields before any compilation. The peer must preserve its exact trace and before-owner suite seeding; this packet does not modify the parent/peer files. Original stops after all COMMON. Fixed then applies `FIXED-from-COMMON.patch.txt`; the only varied producer is actual Settings.init expression. `copy-only-replay.json` records exact two-file stage hashes.

Actual fresh-process original/fixed qualification remains required for stored false, stored true and absent key with the same real EMPTY directory. Expected evaluation contracts are source-derived: explicit choice uses zero RHS observations; absent uses one actual getter observation. These are not executed verdicts. Preserve the actual stored optional choice and effective Bool, no unexpected harness-key mutation, sticky invalidity, rejected late/double/outside-mode configuration, and unchanged existing diarization/native diagnostic branches. Observe through the actual singleton and actual hosted App entry; helper-only checks do not satisfy this gate.

The existing `SelfTestHarnessDefaults.suite` is the only seeded domain. Native mode must not be among saved-selection-copy exceptions. No owner defaults are read/written by preparation; no preference snapshot, asset metadata inspection or native run occurred here. Parent/serial owner must recheck exact current source pins, freeze peer/bootstrap COMMON, typecheck and qualify real original/fixed and related gates. Manager rebase and broader quit/native ownership remain held.
