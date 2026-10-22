# Phase 1 — V1: Next starts the call, the user talks

Tasks `PH-05`…`PH-13`. Contact resolution · an approval card · `tel:` · a truthful receipt · a call
that does not become a meeting.

**Do not start any of it until G1 (PH-01) has closed.** PH-09's implementation depends on the
answer to "does the OS raise Phone.app from a background app", and PH-10's verification levels
depend on which signals exist on this macOS.

This phase is ordinary work on an Action Runtime that already exists. It is the shippable half of
the roadmap and the half a user gets value from.

---

## 1. PH-05 — Readiness, and the Contacts permission

**Effort:** 1 day  **Depends on:** PH-01  **Unblocks:** PH-06

**Goal:** a consumer screen that says what is true, including the one thing it cannot know.

**Files you will change**
- `Sources/NextNotes/Phone/PhoneReadiness.swift`, `PhoneReadinessProbe.swift` (new)
- `Sources/NextNotes/Phone/PhoneConfiguration.swift` (new)
- `Sources/NextNotes/Phone/Contacts/ContactPermission.swift` (new)
- `Sources/NextNotes/Support/Permissions.swift` — **one** new row for Contacts
- `Sources/NextNotes/UI/Settings/PhoneCallsSettingsSection.swift` (new — a **section** in
  `AgentSettingsTab`, not a thirteenth tab)
- `Sources/NextNotes/Phone/Tests/PhoneReadinessSelfTest.swift` (new —
  `--selftest-phone-readiness`)

**Read for context (do not change):** `Support/Permissions.swift` — four rows today, and the
documented approach for a grant with **no read API**: *"a tap without the grant succeeds and
delivers zeroed samples, so one non-silent buffer is proof the grant exists, and it is the only
proof there is."* That is the pattern for anything here that cannot be queried.

**Target behaviour**
```swift
struct PhoneReadinessSnapshot {
    var macSupported: Bool
    var contactsAuthorized: Bool
    var phoneHandlerAvailable: Bool
    var callContinuityLikelyReady: Bool
    var callAudioAvailable: Bool        // V2; PH-16 adds the system-extension states
    var issues: [PhoneReadinessIssue]
}
```

UI:

```text
Make calls with Next

✓ Mac is ready
✓ Contacts
○ iPhone calling

[ Finish setup ]
```

**"Calls on Other Devices" cannot be verified programmatically, and the field is named
`Likely` in the code for that reason.** The UI renders **"Check this setting"**, never a tick it
cannot earn. A false ✓ is worse than an empty circle: it is a claim the app cannot back, and the
person finds out at the moment they need a call.

**Contacts is one framework, one prompt, shared with the iMessage folder.** The iMessage folder needs
it to resolve the user's own address for sending to a self-conversation. **Two prompts for one
framework is a bug a user will report as two.** Coordinate with
`roadmap/in-progress/NextNotes-iMessage/03-PHASE-2-P1-SLICE.md`; if both need it, one row, one request.

**Red-first self-test:** `--selftest-phone-readiness`, INTEGRATION. Cases: a snapshot with
`callContinuityLikelyReady == false` renders **"Check this setting"** and contains no `✓` for that
row (assert the string, not the model); `phoneHandlerAvailable` is a real probe of the `tel:` scheme
handler and is `false` on a machine without it; an unknown issue renders as an issue and never as a
pass; and **the Contacts prompt is requested at most once per process** even when two screens ask.

**Do not**
- Do not add a `SettingsTab` case. A section is one file and one line in the tab's body.
- Do not add a second Contacts permission row, and do not prompt twice.
- Do not show a tick the app cannot verify. This is the whole task.
- Do not put "Continuity", "SIP", "E.164" or a bundle id in a user-visible string.

**Done when:** [ ] the four honest rows render; [ ] the unverifiable one says so; [ ] one Contacts
prompt; [ ] the shared row with the iMessage folder is recorded.

---

## 2. PH-06 — Contact resolution, normalization, and the emergency block

**Effort:** 1.5 days  **Depends on:** PH-05  **Unblocks:** PH-07

**Goal:** turn "Call Sarah" into **one exact telephone target**, or ask.

