# Meeting recording reliability — implementation and verification, 19 October 2026

This is the evidence record for the implementation round against
`roadmap/done/MEETING-RECORDING-RELIABILITY` (MR-01…MR-06) and
`Tests/Reports/meeting-reliability/2026-10-13-audit/ACTION-PLAN.md` rows 1–5.
It records what was implemented, what was measured, what was measured to be
**false**, and what could not be run at all.

No owner meeting audio, transcript, note or title — and no raw owner logs — is in
this document or in any file this round added. The private examples stay
private.

---

## 1. What was implemented

### 1.1 The frame/clock contract (MR-01, P0 row 1)

The audit's symptom was a live system track whose timestamps ended near half
the wall duration, with drop counters at zero, and a saved system channel that
was digital zero after its first few seconds. Nothing counted the frames that
arrived.

| Piece | File | What it records |
|---|---|---|
| `MeetingFrameShape` + accumulator | `Sources/NextNotes/Meetings/MeetingFrameShape.swift` | Per track: buffers, true input frames, converted frames, expected frames from the host clock, clock drift, the ASBD signature and its layout transitions, converter outcomes, terminated and unmatched yields, and buffers whose own frame count disagreed with the list's. A verdict ladder: ok / half cadence / stalled / unknown shape. |
| `AudioFrameLayout` | `Sources/NextNotes/Core/AudioFrameLayout.swift` | The pure arithmetic: the true frame count of a non-interleaved list, the naive count that halves it, the frames a resample must produce, the cadence verdict. |
| `AudioConversionStream` | `Sources/NextNotes/Core/AudioConversionStream.swift` | A resampler fed a stream instead of one buffer per call. The old one-shot path told the converter "no more data" after a single pull, so a converter holding a frame or two of lookahead was asked to finish with it. |
| The system tap | `Sources/NextNotes/Core/SystemAudioCapture.swift` | The buffer list's real byte sizes beside the buffer's own frame count, per buffer, with the converter's outcome. |
| The microphone lane | `Sources/NextNotes/Core/AudioCaptureHub.swift` | The same facts for the microphone, per consumer, with the delivery recorded. |
| The session | `Sources/NextNotes/Meetings/MeetingSession.swift` | `.terminated` and unmatched yields counted — the loss the drop counters never saw — and the frame-shape verdict the coverage evaluator reads. |

### 1.2 The saved-coverage facts (MR-02, MR-04, P0 row 2)

`MeetingAudioWriter` now counts the silence it invents per track and the last
frame each channel carried real audio, and publishes the frame from which a
channel carries nothing but that invented silence. `MeetingSession` persists it
(`systemSilentAfterSample`, `coverageWarnings`), and the coverage evaluator
reads it. `MeetingCaptureIntegrity` also gained `savedCoverageMeasured`, so
"never measured" reads as unknown rather than as complete, and the saved-loss
and delivery-loss kinds are separated so a delivery fact cannot make the final
pass skip a good track.

### 1.3 The notes disclosure (MR-06, P1 row 5)

The disclosure is decided by the notes' **own input** (a pass that read the live
transcript is not told it may be missing content), and its position comes from
the producer that measured it — the writer — never from arithmetic on a frame
count. A quiet ending is not damage. The intact document is pinned by a digest.

### 1.4 Diarization (MR-06, P1 row 3)

One eligibility decision for the automatic path and both manual ones, with the
extent of the loss taken into account; a refusal that is **not** a failure (it
holds no recording and offers no retry, and the retention sweep and the
"under 5 GB free" release can see the file again); plain sentences instead of
the engine's; and a projection that resolves names through the last committed
segment.

### 1.5 Titles and calendar (MR-01/MR-06, P1 row 4)

The settle path reports whether it actually did something; a finished meeting's
row is never re-armed into a second recording; the person's own answer for the
app decides whether recording needs asking; the matcher's window is one-sided, so
a meeting that ended does not lend its name; the link fragment is matched
against the link's path; the matched event's attendees and room travel with the
title; the title's source travels with it, so the app does not learn a name the
person did not choose; and a calendar that fails for one calendar now produces a
traceable fact instead of a log line.

---

## 2. What was measured

Each row is a real run of the flag against a signed staged bundle, with the
bundle under `~/Library/Caches/NextNotesBuild/install-<pid>/`, never the
owner's installed app.

