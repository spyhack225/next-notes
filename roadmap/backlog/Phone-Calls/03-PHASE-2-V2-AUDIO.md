# Phase 2 — V2: Next talks on the call

Tasks `PH-14`…`PH-21`. **Every task in this phase is gated on G2 (DriverKit entitlement) **and** G3
(Developer ID and notarization) **and** PH-14's audio feasibility.** If any one of the three is no,
this phase does not happen and §6's fallback is evaluated instead.

**Nothing in this phase may be started before PH-13 closes.** A V2 that is half-built is a second
signed, notarized binary in a distribution that cannot ship one, and a `.dext` that half-works is
worse than no `.dext`.

---

## 1. Why this phase is written coarsely, and what that means

V1's tasks have steps, files, and test cases. **V2's are deliberately at the level of "what must be
true before this is worth building".** That is not laziness and it is not a placeholder:

- Three of the four dependencies are **outside this project** — Apple's entitlement policy, Apple's
  notarization requirements, and Phone.app's audio routing behaviour.
- The reuse surface is large and already verified: `RealtimeAudioSession` (1,018 lines, a measured
  100 ms barge-in budget), `AcousticEchoProcessor` (1,626), `LocalVoiceTurnDetector`, Pocket and
  Kokoro local TTS, `StreamingSpeechBuffer`. **V2's dialogue loop is assembly, not invention.**
- The genuinely new work — PH-15, the driver, its build, its packaging, its install — is not
  interesting, and it is where most of the lines are.

So each task here says what it must prove, what it reuses, what it must not touch, and what kills
it. A task gets steps when it gets to the front of the queue and its dependencies have closed.

---

## 2. PH-14 — The audio feasibility gate

**Effort:** hours, and it needs a `.dext` target to exist first  **Depends on:** PH-13, **G2**, **G3**
**Unblocks:** everything

**Goal:** prove, or fail to prove, the one thing V2 rests on:

> Can Next Notes **capture remote call audio** and **inject synthetic microphone audio into the
> call**, without SIP modification, private Phone framework injection, third-party virtual audio
> software, or manual Audio MIDI Setup?

**Exit criteria, in order of preference:**

1. A virtual device published by a `.dext` inside the app is selectable as **both** the input and the
   output **while a real call is up**, and a test app can route deterministic PCM into the call path
   and read remote call PCM back out.
2. **It cannot be done reliably with supported, public mechanisms** → §6.

**What to measure, and record:** one-way added latency (target < 80 ms), buffer underrun/overrun
behaviour at 48 kHz, and whether Phone.app keeps the selection across a call. **PH-01's report
records which audio device Phone.app exposes while a call is up** — that is the free first half of
this question, and it is why PH-01 asks.

**Do not**
- Do not build the dialogue loop, the ASR tuning, or the TTS work in the hope this succeeds. The
  predecessor's §23 is right that the two tracks join only after full-duplex call audio is proven.
- Do not automate an OS confirmation to force the routing. If it needs clicking, it is brittle and
  §6 applies.
- Do not write product code. This is a feasibility answer.

**Done when:** [ ] the answer is yes with measurements, or no with a date and a named fallback; [ ]
`STATUS.md`'s gate row and the Phase 2 gate row agree.

---

## 3. PH-15 — The DriverKit driver

**Effort:** 2,500 lines, mostly not features  **Depends on:** PH-14

**Goal:** a virtual duplex device that the app and the system can both use.

**This is the corrected layout. The predecessor put four `.cpp` files under
`Sources/NextNotes/Phone/Audio/AudioDriver/`, which cannot work** — a driver ships as its own
`.dext` inside a `.systemextension`, and it is a *second product*, not a folder.

### 3.1 What changes in the build

1. **A new SwiftPM target** in `Package.swift`, requiring the DriverKit SDK. Today the package has
   one `.executableTarget` (`NextNotes`) plus three support targets and a test target, and the
   executable's path assumes a single product. Whether the driver builds unconditionally or behind a
   flag is a `Makefile` decision, and **the flag must default to off while G2/G3 are open** so a
   developer without the SDK is not broken.