**Files:** `Sources/NextNotes/Phone/Contacts/` — `PhoneContactResolver.swift`,
`PhoneNumberNormalizer.swift`, `PhoneNumberDisambiguator.swift` (new);
`Phone/Tests/PhoneContactSelfTest.swift` (new — `--selftest-phone-contact`).

**Read for context:** `Knowledge/PersonResolutionStore.swift` (500 lines) — it already holds
`person_entity (id, kind, label, merged_into, method, score, reasons, meetings, decided_at)` with a
`person_entity_merged` index, and `resolve` follows the `merged_into` chain to its end, stopping at
a cycle. A "recently referenced person" is one `ORDER BY meetings DESC` away. **Do not build a second
identity system.**

**Target behaviour**
1. Resolution order, and the last step is the important one:
   ```text
   exact contact name
     ↓
   recently referenced person in the Knowledge Graph
     ↓
   contacts aliases / nicknames
     ↓
   partial name
     ↓
   clarify
   ```
2. **Two numbers means a question, not a choice.** *"Sarah Chen has mobile and work. Which one?"* —
   or, if a stable preference exists, *"Call Sarah's mobile?"* `00-README` §11 records this as a
   limit: silently choosing between a mobile and a work line is a real cost to a person.
3. `PhoneNumberNormalizer` stores canonical E.164 where possible and produces the display form
   ("ending in 0194"). It is **also what the emergency block uses**, so it is written once.
4. **The emergency-number block runs in `prepare_call`, before an `ActionIntent` exists.** This is
   load-bearing: in `place_call`, a user can be asked to approve a call to an emergency number.
   Normalize → classify emergency / short code / premium → policy. Premium-rate and short codes are
   refused outright.
5. A spoken confirmation shows the **masked** number, never the full digits — a TTS stream is a
   speakerphone, and a home and a mobile in full is more than a person needs to hear to say yes.

**Red-first self-test:** `--selftest-phone-contact`, INTEGRATION,
`PHONE_CONTACT_OK: <n> cases`. Cases: each resolution rung in order, and a name matching nothing
reaches `clarify` rather than picking the first contact; a contact with two numbers **always**
clarifies; normalization round-trips for a list of shapes including one with an extension and one
with a leading `+`; **every emergency and short code in a fixture list is blocked in
`prepare_call`** and the test asserts the block happens before any `ActionIntent` exists; a
premium-rate number is refused; and the spoken confirmation contains no unmasked number.

**Verify**
```bash
make build && make install OPEN=0
Scripts/run-selftest.sh --selftest-phone-contact
Scripts/run-selftest.sh --selftest-settings
Scripts/run-selftest.sh --selftest-ui-strings
make acceptance TIER=core
```

**Do not**
- Do not choose silently when ambiguity matters.
- Do not put the emergency block in `place_call`.
- Do not read a full number aloud.
- Do not invent a person-record store. `PersonResolutionStore` is the graph's, and a phone call does
  not create a new identity.
- Do not access Contacts before the permission is granted.

**Done when:** [ ] every resolution rung and the `clarify` fallback; [ ] the emergency block fires
before an intent exists; [ ] no unmasked number in any spoken string.

---

## 3. PH-07 — The action model

**Finding(s):** a consequence grade nobody outside one file can read  **Effort:** 1 day
**Depends on:** PH-06 **and AGENT-OVERHAUL P1-03**  **Unblocks:** PH-08

**Goal:** three tools, one registry, and no way for the model to dial.

**Blocked without P1-03.** `AgentCapabilityManifest` is the per-turn source of truth for tool
authority. Landing `phone.*` before it exists means two tool catalogues, and this roadmap has been
built specifically to avoid that. Write the `BLOCKED` note and wait.

**Files:** `Sources/NextNotes/Phone/Agent/PhoneAgentTool.swift` (new) + the manifest registration.

**Target behaviour**
1. ```text
   phone.prepare_call
   phone.place_call
   phone.cancel_call
   ```
2. **Canonical ids, no aliases.** `RealtimeToolSelection` checks the raw name against the allowlist
   *before* the registry resolves it, so a registered alias loses the rest of the plan — a measured
   bug class in this app. Register the canonical name or nothing.
3. `phone.place_call` is `.send`-class risk, so `PermissionPolicy.allowsAutomatically` already
   refuses it. Do not add a phone-specific auto-run rule.