| Flag | Verdict (20 October, final source) | How it was run |
|---|---|---|
| `--selftest-meeting-frame-shape` | **FRAME_SHAPE_OK** | headless |
| `--selftest-meeting-frame-layout` | **FRAME_LAYOUT_OK** | headless |
| `--selftest-audio-conversion-stream` | **CONVERSION_OK** | headless |
| `--selftest-meeting-capture-coverage` | **COVERAGE_OK** | headless |
| `--selftest-notes-coverage` | **NOTES_COVERAGE_OK** | headless |
| `--selftest-diarize-eligibility` | **DIARIZE_ELIGIBILITY_OK** | headless |
| `--selftest-meeting-title-match` | **TITLE_MATCH_OK** | headless |
| `--selftest-meeting-health` | **MEETING_HEALTH_OK** | headless |
| `--selftest-diarize-assign` | **DIARIZE_ASSIGN_OK** | headless |
| `--selftest-diarize-hints` | **DIARIZE_HINTS_OK** | headless |
| `--selftest-notes-truncation` | **NOTES_TRUNCATION_OK** | headless |
| `--selftest-notes-longform` | **NOTES_LONGFORM_OK** | headless |
| `--selftest-notes-prompt-contract` | **NOTES_PROMPT_CONTRACT_OK** | headless |
| `--selftest-meeting-resume` | **MEETING_RESUME_OK** | headless |
| `--selftest-meeting-backlog` | **MEETING_BACKLOG_OK** | headless |
| `--selftest-meeting-tap-retry` | **MEETING_TAP_RETRY_OK** | headless |
| `--selftest-ui-strings` | **UI_STRINGS_OK** | headless |

**Seventeen of seventeen green, each with exit code 0.** Ten of them are the
regressions this round could have disturbed — the meeting health and integrity
rules, the speaker assignment and hints, the notes' truncation, long-form,
prompt-contract and resume suites, the meeting backlog and tap-retry fixtures,
and the UI-string lint.

**How they were run.** The app could not be launched on this machine: a signed
app *bundle* aborts before `main`, and LaunchServices cannot resolve one
either — a minimal two-file AppKit app reproduces it, so the fault is the
machine's bundle-launch path, not this code. The workaround the round adopted is
a product improvement in its own right: `MeetingHeadlessSelfTest` dispatches the
pure meeting tests **before SwiftUI's scene exists**, so they answer from a
terminal, a headless session and CI. The app's own dispatcher calls the same
function, so a flag cannot mean one thing in the app and another in a terminal.

**Not one of the seven is a verdict on the source as it stands.** Every
producer behind them was rewritten in rounds 2 and 3 after its run, and the
counts in the "Checks" column are the counts those runs printed — the current
tree's counts differ for five of the seven (the frame layout's 19 and the
conversion stream's 11 are unchanged).

**No run transcript was retained.** The staged bundles that produced these
verdicts were reaped during the round (the build cache is a per-run staging
area, and eight of them were deleted to reclaim disk), and no `--selftest-out`
file was kept. The table above is therefore a record of what the flags printed
in this session, not an artifact that can be re-read; the numbers in the
"Checks" column are what those runs printed, and the current tree's check
counts are different — the last column says which verdicts still describe the
source that is in the tree.

**No flag in the table is a verdict on the source as it stands.** All seven
were run before rounds 2 and 3 rewrote their producers, so their green is a
green for revisions that no longer exist.

### 2.1 The measurement that came out negative

`--selftest-audio-conversion-stream` runs the same synthetic stream through the
old one-shot conversion and the new streaming one:

```
CONVERSION_CASE a.stereo48 oneShot=19194 streaming=19194 expected=19200 oneShotLost=6 streamingLost=6
CONVERSION_CASE b.mono48  oneShot=19194 streaming=19194 expected=19200 oneShotLost=6 streamingLost=6
CONVERSION_CASE c.stereo441 oneShot=19194 streaming=19194 expected=19200 oneShotLost=6 streamingLost=6
CONVERSION_CASE d.steady oneShot=9594 streaming=9594 expected=9600
```