2. **A new bundle.** The `.dext` lives in `Contents/PlugIns/` of a `.systemextension`, and the app's
   `SystemExtensions.plist` declares the point identifier. The Makefile's `install` target — which
   today stages one `.app` and swaps it under
   `~/Library/Caches/NextNotesBuild/install.lock` — gains a second product and a verification step
   alongside the existing `codesign --verify`.
3. **A new install-time flow**, which is PH-16. A system extension requires user approval in System
   Settings and **is not active until then**, so the app must own a four-state journey, not a
   toggle.
4. **The `codesign` order for a bundle containing a `.systemextension`** follows Apple's documented
   order, and the release build uses `Resources/NextNotes.release.entitlements` (Makefile:232) plus
   the DriverKit and system-extension entitlements. Keep
   `cs.disable-library-validation` — it is there for llama.cpp.

### 3.2 What the driver must do

Publish a virtual input stream and a virtual output stream. 48 kHz. Mono or stereo as needed.
Float32 or the appropriate PCM. **Low-latency ring buffers with correct clock and timestamp
handling** — a driver with a drifting clock produces periodic glitches that look like a network
problem and cost a day to find.

### 3.3 App ↔ driver IPC

A bounded user-client protocol:

```text
Next Notes app → TTS PCM → driver user client → virtual microphone input
Phone.app       → remote audio → virtual output → driver user client → Next Notes ASR
```

**The exact topology is determined by PH-14**, because Phone.app's selectable input/output
behaviour is the critical platform dependency. Do not design it before the spike answers.

### 3.4 What kills this task

G2 refused, G3 incomplete, PH-14 negative, or Apple changing the entitlement. Any of those sends
this phase to §6.

**Red-first self-test:** `--selftest-call-audio` (PH-17) is the gate, not this task. This task's
test is **the loopback**: `TTS → virtual mic → capture → ASR` with no external call, measuring
latency and echo behaviour. It is Milestone 3 in the predecessor's plan and it is the first thing
that proves the driver does anything at all.

**Do not**
- Do not put the driver inside the app's source tree. It is a separate target and a separate bundle.
- Do not default the build flag on. It breaks a developer without the SDK, and a broken build is how
  a roadmapped feature gets quietly abandoned.
- Do not share the driver's buffers with `AudioCaptureHub`. Different graph, different latency
  class, different failure mode.
- Do not add a dependency without a licence check and a `THIRD-PARTY-NOTICES.md` entry.

**Done when:** [ ] a new target builds behind an off-by-default flag; [ ] the `.dext` is bundled and
signed; [ ] the loopback produces intelligible ASR; [ ] one-way latency is measured and recorded.

---

## 4. PH-16 — Install UX: four states, not a boolean

**Effort:** 500 lines  **Depends on:** PH-15

**Goal:** a nontechnical person enables call audio, approves it in System Settings, and knows what
is happening at each step.

```text
Enable AI phone calls

Next needs one audio component so it can
listen and speak during calls.

[ Enable ]
```

**The four states, and why a boolean is a lie here:**

```text
○ Call audio — not requested
◐ Call audio — requested; waiting for approval in System Settings
✓ Call audio — approved and installed
✕ Call audio — denied
```

The predecessor showed two states. **The gap between "enabled" and "working" is a trip to System
Settings**, and a two-state check would render a ✓ the moment the request was made — which is exactly
the "granted" appearance AGENTS.md warns about for every other permission in this app. A `denied`
state also needs somewhere to go, and it needs a repair row.

**Never** expose `DriverKit`, `dext`, `HAL`, `IOUserAudioDriver`, or "system extension" in the
consumer copy. `--selftest-ui-strings` fails per offender.