4. The consequence grade: `phone.place_call` is a consequential action for the same reason an email
   is — the difference between a work line and a mobile is real to the person on the other end.
   `FunctionCallRelevance.consequentialIDs` is **`private static let`**
   (`Agent/FunctionCalling/FunctionCallRelevance.swift:177`), so this task needs a **public
   accessor** or a manifest-level equivalent, and it is the same accessor AGENT-OVERHAUL's action-lane
   work needs. **Ask for it once, in P1-03, and share it** — do not add a second grading.
5. **The model never executes a `tel:` URL.** `phone.place_call` produces an `ActionIntent`; only
   `ActionOrchestrator` produces a `PreparedAction` and only `PermissionBroker` authorises it.

**Red-first self-test:** `--selftest-phone-prepare` and `--selftest-phone-policy`, **CORE**. Cases:
`place_call` produces an `ActionIntent` with the exact masked target and is `awaitingApproval`
without a decision; `place_call` is refused by policy with no grant; an **emergency number never
reaches an approval card** (the PH-06 block, asserted at the action layer this time);
`prepare_call` for an ambiguous contact produces a clarifying question and **no** intent; and the
canonical ids resolve while a non-canonical alias does **not** — that last case is the
`RealtimeToolSelection` lesson, pinned.

**Do not**
- Do not add an alias.
- Do not let the model reach `tel:` directly.
- Do not add a phone-specific confidence threshold. Confidence is not comparable across tool sets —
  the same sentence scored 1.00 with 2 tools and 0.41 with 8. The filter is the manifest.
- Do not start before P1-03. See above.

**Done when:** [ ] three canonical ids in the manifest; [ ] no alias; [ ] both CORE flags green;
[ ] the public consequence accessor is shared with P1-03 rather than duplicated.

---

## 4. PH-08 — Approval

**Effort:** 1 day  **Depends on:** PH-07; soft IM-13  **Unblocks:** PH-09

**Goal:** the person sees the exact number and the exact purpose, and says yes.

**Local voice**

> User: "Call Sarah."
> Next: "Call Sarah Chen on mobile, ending in 0194?"  *(and, if one was given, the purpose)*
> User: "Yes."

**Remote (iMessage)** is **IM-13's `RemotePreparedAction`, not a second implementation.** PH-08
declares that `phone.place_call` submits through it — a `RemoteActionKind.phoneCall(PhoneCallRequest)`
case that IM-13 already reserves and this task fills. Frozen payload, expiry, exact-match on the
offering chat, and **two pending approvals with the reply `call` is a clarification.** If IM-13 has
not landed, record the soft dependency and ship the local half; do not build a remote matcher.

**Target behaviour**
1. `PhoneCallRequest` is `Identifiable, Codable, Sendable` with the id, contact, display name,
   phone number, objective, `source`, created-at, `risk`, and `approvalRequired`. Its `source` reuses
   the app's `AgentUtteranceSource` (`Agent/RealtimeAgent.swift:4-8`) — **do not add a parallel
   enum.**
2. **The payload is frozen at offer time.** A recomputation must not substitute a different number
   between the question and the approval.
3. Approval **expires** — a short window. A "yes" twenty minutes later is not consent to that call.
4. The card shows the number **masked** and, when present, the objective in the person's own words:
   *"Call the dentist and ask about Thursday?"*

**Red-first self-test:** extend `--selftest-phone-policy` (CORE). Cases: the local approval
produces exactly one `PreparedAction` whose target equals the confirmed one; the remote path submits
through `RemotePreparedAction` and **the two pending case clarifies**; an expired approval does not
fire; a declined approval leaves no `PreparedAction`; and the frozen payload equals the fired target
byte for byte.

**Do not**
- Do not build a remote approval matcher. IM-13 owns it; `00-README` §6.
- Do not let a re-resolved contact change the number after the question.
- Do not read a full number in the spoken card.

**Done when:** [ ] local approval is exact; [ ] the remote path routes through IM-13;
[ ] expiry and the two-pending case are green.

---

## 5. PH-09 — The launcher

**Finding(s):** a background app's `activate()` is refused, measured  **Effort:** 1.5 days
**Depends on:** PH-08, PH-01  **Unblocks:** PH-10, PH-12

**Goal:** the call actually starts, and the app knows whether it did.

