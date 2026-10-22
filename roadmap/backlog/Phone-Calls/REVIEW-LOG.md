# Next Notes Phone Calls — review log

Written 2026-09-25. The audit this folder was built from, what was checked, and what is open.

---

## 1. What this replaced, and the six substantive changes

The predecessor was `roadmap/todo/NextNotes_Phone_Call_V1_V2_Roadmap.md`, 1,796 lines of prose
roadmap. It was **deleted** and replaced by this folder. Six changes are substantive.

### 1.1 G3 exists: Developer ID and notarization are a second gate

The predecessor's §21 named the DriverKit entitlement as "a V2 program risk" and told the reader to
start it early. Correct, and incomplete. AGENTS.md's "What isn't built" §1 says **notarization and
code signing are not built** — the release image is ad-hoc or locally signed.

So a `.dext` today:

- cannot be **stably signed** on this machine, because an ad-hoc signature produces a different
  designated requirement on every compile;
- cannot be **notarised**, so it cannot be distributed;
- and needs an entitlement attached to a certificate the project does not have.

**Any one of G2 (entitlement) or G3 (distribution) failing ends V2.** The predecessor budgeted for
one blocker and described two. G3 is also worth doing on its own — it unblocks the app's own release
— so PH-03 is shared work, not phone work.

### 1.2 The call detector will arm a meeting for Next's own call

`Meetings/CallDetector.swift` and `CallPolicy.isCall` (`Meetings/CallPolicy.swift:114`) already work:
they read `kAudioProcessPropertyIsRunningInput` / `…IsRunningOutput`, require **both**, exclude our own
pid, and apply the denylist at `:54` (`com.apple.CoreSpeech`, `com.apple.speech.speechsynthesisd`,
`com.apple.assistantd`, `com.apple.Siri`, `com.apple.accessibility.AXVisualSupportAgent`,
`com.apple.replayd`, our own bundle id — **nine entries in total** at `CallPolicy.swift:54`; an
earlier draft of this line listed seven and understated the denylist.)

So a call `PhoneCallController` places **is a call by that definition**, and it will arm a meeting —
recording the user's phone call through the meeting pipeline, diarizing it, generating notes, writing
both tracks to `audio.caf`, unasked.

The predecessor's V1.8 said "a phone call ≠ meeting recording by default" and read it as a policy
statement. **It is a code change**: the marker in PH-09, the check in PH-12. The symptom if missed is
not a feature being off — it is a phone call silently appearing in the Meetings list, which reads as
data loss. That is why PH-12 exists as a task with a CORE flag, and why it is sequenced **with**
DICTATION-MEETINGS-LIMITS M-11 rather than around it.

### 1.3 The driver is a second binary, not a source folder

The predecessor's §6 put `NextNotesAudioDriver.cpp` and three siblings under
`Sources/NextNotes/Phone/Audio/AudioDriver/`. An AudioDriverKit driver ships as its own `.dext`
inside a `.systemextension`, installed by the app and approved in System Settings. It means a new
SwiftPM target, a new bundle, a second product in a Makefile `install` that today stages one `.app`
under `install.lock`, a new `codesign` invocation, and a new verification step.

"Add four files" and "add a second signed, installed, notarized, user-approved binary to the
distribution" are different projects. The predecessor's plan budgeted the first and described the
second, which is why its V2 estimate was wrong in a way nobody would have found until PH-15 was
already a week old.

### 1.4 `tel:` from a background app has a measured precedent for failing

The predecessor proposed `NSWorkspace.shared.open(URL(string: "tel:…"))` and moved on. It is public
API and it is the right mechanism. What it did not anticipate is that **Next Notes is, by design, a
background app during an agent turn** — the HUD is a non-activating panel and focus never leaves the
user's field.

This repo has already measured the consequence: `NSRunningApplication.activate()` "is refused often
enough to be useless alone, because macOS's cooperative activation resists a *background* app raising
another — and Next Notes is always background during a dictation, by design." The fix that shipped
is **two mechanisms plus polling**: `activate()` **and** `kAXFrontmostAttribute` through the
Accessibility grant.