**Red-first self-test:** extend `--selftest-settings` and `--selftest-ui-strings`. Cases: the ◐ state
renders and contains **no** `✓`; the ✕ state renders with a repair link; the transition ◐ → ✓ happens
only when the system reports the extension is active, **not** when the user returned to the app; and
no consumer string contains a banned developer word.

**Done when:** [ ] four states render; [ ] ✓ only after the system says so; [ ] the repair path
works; [ ] `UI_STRINGS_OK`.

---

## 5. PH-17 — `CallAudioBridge`

**Effort:** 800 lines  **Depends on:** PH-15

```swift
actor CallAudioBridge {
    func start(callID: UUID) async throws
    func stop() async

    var remotePCM: AsyncStream<AudioPCMBuffer> { get }
    func writeAgentPCM(_ buffer: AudioPCMBuffer) async throws
}
```

Responsibilities: connect to the virtual device · provide incoming PCM · accept outgoing PCM · avoid
buffer starvation · resample where necessary · timestamps · mute/unmute · detect underrun/overrun ·
meters for diagnostics.

**This is a new low-latency path in a codebase that has already paid for one.** Three things to
carry across:

- `RealtimeAudioSession` owns the **existing** duplex session, with `duckedVolume = 0.65` on the
  output and a 100 ms barge-in stop budget enforced by `bargeInFailures()` (:516), pinned by
  `--selftest-duplex`. **`CallAudioBridge` does not share the session object.** A call and a local
  voice turn are two different audio graphs, and `00-README` §11 puts both at P0.
- `Agent/VoicePlaybackDelivery.swift` already records output acknowledgements **separately from
  generated results**, because a completed clause is not proof of physical audibility. A call's
  TTS needs the same discipline: a synthesised sentence that the call path dropped is not a spoken
  sentence.
- `AcousticEchoProcessor` (1,626 lines) is the existing echo story for the *local* duplex. **Call
  echo is a different problem** — the far end's audio comes back through the device — so this task
  must not assume its results transfer. `--selftest-call-loop` measures the new path on its own.

**Red-first self-test:** `--selftest-call-audio`, then `--selftest-call-loop`. Cases: buffer health
and no underrun over 30 minutes of loopback; a timestamp discontinuity is **detected** rather than
silently resampled; a mute interrupts within one buffer; and **no recursive echo causes the agent to
trigger on its own speech** — the single release gate that matters most here, and the one a
synthetic test cannot fully prove. §7 requires a real 30-minute call.

**Do not**
- Do not reuse `RealtimeAudioSession`'s buffers or session.
- Do not assume `AcousticEchoProcessor`'s results transfer to a call path.
- Do not let a call's audio reach `AudioCaptureHub`, or a call will become a meeting recording.

**Done when:** [ ] the loopback is stable for 30 minutes; [ ] underrun is detected and reported;
[ ] the self-trigger case is green; [ ] the two audio graphs are provably separate.

---

## 6. PH-18 — Phone ASR and TTS

**Effort:** 600 lines, mostly tuning  **Depends on:** PH-17

```text
remote call PCM → VAD → streaming transcription → stable partial/final turns → PhoneDialogueLoop
```

Target: **remote speech end → stable text < 500 ms**, measured on real calls.

Everything exists: `Transcription/ParakeetEngine.swift` (local CoreML),
`Transcription/AppleSpeechEngine.swift`, and `Activation/LocalVoiceTurnDetector.swift` wrapping
FluidAudio's `StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 320)`. What is new is
**telephone-band robustness** — 300 Hz–3.4 kHz, narrowband, and often worse than that — and a new
`WorkClass` rung at P0 **alongside** `realtimeASR`, not above it.

TTS reuses `Agent/Speech/StreamingSpeechBuffer.swift` (clause-by-clause streaming while generation is in
flight), `PocketAgentVoice` (`PocketTtsManager(precision: .int8)`, warmup 0.55 s → 0.08 s) and
`KokoroAgentVoice` (`af_heart`). **Kokoro refuses to run on macOS 26.4–26.5** because CoreML crashes
in Apple BNNS, and a call is exactly the latency-critical, clause-heavy case the streaming buffer was
built for.