```swift
actor PhoneCallLauncher {
    func launch(_ request: PhoneCallRequest) async throws -> PhoneLaunchResult
}
```

**Target behaviour**
1. `NSWorkspace.shared.open(URL(string: "tel:\(normalizedE164)"))` — public API, and the right
   mechanism. Then, per PH-01's Q1, the **raise**: `NSRunningApplication.activate()` **and**
   `kAXFrontmostAttribute` through the Accessibility grant, both followed by **polling**, because a
   launch arriving mid-raise lands somewhere else. This is the dictation path's shape; reuse it
   rather than inventing a second one.
2. **Do not automate away an Apple confirmation dialog if the OS requires one.** If PH-01's Q2 found
   a confirmation, the app waits for the person. Absolute rule.
3. **The agent-launched marker.** `PhoneCallController` marks every call it launched, with its
   `TaskID`, and `CallPolicy` consults that marker before arming a meeting. **Write it in this
   commit** — PH-12 wires the other side, but the flag is created here so no intermediate build
   leaves a window where a call arms a meeting. See §12 below.
4. The launcher returns a `PhoneLaunchResult` that distinguishes *dispatched* from *observed*, so
   PH-10 does not have to guess.

**Red-first self-test:** the launch needs a real device, so the **unit** half is a seam: a
`PhoneLaunchLauncher` protocol with a recording fake, asserting (a) the E.164 is built from the
normalized number and nothing else, (b) the marker is written before `open` is called,
(c) a confirmation dialog, if present, is **waited for and not clicked**, and (d) two launches in
quick succession produce two distinct `PhoneCallRequest` ids and both are refused by PH-13's
nonce rule while one is in flight.

The **live** half is `--selftest-phone-spike`'s background-app row, run by hand from PH-01.

**Do not**
- Do not click Apple's confirmation.
- Do not assume `open` succeeding means a call is up. PH-10.
- Do not skip the polling. A single `activate()` is refused often enough to be useless here.
- Do not mark the call as agent-launched *after* `open`. Before.

**Done when:** [ ] the marker exists and is written before the launch; [ ] the raise follows
PH-01's answer; [ ] the confirmation is waited for, never clicked; [ ] the seam's four cases green.

---

## 6. PH-10 — Verification, and the receipt

**Finding(s):** a successful URL open is not a call  **Effort:** 1 day  **Depends on:** PH-09
**Unblocks:** PH-11

**Goal:** say only what was observed.

```swift
enum PhoneCallVerification: Sendable, Equatable {
    case requestDispatched
    case systemCallUIVisible
    case dialingObserved
    case connectedObserved
    case endedObserved
    case unverifiable
}
```

**`PhoneCallState` is not the same as `PhoneCallVerification`, and conflating them is how a receipt
lies.** The state is what happened; the verification is how it is known — `observed`, `inferred`,
or `unknown`. A receipt that says `connected` and a receipt that says `connected (inferred after 30 s
of silence)` are different facts, and the UI must not render them the same.