So PH-01's Q1 asks the question the predecessor assumed, and PH-09 carries the same treatment. The
verification levels then distinguish "the OS accepted my request" from "a call UI is on screen" —
which is the same discipline the app already applies to every other grant it cannot read.

### 1.5 The vocabulary, again

The predecessor was written the same day as the multi-agent roadmap and inherited its unexamined
names. It is now corrected in place: `TaskBridge.spawn` for `spawn_agent`, `OutputScheduler` for
`AgentResultBus`, `TaskRecord` for `AgentJob`, `TaskEvent.needsInput` for
`AgentResultEvent.needsInput`, `TaskDelivery` for `AgentJobKind`, and `RealtimeAgent.swift:4-8` for
"the spine's `AgentUtteranceSource`". The two sibling roadmaps were corrected in the same pass.

**And one correction the predecessor got wrong about its own dependency:** it described
`FunctionCallRelevance.consequentialIDs` (`:177`, "14 ids") as something `phone.place_call` "joins" so
a lane "picks it up automatically". **It is `private static let`**, so nothing outside that file can
read it. PH-07 asks for a public accessor and shares it with AGENT-OVERHAUL's action-lane work,
rather than adding a second grading.

### 1.6 The receipt and the approval are shared, not duplicated

The predecessor proposed a `PhoneCallReceipt` type and, separately, an iMessage approval mechanism.
Both already have better homes:

- `ActionReceipt` (`Agent/ActionRuntime.swift:285`) and `ActionReceiptStore` (:329,
  `action-receipts.json`, already on the isolation list) record a `PreparedAction` and its
  verification. **A phone receipt is that receipt's payload.** A fourth store would mean
  "prepared payload equals payload fired" is asserted in one place and enforced in another — and for
  a phone call that difference is the difference between a work line and a mobile.
- Remote approval is IM-13's `RemotePreparedAction`, which already reserves a `phoneCall` case.
  `00-README` §6 makes "no second approval matcher" a rule, and the two folders' `STATUS.md` rows say
  so in both directions.

---

## 2. What was checked

- **Every anchor this folder cites was re-verified by grep on 2026-09-25** against `78cebc9`:
  `RealtimeAgent.handle` `:258` and `AgentUtteranceSource` `:4-8`; `ActionIntent` `:97`;
  `PreparedAction` `:226`; `ActionReceipt` `:285`; `ActionReceiptStatus` `:255`;
  `ActionReceiptEvent` `:269`; `ActionReceiptStore` `:329`; `ActionOrchestrator` `:382`;
  `verifyResult` `:638`; `PermissionBroker.authorize` `:13`;
  `PermissionPolicy.allowsAutomatically` `Permissions/PermissionPolicy.swift:114`; `AgentRisk`
  `AgentModels.swift:10`; `FunctionCallRelevance.consequentialIDs`
  `Agent/FunctionCalling/FunctionCallRelevance.swift:177` (**`private static let`**);
  `RealtimeAudioSession.duckedVolume` `:49` and `bargeInFailures()` `:516`;
  `RealtimeAudioSession` is 1,018 lines; `AcousticEchoProcessor` is 1,626;
  `CallPolicy.deniedBundleIDs` `:54` and `isCall` `:114`; `AudioProcessOwner.outermostAppPath` `:19`;
  `IslandState.Kind.callQuestion(MeetingEvent)` `UI/Island/IslandState.swift:82`;
  `SelfTestStoreGuard.fileNames` `:24`; `SelfTest.isRunning` `NextNotesApp.swift:85`;
  `SettingsTab` `UI/Settings/SettingsWindow.swift:93`; `SettingsTab.case agent` `:101`;
  `AgentSettingsTab`'s six existing sections; `Makefile:37` identity detection, `:70` entitlements,
  `:232` the release entitlements; `Resources/NextNotes.entitlements` (not sandboxed, carries
  `automation.apple-events` and `cs.disable-library-validation`); `Knowledge/PersonResolutionStore.swift`
  at 500 lines with the `person_entity` table and `merged_into` chain.