**Red-first self-test:** `--selftest-call-loop` extended with telephone-band fixtures. Cases: a
narrowband fixture transcribes to the expected text; **Pocket is resident and warm** before the first
TTS, and the test asserts the warm path rather than a cold one; the streaming buffer's first clause
lands within the target; and Kokoro's CoreML crash is asserted as **refused**, not as a silent
fallback to a voice that does not work.

**Do not**
- Do not raise `realtimeASR` above the call lane, or a call will compete with the user's own speech.
- Do not add a new TTS engine.
- Do not treat a telephone-band result as equivalent to the meeting/dictation ASR numbers. It is not,
  and the `--selftest-transcribe` score does not transfer.

**Done when:** [ ] telephone-band fixtures green; [ ] the warm path is asserted; [ ] the CoreML
refusal is a refusal.

---

## 7. PH-19 — The dialogue loop, disclosure, barge-in, hold, IVR

**Effort:** 1,800 lines  **Depends on:** PH-18

```swift
enum PhoneDialogueState {
    case introducing
    case listening
    case thinking
    case speaking

    case waitingOnHold
    case confirmingDetail
    case askingUser

    case objectiveCompleted
    case unableToComplete
    case ending
}
```

Worker prompt, and note the last block is enforced rather than suggested:

```text
CALL OBJECTIVE
Ask for a dental appointment Thursday after 2 PM.

KNOWN USER CONSTRAINTS
Prefer 2:00–5:00 PM. Do not book Friday.

AUTHORITY
May ask questions and gather availability.
May NOT commit an appointment without user approval unless explicitly preauthorized.

IDENTITY
You are an automated assistant calling on behalf of <name from agent-identity.json>.
Do not claim to be the user.
```

**Disclosure** (PH-19's hardest requirement, and it is a legal one — see `00-README` §12's G4):
> "Hi, I'm an automated assistant calling on behalf of Alex. I'm calling to ask about…"

Wording is configurable; the **meaning is not**. The name comes from `agent-identity.json` through
`AgentGrounding`, never a literal — `--selftest-persona` fails a hardcoded one, and a call is the
most consequential place to get that wrong.

**Barge-in** reuses the interruption architecture. **Call barge-in must be independent of the user's
local microphone barge-in** — different audio source, different graph. Coupling them means a person
talking at their desk interrupts a call they are not on.

**Hold detection** is conservative, over long non-speech audio, a recurring music-like signal,
explicit phrases, and extended silence after IVR. During hold: pause expensive reasoning · keep
lightweight detection running · resume on speech · **do not repeatedly announce into the call.**

**IVR/DTMF comes last and is not a blocker.** If there is no stable public mechanism for injecting
DTMF into an active Phone call, **mark it unsupported rather than automating UI clicks unreliably.**

**Red-first self-test:** `--selftest-call-bargein`, `--selftest-call-hold`, `--selftest-call-loop`.
Cases: a remote interruption stops TTS within the 150 ms target and the state becomes `listening`;
**a local microphone barge-in does not stop call TTS and a remote one does not stop local voice
speech** — the independence case, asserted both ways; hold pauses reasoning and resumes once;
a repeated hold does not re-announce; and the disclosure sentence is spoken verbatim with the
runtime name, with a case that a hardcoded name fails.

**Do not**
- Do not let the agent claim to be the human, in any wording.
- Do not couple the two barge-in paths.
- Do not automate an IVR through UI clicks.
- Do not make IVR a release blocker.

**Done when:** [ ] barge-in independence is green **both ways**; [ ] hold is conservative;
[ ] disclosure is asserted with the runtime name; [ ] IVR is marked supported or explicitly not.

---

## 8. PH-20 — User intervention, preauthorization, consequential actions