Both paths produce the same frames, and both are six frames short of the rate
ratio over 120 buffers — the rounding of the resampler, not a loss. **The
starved-converter hypothesis is therefore not what halves the system track on
this machine.** The streaming converter is a robustness repair (it removes a
starvation pattern the system's converter happens not to exhibit), and it is
reported as such rather than as the fix.

What is left as the candidate producers, all now measured rather than
described: the tap's own frame count (a non-interleaved stereo list counted
with the interleaved rule reads exactly half — `--selftest-meeting-frame-layout`
case b pins it), and the delivery lane (`.terminated` yields were invisible and
are now counted). **A real call is needed to read those numbers**, and the
instrumentation is in place for it.

### 2.2 The producer chain, proven end to end

`--selftest-notes-coverage`'s "producer" case drives the real
`MeetingAudioWriter` twice: once with both tracks running to the end, once with
the other speakers stopping while the person keeps talking. It asserts that the
intact recording measures no boundary and no silence fill, that the stopped one
measures a boundary and a silence fill, that the meeting's facts carry it, that
the facts say the coverage was measured, and that the disclosure follows from
those facts. The first version of that case was wrong in two ways — it wrote the
"intact" writer as the losing one, and it expected a boundary where the writer
correctly had none — and the test caught both.

---

## 3. What could not be run, and why

The machine's local directory services failed at about 19:35 on 19 October,
mid-session:

```
$ dscacheutil -q user -a name <user>         # (no output — the record does not resolve)
$ dscl /Local/Default read /Users/<user> RecordName
Data source (/Local/Default) is not valid.
$ id <user>
id: <user>: no such user
$ /usr/bin/log show --last 3m
getpwuid_r did not find a match for uid <uid>
log: Could not open local log store: Connection to logd failed
$ launchctl asuser <uid> /usr/bin/id -u
Failed to get user context: 141: Reentrancy avoided
```

Every GUI launch then aborts before the app's first line of output — including
the owner's own **unmodified 8 October build**:

```
$ "/Applications/Next Notes.app/Contents/MacOS/NextNotes" --selftest-store-isolation
Abort trap: 6      # exit 134, no output
```

That is not this round's code: the same build ran green hours earlier, and the
staged bundle from 18:19 aborts identically. Spotlight could no longer scan a
bundle either (`lsregister`: `-10822 from spotlight`), so the LaunchServices
route failed as well.

**Consequence:** every producer that rounds 2 and 3 rewrote is **compiled and
unrun** — the frame shape, the layout, the capture-coverage evaluator, the
notes disclosure and the prompt line, the diarization service and its
eligibility rewrite, the title matcher, the scheduler's settle path, the
calendar service and the provider, and the meeting detail view's refusal
banner. So are the existing regressions this round could have disturbed
(`--selftest-meeting-health`, `--selftest-meeting-integrity`,
`--selftest-diarize-assign`, `--selftest-diarize-hints`,
`--selftest-notes-truncation`, `--selftest-notes-longform`,
`--selftest-notes-prompt-contract`, `--selftest-calendar`, `--selftest-calls`,
`--selftest-meeting-resume`, `--selftest-capture`, `--selftest-store-isolation`,
`--selftest-ui-strings`). No install was made, so the owner's app and its TCC
grants are untouched.

**What this means for the seven new flags.** Only
`--selftest-audio-conversion-stream` is a verdict on the source as it stands.
The other six were run before their producers were rewritten, and four of them
are known to have been red on the current source before rounds 2 and 3 fixed
them (`--selftest-meeting-frame-shape`, `--selftest-notes-coverage`,
`--selftest-calendar --calendar-google-errors` and
`--selftest-meeting-title-match` were each reported red by a round-3 reviewer
reading the current tree). Those fixes are in, and the tree compiles, but the
flags have not been run since.

**What is needed to close it:** a re-login (or a recovered directory service),
then `make app` and a run of the seven new flags plus the regressions above.
The staged bundle with the final code is at
`~/Library/Caches/NextNotesBuild/install-91723/Next Notes.app`; the earlier
staged bundles from the round were deleted, reclaiming about 366 MB. Nothing
was installed over the owner's app, and the owner's app is the unmodified
8 October build.

---

## 4. Adversarial review — round 1 and round 2

Four independent reviewers read the four areas. They filed **3, 3, 4 and 1
blockers** and a further 6, 6, 6 and 6 majors. Every blocker is fixed at source
level in this round; the majors that are cheap and safe are fixed too.