**Target behaviour**
1. V1 ships even if only `requestDispatched` and `systemCallUIVisible` are available (PH-01's Q3).
2. **`.unverifiable` is a first-class answer** and the failure copy says so.
3. **`PhoneCallReceipt` is the payload of an `ActionReceipt`, not a fourth receipt store.**
   `ActionReceipt` (`ActionRuntime.swift:285`) and `ActionReceiptStore` (:329,
   `action-receipts.json`, already on the isolation list) already record a `PreparedAction` and its
   verification. A parallel store would mean "prepared payload equals payload fired" is asserted in
   one place and enforced in another — and this is the tool where that difference is a real cost to
   a person on the other end.
4. `normalizedNumberHash`, never raw digits. `00-README`'s data model had this right: avoid
   persisting a raw number when a contact reference or a hash is enough.

**Red-first self-test:** `--selftest-phone-receipt`, **CORE**. Cases: with no state signals, a
finished call's verification is `.unverifiable` and the rendered copy does **not** say "connected" —
**assert the string, because a model that claims connection it cannot see is the whole failure mode**;
an inferred state is labelled inferred; the receipt is an `ActionReceipt` with the phone payload and
no separate file exists; the receipt carries a hash and no raw digits; and the receipt's target
equals the approved `PreparedAction`'s target exactly.

**Do not**
- Do not claim "Call connected" without a signal.
- Do not create a receipt store.
- Do not persist a raw number.
- Do not conflate state with verification.

**Done when:** [ ] the unverifiable path is green **and asserts the copy**; [ ] inferred is labelled;
[ ] no new store; [ ] no raw digits on disk.

---

## 7. PH-11 — Call activity

**Effort:** 0.5 day  **Depends on:** PH-10  **Unblocks:** PH-12

**Goal:** the call is visible while it happens, and findable after.

**The island already has the state.** `IslandState.Kind.callQuestion(MeetingEvent)` exists at
`UI/Island/IslandState.swift:82` — it is used today for a *detected* call. **Reuse it; do not add a
call state.** What is new is a title and a duration for a call *we* placed.

```text
Calling Sarah
Ringing                 ← only where observable
Connected · 00:42       ← only where observable
Call ended
```

**Every line is gated on its verification level.** An unobservable `Ringing` is not rendered
dimmed — it is not rendered.

**Activity**, through `AgentActivityProjector` so the public title is "Calling Sarah Chen" and the
machine's own `detail` is one disclosure away:

```text
Call Sarah Chen
Started 3:42 PM
Duration 4m 12s
User handled conversation
```

**Do not store audio.** V1 stores a receipt and a row. A phone call is **not** a meeting recording
by default — and the enforcement is PH-12, not this screen.

**Red-first self-test:** extend `--selftest-island` and `--selftest-activity`. Cases: an
`unverifiable` call renders no `Ringing` or `Connected` line (assert the absence, not the presence of
a dimmed one); a verified call renders them; the Activity title is projected and carries no tool id;
and the duration comes from the receipt's timestamps rather than a wall clock read at render time.

**Done when:** [ ] only verified lines render; [ ] the projected title; [ ] no audio; [ ] the
duration is from the receipt.

---

## 8. PH-12 — An agent-launched call does not arm a meeting

**Finding(s):** `Meetings/CallPolicy.isCall` **will** arm a meeting for a call Next placed.
**Effort:** 0.5 day  **Depends on:** PH-09; **coordinated with DICTATION-MEETINGS-LIMITS M-11**
**Unblocks:** PH-13

**This is the highest-value 200 lines in the roadmap.**

**The problem.** `Meetings/CallDetector.swift` and `CallPolicy` already work: they read
`kAudioProcessPropertyIsRunningInput` and `…IsRunningOutput`, and `isCall` (:114) is **input AND
output both held**, with own-pid exclusion and the denylist at :54. When `PhoneCallController`
places a call through Phone.app, that detector sees it and arms a meeting — recording the user's
phone call through the meeting pipeline, diarizing it, generating notes, and writing both tracks to
`audio.caf`, without anyone asking for any of it.

**The symptom if this is missed is not "a feature is off." It is a phone call silently becoming a
Meeting in the list**, which a person reads as data they lost.

**The rule.** `phone call ≠ meeting recording by default` is a **code change, not a setting**:
`PhoneCallController` marks a call it launched (PH-09 writes the marker) and `CallPolicy.isCall`
consults that marker before arming.

**Coordination is mandatory.** DM **M-11** ("one recording per real meeting: call near an event
starts it, hang-up ends it, speech-aware overrun") is `todo` and owns the question *when a call
should arm a meeting*. PH-12 plugs an agent-launched call into M-11's answer. **Do not edit
`CallPolicy` while M-11 is in flight** — two answers to one question, and `CallPolicy` is shared.

The two questions are genuinely separable, and this is the split:

```text
M-11 answers:   which detected calls SHOULD arm a meeting?
PH-12 answers:  which calls Next placed itself must NEVER arm one?
```

**Red-first self-test:** `--selftest-phone-meeting`, **CORE**,
`PHONE_MEETING_OK` / `PHONE_MEETING_FAILED: a call armed a meeting`. Cases: a call with the
agent-launched marker set does **not** arm a meeting; a detected call without it still does (M-11's
behaviour is unchanged); a marker from a **previous session** does not exempt a new, unrelated
detected call — the marker's lifetime is the call's, not the app's; and `AudioProcessOwner.outermostAppPath`
resolution is unchanged, so a helper-keyed call is still attributed to its owning app.

**Do not**
- Do not make the exemption permanent. It is scoped to the call that carries the marker.
- Do not edit `CallPolicy` without M-11. See above.
- Do not add a "user asked for it" exception. If a person wants a call recorded, that is the
  meeting flow with its own consent, reached deliberately.

**Done when:** [ ] the marker is consulted; [ ] M-11's cases still pass; [ ] the flag is green and
its failure message names the symptom.

---

## 9. PH-13 — V1 recovery

**Effort:** 1 day  **Depends on:** PH-12  **Unblocks:** PH-14

**Goal:** every failure ends with the same four answers, and no call happens twice.

**Test these, all of them observable by a human:**
```text
Next Notes quits after launching
the iPhone disconnects mid-call
Phone.app quits
the Mac sleeps while dialing
the user declines the system confirmation
the contact was deleted
the number is malformed
Continuity is unavailable
a second call is attempted while one is in flight     ← PH-09's seam
```

**Every failure ends with:**

```text
what was attempted
whether a call was actually launched
whether anything else happened
what to try next
```

That is this app's standing failure-card philosophy and `AgentSpeechPolicy`'s silencers are what
keep a raw OS error number out of a spoken card. "The request was sent to the phone and the phone
refused it (error 40)" is not a sentence a person can act on.

**The nonce.** One call per request. A retry is a **new approval**, never a re-fire — the same rule
as an email, and the same reason. A call that was launched and then lost to a crash is `unverifiable`
on recovery, and the person is offered `[Call again]` rather than being called again.

**Red-first self-test:** extend `--selftest-phone-policy` and `--selftest-phone-receipt`. Cases: a
crash between launch and verification yields `unverifiable` and **not** a second launch; a
second request while one is in flight is refused with a plain reason; every failure's copy contains
the four answers and **no raw error number**; and a declined confirmation produces no receipt at all,
rather than a receipt saying "failed".

**Do not**
- Do not retry a launch automatically.
- Do not put a raw error in a card or in speech.
- Do not treat a crash after launch as a failed call — it is `unverifiable`, which is different.

**Done when:** [ ] the nine cases have answers; [ ] the four-answer copy is in every path;
[ ] no raw error text; [ ] no second launch.

---

## 10. Phase 1 exit, and the definition of done

`make test` passes. `make acceptance TIER=core` has not regressed. `PHONE_READINESS_OK`,
`PHONE_CONTACT_OK`, and the four CORE flags `PHONE_PREPARE_OK`, `PHONE_POLICY_OK`,
`PHONE_RECEIPT_OK`, `PHONE_MEETING_OK` all report `*_OK`. `--selftest-phone-spike` has been run by
hand and recorded.

**The V1 release gates, all of them `[ ]`-able in `STATUS.md`:**

- [ ] The system call launch works from a **background** app on the supported macOS versions.
- [ ] No private API is required.
- [ ] Contact ambiguity is **always** resolved.
- [ ] A remote or iMessage call requires approval.
- [ ] The emergency-number policy fires **before** an `ActionIntent` exists.
- [ ] No failure claims a call connected without a signal, and the copy is asserted, not reviewed.
- [ ] **No call is launched twice** after a retry or a restart.
- [ ] **An agent-launched call does not arm a meeting.**
- [ ] Phone calling can be disabled instantly, and the disable is local-only.
- [ ] No raw call audio is stored.
- [ ] No full phone number is spoken, stored, or logged.

Then copy this into `AGENTS.md` under "What has never run, on macOS" and leave it:

- **The app has never placed a call.** `--selftest-phone-spike` is a matrix a human runs; it is not
  evidence that a call connected.
- **`tel:` from a background app is a prediction, not a measurement**, until the spike runs.
- **Whether Phone.app appears in `kAudioHardwarePropertyProcessObjectList` with both flags set is
  unknown.** If it does not, `CallPolicy` may never see an agent-launched call, PH-12's exemption is
  untested by nature, and the flag proves only the marker path. Say which, in the report.
- **V1 is the only version with a shippable path.** V2 is behind three gates and PH-14.

**Report:** `Tests/Reports/Phone-Calls-P1-____.md`, with a flag → final line table before and after,
and PH-01's measurements as the baseline the performance targets are judged against.