**Effort:** 700 lines  **Depends on:** PH-19

**The ask.** The far end offers two slots. The phone worker says *"one moment while I confirm"* —
which is the one thing it may say without permission, because it is about the user and not to the
far end. Then the result goes out as `TaskEvent.needsInput` and **the agent presents it**:

```text
Dentist has 2:30 or 4:45 Thursday. Which one?
   ↓
4:45.   → back to the worker; the call resumes
```

Channels: iMessage · the island · a notification · an active voice session. The worker does not
speak it, and it does not go out over the call's own audio.

**Preauthorization.**
```swift
struct PhoneDecisionPolicy {
    var mayBook: Bool
    var allowedDateRange: ClosedRange<Date>?
    var allowedTimeRange: ClosedRange<DateComponents>?
    var maxPrice: Decimal?
    var excludedConditions: [String]
}
```
The worker commits **only** inside those bounds. Anything outside needs the user.

**Consequential actions during a call** — booking, accepting a price, agreeing to a service,
cancelling a reservation, changing an account setting:

```text
remote party proposes
   → the worker understands
   → ActionIntent
   → policy
   → authorized by preapproval?  ── yes → continue
                                └── no  → ask the user
```

**The dialogue model is never the permission system.** Booking is a *different tool* that does not
exist yet; when it does, it is `.write`- or `.purchase`-class and `PermissionPolicy.allowsAutomatically`
already refuses it. The call is a context, not an authority.

**Red-first self-test:** `--selftest-call-intervention`, `--selftest-tool-review`. Cases: an
`askingUser` state produces a `needsInput` and **not** speech on the call's audio; a commitment
inside the bounds proceeds; **one step outside the bounds asks the user**; an un-preauthorized
booking never reaches `ActionOrchestrator`; and the "one moment" sentence is the only thing the
worker says to the far end without permission.

**Done when:** [ ] the ask goes out through the right channel; [ ] bounds are enforced; [ ] no
commitment bypasses the Action Runtime.

---

## 9. PH-21 — Transcript, outcome, and the no-blind-redial policy

**Effort:** 700 lines  **Depends on:** PH-20; soft AGENT-OVERHAUL P6

**Transcript.** `PhoneCallTurn { at, speaker, text, confidence? }` with speakers `agent`, `remote`,
`userIntervention`, `system/ivr`. **Raw audio is transient; the transcript follows the call-history
setting.** Live audio processing is not persistent recording, and the product must not blur them.

**Outcome.**
```swift
struct PhoneCallOutcome {
    let summary: String
    let objectiveCompleted: Bool
    let facts: [String]            // the shape AgentTaskOutcome already uses; see below
    let commitments: [PhoneCommitment]
    let followUps: [String]
    let referenceNumbers: [String]
    let transcriptReference: String?
}
```
**Correction (2026-09-25):** the earlier draft said `facts` and `followUps` were "the spine's
existing types" and named `AgentResultFact`. **That type does not exist** — 0 hits in `Sources/`.
The real result type is `AgentTaskOutcome` (`Agent/Tasks/AgentTaskManager.swift:336`). A phone
outcome is *that* struct's shape plus call-specific fields, not a parallel result model. If AO's
P6 lands a structured facts type, this is the line to widen — and it is the reason to check before
writing it.

**The durable job.** A call is a task in `agent-jobs.sqlite` with `TaskRecord` and `TaskDurability`.
**Do not add an `AgentJobKind` enum** — `TaskRecord.backend` already carries `AgentBackendKind`, and
`TaskDurability.runtimeClass` is the right home. Persist the id, objective, contact, call state,
runtime, timestamps, a transcript checkpoint, the dialogue state, and any user questions.

**And the rule that matters most:**

```text
If Next Notes crashes during a live call:  do not automatically redial.
On relaunch:  "Phone call interrupted. I didn't automatically call back."  [Call again]
```