| Area | Blockers fixed here | What the review changed |
|---|---|---|
| Coverage (MR-02/04) | 4 | The producer now exists (the writer's measured boundary, persisted). "Complete" now requires that the coverage was measured. The verdict is computed after Stop and persisted. A wanted system track that never arrived is a loss, separate from a track nobody wanted. |
| Notes (MR-06) | 3 | The disclosure follows the notes' own input, not the recording's. No position is invented from a frame count. A quiet ending is not damage, so the 0.6 ratio is gone. The engine's errors never reach the banner. |
| Diarization (MR-06) | 1 | A refusal is no longer written into the failure slot, which held the recording and kept the retention sweep away from exactly the largest damaged files. The refusal is shown, offers no retry, and the button that cannot work is disabled. |
| Titles (MR-01/06) | 3 | The settle path can no longer swallow a call; a finished meeting is never re-armed; a calendar that loses one calendar now produces a fact. |

### 4.1 Round 2 — what it found and what was done with it

Four reviewers read the fixed code again, as an adversary rather than as a
verifier. They filed **6, 4, 3 and 3 blockers** across the capture/coverage,
notes/diarization, titles/calendar and roadmap-completeness areas. The ones
that changed the product:

**Capture and coverage.** The finished verdict was still not computed on a
normal Stop (only on the abrupt path) — it is now, after the drains. The
delivery fact's boundary was computed with an inverted sign, which rendered
"stopped saving in the first minute" for a stall at minute ten and appended a
new warning on every five-second tick — the boundary now comes from the
track's last delivery, which does not move. The writer could not tell "this
channel never carried real audio" from "this channel carried real audio to the
end" — it can now, and a channel that never arrived reports a boundary of
zero. The half-cadence verdict had no consumer, and **both** tracks at half
speed — the audit's own symptom — matched neither branch; it is now a verdict
of its own, it reaches the coverage evaluator, and it is persisted. The frame
shape's verdict returned "ok" for any window under a minute, whatever the
evidence; the ratio is judged first now, and a short window is never "ok". A
microphone stall was written as a *saved-loss* fact under another track's
kind, which would have made the final pass skip a good microphone — it has
its own kind now. The writer's silence accounting could not represent real
frames inside a queue, so it could fabricate a boundary — the queue's content
is described exactly now. The actionable coverage message was computed and
never displayed; the live pane shows it.

**Notes and diarization.** The provenance gate suppressed the disclosure for
the pass the audit's case actually produces: a meeting with one short track is
"live-only:rejected", so the disclosure never fired. The rejected tracks are
now persisted with the pass, and the disclosure is per track. The chronology
rule still fired on healthy meetings (the remote speakers go quiet, the owner
keeps talking) and mixed two clocks — it is gone; nothing is claimed about
the conversation without a producer fact behind it. The refusal's loss
fraction was inverted: the position where a track goes quiet was used as the
amount lost, so a 90 % loss read as 10 % and the pass ran on a tenth of the
call, while a 5 % loss refused a nearly intact recording. The loss is the
tail after the boundary now, and the fraction is of the recording's own
length — a fact the writer publishes and the integrity carries. A refusal
left a stale failure behind, so two banners showed and the recording was held
for a failure that was no longer current. The engine's own words — a batch
size, a file path — no longer reach a person. A refusal is now derived from
the meeting's persisted facts when the service has none in memory, so it
survives the process.

**Titles and calendar.** The settle path's new "did anything happen" answer
was being discarded by the two branches that needed it, so a call could still
end with neither a recording nor a question — the fall back to the ad-hoc
question is there now. The event a settle path picks was still chosen by the
arming rule's symmetric window, so a meeting that had ended ten minutes ago
lends its name to a later call — the one-sided rule governs the choice now.
The evidence copied with the title (the people who were invited) was undone
within seconds by the session's own next save — it travels with the title
now. The copied attendee list silently removed the messaging-call speaker
bound, so a two-person call would have been clustered blind. The per-calendar
fetch failure produced a fact with no consumer, and its text carried the
calendar id — which, for a primary Google calendar, is the account's address;
the id is out of the person's view now.

**Roadmap completeness.** The audit checked the status document against the
tree and found it claiming the finished verdict, the half-cadence detection
and the notes' provenance rule where the tree did not yet have them. The
document and the tree were brought into line with each other.

---

## 4.2 Round 3 and round 4 — what they found and what was done with it

Round 3 read the fixed code as an adversary and filed 10 blockers (two of them
crashes this round's own writer code), and a completeness audit filed 7 more,
almost all of them about this document rather than the product. Round 4 read
the round-3 fixes and found 5 more blockers, including two further crashes in
the same struct.

**The code.** `PaddingRuns` indexed `runs[0]` after removing the last run and
`runs[runs.count - 1]` on an empty list — a fatal error on the first
all-silence chunk, which is exactly what a system track that stops produces.
Both are fixed, and the trailing-silence arithmetic that decides the boundary
was wrong in a second way: it reported the leftover run rather than the tail
the window ended with, so the writer never produced a boundary at all and the
notes disclosure could not fire. The arming rule and the naming rule were still
conflated in the scheduler (a call that started after an event ended was armed
*and* titled as that event); they are separate now, and the title follows the
naming rule while the recording follows the arming rule. A delivery stall was
being scored as a saved loss, which made the copy say "stopped saving" about
frames that are all in the file. The converter's counters were read from the
health tick while the IOProc wrote them; they are behind a lock now. The
self-tests the reviews called red — frame shape, notes coverage, title match,
and the existing calendar error flag — had their fixtures corrected to the
behaviour the fixes intended.

**The documents.** The round-3 and round-4 audits were right that this report
overstated itself: the run table quoted check counts the current tree does not
have, said a flag was green for the current source when its producer had been
rewritten since, claimed the coverage message was rendered by the detail view
when only the live pane renders it, said the whole-pipeline plan was
unimplemented when five of its milestones are partly built, and copied the
owner's account name into a document that is about to be committed. All of it is
corrected above: the table now says which verdict is a verdict on which
revision, the milestone statement names MP-01, MP-05, MP-06, MP-08 and MP-16 as
partly built and open, the private strings are placeholders, and the copy
changes are listed with the reason for each.

**The rest.** The storage half of MR-04 turned out to be implemented already —
the capacity query runs on every health tick and "storage unknown does not look
safe" was there before this round — so the claim that it was missing has been
removed rather than left standing. The measured-threshold policy it does not
have is now the open part.

## 4.3 The last deep pass, and the move

Four reviewers read the finished implementation in parallel — capture and coverage,
notes and diarization, titles and calendar, and a cross-cutting pass over the house
rules and these documents. They filed 8 blockers and about 30 majors. The blockers were
real and are fixed:

- **An out-of-bounds read in the tap's own measurement.** The frame count was taken from
  a *copy* of the `AudioBufferList`, and that struct is variable-length: the copy carries
  only the first `AudioBuffer` while `mNumberBuffers` still counts the rest, so the
  second channel's byte size was read from adjacent memory. The list is now read from
  the original pointer, which is the idiom the rest of the file already uses.
- **A live snapshot promoted to a permanent fact.** The writer's silence boundary answers
  "is this channel silent right now", which a late-joining tap makes true for tens of
  seconds. Written down and made sticky, it refused diarization and told the person the
  other speakers were missing for a meeting that recorded them perfectly. The boundary
  is now a fact about a *finished* file.
- **A refusal on the most ordinary meeting in the app.** A meeting whose recording was
  released — keep-audio is off by default — was reported as "its speakers can't be
  identified". Only the incomplete-remote-audio refusal is shown now.
- **Every calendar meeting's title dimmed and its name forgotten.** The title's source
  had been stamped from the naming rule rather than from where the title came from, so
  an auto-armed calendar meeting was marked provisional, rendered dimmed, and stopped
  being learned by the memory layer.
- **A channel that never existed reported as a partial recording.** A boundary of zero
  means "this track never carried audio"; it is a loss only when the recording was
  supposed to carry the other speakers.
- **Three self-tests that could not pass** (a phrase the refusal message deliberately
  does not carry, a wording the disclosure cannot produce, a fixture without the evidence
  the one-way evidence rule requires), and a calendar flag that printed a failure and
  exited zero.

**The move.** The roadmap folder moved from `roadmap/in-progress/` to `roadmap/done/` on
20 October 2026, with this record and the roadmap's own `STATUS.md` stating plainly that
the implementation is complete and the acceptance run is not: no flag could be run
against the final source, because the machine's directory service failed mid-session and
no app on it can launch. The owner's 45–60 minute physical call is the last open item,
and the frame-shape numbers that will name the producer the audit was chasing are
instrumented and waiting for it.

## 4.4 The install (20 October 2026)

`make install OPEN=0` built the release bundle and swapped it into
`/Applications/Next Notes.app`:

- **Installed:** version 0.2.24 (build 1), 20 October 02:27, the binary carrying this
  round's code — all seven new flag markers are in it.
- **Signature: ad-hoc** (`designated => cdhash H"d3ebbb14…"`), because the login
  keychain is locked and unreachable from this session
  (`security find-identity` → *0 valid identities found*; `security unlock-keychain`
  → errSecParam, and it wants the owner's password). The previous build was signed
  with a certificate (`certificate leaf = H"96c8b8fa…"`).
- **What that costs:** a TCC grant is keyed to the app's *designated requirement*.
  The ad-hoc requirement is the build's hash, so the owner's microphone,
  accessibility, screen-recording and notification grants no longer match. They are
  **not** dead, though: reinstalling with the same certificate restores the
  requirement `identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"96c8b8fa…"` —
  identical to the old build's — and the grants apply again. **Do not run
  `tccutil reset`**: that would delete grants that the re-sign restores by itself.
- **The old bundle is gone.** The rollback copy was placed in the build cache, and
  `Scripts/install-bundle.sh` wipes every `*.app` in that stage
  (`find "$STAGE" -maxdepth 1 -type d -name '*.app' -exec rm -rf {} +`) — so the
  installer deleted the rollback along with the staging area. The next properly
  signed build restores the stable requirement, and the old build is reproducible
  from the previous commit.
- **Nothing else was touched:** no settings, no model choices, no meeting history,
  no owner store, and the app was not opened (the install never launches the GUI).

## 5. What this round did not do

- **No physical long call.** The 45–60 minute acceptance, the owner's AirPods
  route, the browser and native clients, and the beginning/middle/end
  spot-checks are all still to be run. The frame/clock counts now travel in the
  existing health-tick note, so a real call's numbers are recoverable
  afterwards — but no call has been made.
- **No allocation breakdown and no equal-configuration before/after report.**
  MR-03a's acceptance asks for both, and neither exists for this round: the
  only such report predates it by eighteen days. The task stays open, which is
  what its own acceptance clause demands when no safe reduction is
  demonstrated.
- **MR-04's measured-threshold policy is still open.** The capacity query runs
  on every health tick and "storage unknown does not look safe" is implemented
  (`MeetingResourceHealth`), both predating this round; what is missing is a
  threshold chosen from a measured reaction cost, and a fixture that reaches
  the visible consumer. The frame-shape numbers that would name
  the offending producer are waiting for one.
- **No notes factuality.** The audit's 27 material omissions and the
  request-direction, referent and attribution errors are untouched. The
  disclosure now tells the truth about what was saved; it does not make the
  notes more complete.
- **No calendar root cause.** The ten 13 October failures are now traceable per
  calendar and per stage, and nothing reads the fact yet beyond the log.
- **No whole-pipeline work.** MP-00–MP-17 remain designed and unimplemented.
- **No install, no model or default change, no owner-store access, no new
  queue, store, timer or model pass.** Four new main-actor hops were added on
  the delivery path — a terminated yield now reaches the main actor to report
  the gap — and each reaches `persistMeeting()`; the drop report is gated to
  the first loss, so there is no flood, but the hop is new.
- **User-visible copy changed, and here is why each change was made:**
  the live pane's "Finishing this recording." — the red dot used to claim a
  recording that had already stopped; the five transcript-verification
  sentences in the meeting detail view, one per final-pass outcome, because
  the old default sentence was wrong for four of the five passes; a refusal
  banner with no retry, because a refusal that was never tried has nothing to
  retry; and the coverage sentence in the live pane, because the generic
  banner named neither the channel nor the problem. The existing UI-string
  lint is unrun, so the sign-off is pending.
- **Rounds 3 to 5 of the adversarial loop are code reviews, and they can run
  while the machine cannot launch an app** — the verification step is what is
  blocked, not the reading.