- **The absence of telephony was checked, not assumed.** `tel:`, `Phone.app`, `com.apple.Phone`,
  `AudioDriverKit`, `AVCaptureSession`: **0 hits** across `Sources/` and `windows/`.
  `AVCaptureDevice` appears 6 times, **all of them permission probes**, not capture.
  `AudioHardwareCreateProcessTap` appears only in `Core/SystemAudioCapture.swift` — a meeting's
  system track, which is the existing precedent for call-audio *capture*.
- **The call-detection finding was checked against the real code**, not inferred from the roadmap:
  `isCall` is input **and** output, and `deniedBundleIDs` is a denylist of nine entries by design
  ("a conferencing app nobody here has heard of has to work on the day it is installed").
- **`IslandState.Kind.callQuestion` already exists** and carries a `MeetingEvent`, so the island's
  call surface is a reuse rather than a new state.
- **The `osascript` finding was carried across** from the iMessage pass: the app lists `osascript` on
  `Shell/ShellExecutor.swift:7`'s `privilegedPrefixes`, so anything that shells out to it demands
  approval every time. V2 has no equivalent, but the rule is recorded.
- **The live-workstream overlap was checked.** DICTATION-MEETINGS-LIMITS owns `Meetings/CallPolicy.swift`
  via M-02 (done) and M-11 (todo); AGENT-OVERHAUL owns `Agent/RealtimeAgent.swift`, the tool
  manifest (P1-03) and durable tasks (P6); the iMessage folder owns the Contacts permission and
  `RemotePreparedAction`. Every one of those is written into a task's **Depends on** line as a soft or
  hard edge.

---

## 3. Known open issues, carried into the tasks

1. **The V1/V2 split assumes a platform capability nobody has verified.** PH-01 measures the first
   half (does `tel:` raise Phone.app from the background) and PH-14 the second (can a virtual device
   be routed into a live call). If **PH-01's answer is that the raise needs the dictation treatment**,
   V1 grows — and that is a design input, not a bug.
2. **Whether Phone.app even appears in `kAudioHardwarePropertyProcessObjectList` with both flags set
   is unknown.** If it does not, `CallPolicy` may never see an agent-launched call, PH-12's exemption
   is untestable by nature, and `--selftest-phone-meeting` proves only the marker path. The task
   says to report which, rather than letting a green flag imply coverage.
3. **Call echo is a different problem from local echo.** `AcousticEchoProcessor` (1,626 lines) is the
   local duplex story and its results should not be assumed to transfer to a far end coming back
   through a device. PH-17 measures the new path on its own, and "no recursive echo causes the agent
   to self-trigger" is a release gate that a synthetic test cannot fully prove.
4. **A new `WorkClass` rung is needed and the ladder has a documented deadlock.** The app's rule is
   that the on-device model's single native context must be reserved **before** acquiring a compute
   ticket, or actor reentry corrupts inference state and reverse lock order deadlocks. A phone
   worker reasoning on the same local model as the live voice turn, while call audio sits at P0, is
   exactly that shape. PH-18 names it; the sequencing constraint belongs in AO's compute work too.
5. **Emergency-number lists are jurisdiction-specific and go stale.** PH-06's block is correct in shape
   and its list is a guess until someone owns it. It belongs with G4's owner, not in a Swift file
   that nobody revisits.
6. **`PhoneNumberNormalizer` correctness is unverifiable without a device.** E.164 canonicalisation
   has edge cases — extensions, `+` prefixes, local formats — and the test can only check the ones
   written down.
7. **V2's task list is coarse on purpose and that is a known gap.** PH-15 through PH-21 say what must
   be true, what to reuse, and what kills them; they do not carry V1's step-level detail because their
   dependencies are outside the project. **That detail is written when a task reaches the front of
   the queue** — and if PH-14 is negative, it is never written at all, which is the correct outcome
   rather than a shortfall.
8. **Two folders share four things and neither owns them.** The Contacts permission, IM-02's
   self-conversation target, IM-03's grants report and IM-13's `RemotePreparedAction` are all
   dependencies of this folder and all live in `NextNotes-iMessage/`. There is no shared location, so
   reorganising that folder breaks this one silently. Both ledgers say so in writing.
