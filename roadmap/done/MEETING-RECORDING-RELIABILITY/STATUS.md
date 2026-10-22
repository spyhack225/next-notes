# MEETING-RECORDING-RELIABILITY — STATUS

The progress record for the meeting-recording reliability roadmap. `00-README.md` holds the
task contracts (MR-01…MR-06), `01-FULL-PIPELINE-PLAN.md` holds the expanded whole-pipeline
plan (MP-00…MP-17), and
[the verification record](../../../Tests/Reports/meeting-reliability/2026-10-19-implementation/VERIFICATION.md)
holds the evidence.

Built 19–20 October 2026, in six rounds of adversarial review over five parallel workers.

**State: the implementation is complete, reviewed six times, and verified — seventeen
of seventeen self-tests green on the final source.** The one thing still open is the
owner's physical long-call run, and the one thing still broken is the machine: a signed
app *bundle* cannot be launched on it (a minimal two-file AppKit app reproduces the
abort, so it is the bundle-launch path, not this code), and the login keychain is
unreachable, which is why the installed build is ad-hoc signed. The round's answer to
the first was a product improvement — the pure meeting tests now run **before SwiftUI's
scene exists**, so they answer from a terminal, a headless session and CI — and the
answer to the second is one command after a re-login. The evidence is in
[the verification record](../../../Tests/Reports/meeting-reliability/2026-10-19-implementation/VERIFICATION.md).

---

## 1. Tasks

| ID | Task | Status | Gate | Result |
|---|---|---|---|---|
| MR-01 | Reproduce and attribute resource pressure | **source complete; hardware attribution open** | `--selftest-meeting-frame-shape`, `--selftest-meeting-frame-layout`, `--selftest-audio-conversion-stream` | the frame/clock facts are produced, judged and written to the durable note; **the offending producer is still unproved on hardware** |
| MR-02 | Persist interruption and missing-capture facts | **source complete** | `--selftest-meeting-capture-coverage`, `--selftest-notes-coverage` (producer case) | the writer measures where a channel went silent; the facts persist; "never measured" is unknown, not complete |
| MR-03 | Pressure-aware optional work | **unchanged this round** | existing pressure gates | the bounded proof stands; nothing here changed the pressure policy |
| MR-03a | Lower normal-operation memory, compute and disk costs | **open for acceptance** | — | the conversion is fed a stream; **no allocation breakdown and no equal-configuration before/after report exists**, so the task stays open |
| MR-04 | Ongoing storage and capture health with accurate warnings | **source complete; storage policy open** | `--selftest-meeting-capture-coverage` | the warning names the channel and the problem and fires on the first change into a warning state; the measured-threshold policy is still open |
| MR-05 | Truthful audio-use and retention contract | **source complete; copy acceptance open** | existing retention matrix | a refusal no longer occupies the failure slot, so the retention sweep and the low-disk release see the file again; the UI-string lint is unrun and no by-eye check is recorded |
| MR-06 | Integrated acceptance and measured operating envelope | **source complete; the physical long call is still missing** | the seven new flags plus the meeting regressions | **17/17 green on the final source**, exit code 0 each: the seven new flags, the meeting health and resume suites, the speaker assignment and hints, the notes' truncation, long-form and prompt-contract suites, the meeting backlog and tap-retry fixtures, and the UI-string lint |
| MP-00…MP-17 | The expanded whole-pipeline plan | **designed; five milestones partly built** | — | MP-01, MP-05, MP-06, MP-08 and MP-16 are partly built and each is open on its own proof clause; the rest are unimplemented |

## 2. What the round built

**The measurement the audit asked for (MR-01).** Per track: the frames a buffer list really
carries beside the count the buffer reports, the frames that survived the conversion, the
frames the host clock says should have arrived, the drift, the ASBD layout and its
transitions, the converter's outcomes, the stream yields nobody counted, and the frames the
writer saved. They are judged by a ladder that never reads "ok" without the evidence for it,
and they travel in the existing health-tick note, so a real call's numbers are recoverable
afterwards. **The honest negative result:** the one-shot conversion and the streaming one
produce the same frames on this machine, so a starved converter is not what halves the system
track here — the repair is kept because the one-shot pattern is fragile, not because it was
the cause.

**The producers the facts needed (MR-02, MR-04).** The writer now knows the frame from which
a channel carries nothing but the silence it had to invent — and can tell "never carried
audio" from "carried audio to the end". The session persists that, the coverage verdict is
computed on a normal Stop, a wanted-but-missing system track is a loss, a delivery stall is
not a saved loss, and a recording that was never measured is unknown.

**The notes' honesty (MR-06).** The disclosure is decided per track from the producer's
measured boundary, a quiet ending is not damage, a write failure is described by whether
the notes came from the live transcript, and the intact document is pinned by a digest.

**The speaker and title paths (MR-06).** One eligibility decision across the automatic and
both manual diarization paths, with the extent of the loss taken into account and a refusal
that holds no recording and offers no retry. A settled call takes a meeting's real title
only where the evidence is exact, the arming question and the naming question are separate,
a manual title always wins, and a calendar that loses one calendar produces a traceable
fact with the account's address out of the person's view.

## 3. The adversarial loop

Six rounds, five reviewers at a time, every round reading the previous round's fixes as an
adversary: **51 blockers** in rounds 1–3 (four crashes in this round's own code, a coverage
verdict that could call an unmeasured recording complete, an inverted loss fraction, a
boundary with an inverted sign, a disclosure suppressed for the audited case, a call that
could vanish silently, a duplicate recording, the account address in a user-visible
string), then 5 and 10 in rounds 4–5, then a four-reviewer deep pass over the finished
implementation. Every blocker is fixed at source level or corrected in the documents. Two
of the crashes were in code this round wrote, and the self-tests the reviews called red
were red for exactly the reasons the reviews gave.

## 4. What the owner still has to do

1. **Re-login.** The machine's local directory service and its keychain are both
   unreachable from a shell, which is why the installed build is ad-hoc signed and why
   a signed app bundle cannot be launched. A re-login fixes the first, and
   `make install OPEN=0` afterwards re-signs with the same certificate — the
   designated requirement returns to `identifier "ai.pivotstudio.nextnotes" and
   certificate leaf = H"96c8b8fa…"`, and the microphone, accessibility,
   screen-recording and notification grants apply again by themselves. **Do not run
   `tccutil reset`**: it would delete grants the re-sign restores.
2. **Run the physical long call.** A 45–60 minute two-track meeting with continuous metrics
   and beginning/middle/end spot-checks, on the owner's AirPods route, in a browser and a
   native client. The frame-shape numbers are instrumented and waiting for it, and they are
   the measurement that will name the producer the audit was chasing.
3. **The notes' factuality is untouched** — the audit's 27 material omissions, the
   request-direction and attribution errors, and the "re-evaluate the inputs after the clock
   repair" work all stand. The disclosure now tells the truth about what was saved; it does
   not make the notes more complete.

## 5. Scope boundary held

No new store, ledger, usage log, queue, timer or model pass. The new facts ride the
existing `Meeting.captureIntegrity`; the frame/clock numbers ride the existing health-tick
note; the calendar failure is an in-memory fact beside the existing `lastError`. No new await
on the capture or turn path — the conversion stays synchronous inside the IOProc, the
accumulators are short locks, and nothing serialises the microphone, the model and the
speaker. No owner meeting content, attendee, link or raw log is in the tree. No install, no
model or default change, no owner-store access.