**Do not persist enough state to recreate an already-ended cellular call after restart.** This is
AO Phase 6 §2.6's receipt rule applied to a call: a consequential action is never re-fired blind,
and a call is more consequential than an email because the far end is a person who has been put on
hold.

**Red-first self-test:** `--selftest-call-recovery`, **CORE**. Cases: a crash mid-call produces
`unverifiable`, **never a redial**, and the copy names that it did not call back; a call already
ended is not recreated; the transcript respects the retention setting; and the outcome's
`objectiveCompleted` is `false` when the far end never answered, rather than inferred optimistically.

**Do not**
- Do not redial. Ever.
- Do not store raw audio by default.
- Do not infer success from silence.
- Do not add a second result model or a second receipt.

**Done when:** [ ] the no-redial case is green; [ ] retention is honoured; [ ] the outcome is
honest about an unanswered call.

---

## 10. The V2 release gates

Every one of these is a `[ ]` in `STATUS.md`, and **G4 (legal review) is on this list** — it is not
something this roadmap can close.

- [ ] The DriverKit entitlement (G2) is available.
- [ ] **Developer ID and notarization work end to end** (G3).
- [ ] Driver installation works for a nontechnical user, **including the System Settings approval
      step**, and the four states render honestly.
- [ ] Phone.app uses the required virtual audio routes reliably (PH-14).
- [ ] Full-duplex audio survives a 30-minute test call.
- [ ] ASR accuracy is acceptable on telephone-band audio, measured on real calls.
- [ ] Barge-in works under real remote speech, and is independent of the local mic both ways.
- [ ] **No recursive echo causes the agent to self-trigger.**
- [ ] The person can take over the call and terminate it.
- [ ] The agent identifies itself appropriately, in every configured wording.
- [ ] High-risk call categories are blocked or restricted.
- [ ] **No blind redial after a crash.**
- [ ] Consequential commitments require policy authorization.
- [ ] Raw audio is not stored by default.
- [ ] Call transcript privacy controls are implemented.
- [ ] **Legal review obtained for calling, recording and disclosure in every supported market (G4).**
- [ ] Physical-device dogfood completed — a consenting human, a business, a hold, an interruption.

---

## 11. What will still have never run

Add to `AGENTS.md` as each task lands, and copy here at the phase gate:

- **No call has ever been placed by this app.** Parakeet has transcribed meeting and dictation audio
  on this machine; **a 300 Hz–3.4 kHz band through a virtual device has not been tested once.**
- **No `.dext` has been built, signed, installed, or enabled.** No entitlement, no Developer ID, no
  notarization, no Phone.app routing proof.
- **The disclosure wording has not been reviewed by anyone whose job is that.** A bot placing calls
  under a person's identity in several jurisdictions is a legal question, and this roadmap's §12
  G4 is a gate with an owner rather than a task.
- **V2 is the version with no shippable path.** If G2, G3 or PH-14 is no, this phase is abandoned and
  §6's fallback is evaluated — and the fallback must not be UI-clicking an IVR, because that is the
  brittleness the whole split of V1 from V2 was meant to avoid.

## 12. The fallback, if the audio cannot be routed

Evaluate, in order, and **do not compromise**:

```text
no SIP modification
no private framework injection
no UI-clicking a system dialer
nontechnical-user setup
```

1. **Core Audio process taps for capture, plus another supported injection route.** The app already
   uses `AudioHardwareCreateProcessTap` for a meeting's system track
   (`Core/SystemAudioCapture.swift`), so capture is the half that is proven. Injection is the half
   that is not.
2. **A tightly scoped native companion** — only if Apple provides a public path.
3. **Cloud/SIP telephony** as an entirely separate architecture, separately consented, and a
   different product with a different privacy posture. Not a toggle in this one.

**And if none of them works: stop, ship V1, and say so.** V1 is a real feature that a person can
use every week. A V2 that ships with brittle UI automation is a worse product and a worse
reputation.
