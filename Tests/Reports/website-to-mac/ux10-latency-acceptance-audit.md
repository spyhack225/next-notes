# UX-00 / UX-05 / UX-08 / UX-10 latency acceptance audit

2026-10-01. Read-only audit of roadmap contracts, existing production instrumentation,
and retained installed evidence. No source, registry, status, build, native test,
owner data, setting, model or device was changed. This report supplies no new measurement.
The compiler/native slot remains with the Agent-overhaul integration owner.

## What the gates actually require

| UI task | Exact timing contract | Evidence still needed |
|---|---|---|
| UX-00 | Four real journeys; first visible feedback and main-actor stalls at the minimum main window and a larger size | Correlated event, state and first displayed frame timestamps, exact installed executable identity, sanitized journey captures |
| UX-05 | Key-down → visible listening; work update → island text; approval → acknowledgement; none regress against UX-00 | The same producer and display endpoints before/after, plus physical microphone/speaker/work overlap |
| UX-08 | Key-down → listening versus baseline; no extra await/sleep/debounce in capture; insertion remains in key-down target | Display latency, actual safe-target insertion/readback and switch-away run. A controller outcome fixture proves a different contract |
| UX-10 | Added motion does not regress UX-00 feedback; worst main-actor stall and voice latency meet Agent Phase 2 measured gates; no continuous off-screen/collapsed drawing | Current packaged UI under active voice/dictation/meeting load, actual frame/CPU profile, and the unchanged Phase 2 exit checks |

`AGENT-OVERHAUL/03-PHASE-2-LATENCY.md` §0.3 names four phase exit numbers:
warm file-fed speech end → first audio median **≤0.9 s over five runs**;
voice onset → output duck **≤200 ms**; three-sentence inter-clause silence
**≤50 ms**; worst main-actor stall inside a voice turn **≤100 ms**.
There is no numeric website-roadmap budget for the three UI display deltas: its
criterion is no regression against a measured UX-00 baseline. The documentation
targets `<100 ms` for dictation capture and Agent visual ACK in `LatencyBudget`
are not a replacement for that baseline or automatic production assertions.

## Existing evidence and bounded verdicts

| Evidence | Actual measurement/verdict | What it satisfies |
|---|---|---|
| Original installed five-turn voice run | First-audio median 4.776 s; worst counted stall 156 ms; missing frontend usage joins; run 5 committed twice; `VOICE_LATENCY_FAILED` | Original failure evidence. Neither latency exit nor presentation timing passes |
| Installed build 4 warm-up plus five counted native turns | First-audio median 2.894 s, p90 3.729 s; five actual single commits with playback acknowledgement and matching usage joins; worst counted stall **35 ms**; `VOICE_LATENCY_OK` | Historical warm voice-turn **stall bound passes**. The unchanged 0.9 s headline target **fails numerically**. No headline exit budget was supplied to this run |
| Installed instrumentation modifier | `VOICE_LATENCY_OK`; explicitly instrumentation-only, no audio/model latency | Instrumentation/persistence validator proof only |
| Installed build 9 UI checks and 72 experience images | 8/8 selected checks pass; fixture images produced | Functional/layout evidence for that binary, **no display timing, voice latency, keyboard or physical overlap measurement** |
| Actual Chromium action driver | Fixture action p50/p95 4.768/6.750 ms; snapshot-through-action 8.420/9.874 ms | Browser action protocol fixture timing only; no HUD/island/composer displayed frame or desktop human-yield timing |

The build 4 stall number does not certify the later fixed theme, font packaging,
onboarding shell, dictation receipt or current working tree. The first warm-up had
60 ms stall and 7.049 s first audio, but it is excluded from the five-run warm gate.
The counted first-audio values are 3.729, 2.759, 2.892, 2.894 and 3.013 s;
counted stall maxima are 35, 31, 28, 28 and 26 ms.
Sites are `unlabelled`: these data establish queue lateness, not a responsible
view/canvas or an attributed repair. The old cold duplicate remains a product
failure until its original cold controlled flow is verified; warm single commits
do not close it.

The retained evidence does not provide new measured `voice.onset_to_duck` or
three-sentence `voice.inter_clause_gap` acceptance. Enumeration of those span IDs,
scripted duplex green and playback-ledger green are not emission or timing proof.
Live capture-host-time → delivery/processing, dropped audio, physical near speech,
actual output-device latency and acoustic first syllable are also unavailable here.
The Phase 2 headline is deliberately file-fed/playback-callback based, not acoustic.

## Existing endpoints must not be mislabeled

1. `DictationController.begin` sets `.starting`, records the actual hold identity,
   and starts `dictation.keyDown_to_capture`. It ends that trace when the actual
   subscription succeeds and `isCapturingAudio` becomes true. This measures
   **capture admission**, not first HUD/island pixels. The trace itself starts after
   earlier synchronous beginning work, so it is not an independent hardware key-down
   timestamp. `holdStarted` and `keyDownToCaptureMs` retain that same bounded meaning.
2. `WakeWordAudioMonitor.didSpot` starts `agent.wake_to_listening_ui`, calls
   `ActivationController.beginAgent`, then immediately ends the trace. The end is
   the synchronous activation return/state mutation, not an observed rendered frame.
   Its name alone cannot establish a visual ACK budget.
3. `NextNotesApp.observeState`, `IslandState.observe` and `IslandPanel.observe`
   re-arm through existing MainActor tasks. That is where producer→presentation
   scheduling can be observed. `HUDPanel.present`/`IslandPanel.present` order a
   nonactivating panel and begin an alpha animation. `present()` return, `isVisible`,
   `alphaValue` assignment and animation completion are four different endpoints;
   none by itself records the first visible listening label.
4. `AgentPresentationSelfTest` checks actual handle/stream/row mapping while a
   fixture is suspended, using bounded waits. Its polling deadline is a test bound,
   not a measured request→display latency or frame timestamp.
5. `ExperienceSheet` caches offscreen leaf views; `OnboardingSheet` likewise supplies
   layout frames. Their success markers cannot measure on-screen feedback, canvas
   cost, target focus or physical full duplex.

## Smallest safe remaining checks

### A. Use the existing native voice diagnostic first

After the shared owner installs the current frozen packaged binary, retain its
executable SHA and run the existing five-run diagnostic with explicit exit inputs:

```sh
Scripts/run-selftest.sh --selftest-voice-latency \
  --voice-latency-fixture /tmp/nextnotes-agent-closure-voice-fixtures/haiku16k.wav \
  --voice-latency-runs 5 --voice-latency-budget 0.9 \
  --voice-latency-max-stall 0.100 --selftest-timeout 600
```

This uses the existing timeline, metrics store, usage log, playback acknowledgement
and calibrated `MainActorStallProbe`; it adds no timer or user-turn gate. Check the
exact five committed counts, required stages, usage joins and final marker. A
failure is actionable Agent Phase 2 evidence, not permission to weaken the UX gate.
The same existing `--voice-latency-island off` option enables the prescribed island
on/off comparison when a concrete UI stall/drawing risk needs attribution. Keep
fixture, model, binary and warm-up convention identical; do not call noisy differences
an improvement without that pairing. No P2-02…08 changes are proposed by this audit.

### B. Add only missing presentation boundary observation

If source-level scheduling latency is needed while screen capture remains unavailable,
the narrow seam is a **SelfTest-only default-nil observer** at existing accepted
input/work/approval producers and their existing presentation consumers. Use
`VoiceLatencyTimeline.nowNanos()` for all endpoints; retain only app-generated
hold/task/review identity, stage and numeric timestamp in the harness output.
Do not log text, destination, transcript, URL, recipient or owner identity.

Observe, without gating, the actual accepted hold/input; real activity revision;
actual gate choice callback; MainActor HUD/island observer consumption; and actual
review/result view state consumption. A callback only records metadata synchronously:
no new await, polling loop, sleep, debounce, live repeating timer, queue, ledger,
production preview state or forced display on the user path. Existing isolated
controller/gate/runtime fixtures can own the observer and remove it on cleanup.
Reuse the existing `MainActorStallProbe` only for the bounded diagnostic interval
if nonvoice presentation load needs queue-lateness samples; its calibrated probe
already exists. Do not fabricate a voice turn to make dictation/meeting stall rows
look like voice acceptance.

Label these outputs **event→presentation-consumption**, not event→first-visible.
They can isolate the first slow producer/observer boundary and guide a repair,
but cannot close the explicit display gate. SwiftUI `.onChange`/`.onAppear`, a
hosting view attachment, AppKit ordering and offscreen `cacheDisplay` do not
establish compositor presentation. A draw/flush diagnostic must say what it
actually measured and cannot substitute for on-screen frames.

### C. Complete actual displayed-frame and load evidence

An approved live capture of a sanitized harness window/target is the remaining
first-visible endpoint. Correlate its frame clock to the same monotonic event
observations; record the clock mapping and frame resolution/uncertainty, exact
build, dimensions, requested OS appearance, actual fixed light appearance,
motion/transparency settings and HUD/island placement. Use the same frames and
definitions for original baseline and new implementation. A static baseline
or video with no event clock cannot establish no regression.

Profile the actual changed surfaces while voice, dictation and meetings run,
including collapsed/offscreen rows. Reuse existing Instruments/signpost labels
and the existing queue-lateness probe. Confirm drawing ceases when frozen or
offscreen, rather than inferring it from a source `TimelineView` branch. No
clocks or observers should be added to production just to make that check pass.

The latest user confirmed the Mac is unlocked. That availability does not turn
the recorded ScreenCaptureKit −3811 or Computer Use app-access refusal into a
successful capture. Keep physical display/focus/VoiceOver evidence explicitly
unverified until the real authorized surface succeeds.

## Evidence identities and report reconciliation

| Retained file | SHA-256 |
|---|---|
| `../agent-overhaul-closure/latency/installed-five-turn-baseline-red.log` | `91bd813b65aeadd3db8c0e5e1131157a66f8044241a4fdbdf9ce9beb4dd0809f` |
| `../agent-overhaul-closure/latency/usage-correlation-before/installed-five-turn-current-green.log` | `a041710e666277ae36cca2b2ddae5ad54cb51b258b650fdb1c7444baa6bb70cc` |
| `../agent-overhaul-closure/latency/installed-instrumentation-green.log` | `04f7cc484b08f9b09ad8291cb4fa5a9b37bac2794a88d66b697058c05452d37a` |
| `../agent-overhaul-closure/installed-integration/app9-ui-evidence-manifest.json` | `820013a93a2d5c5a294d541cf55ff9e9f645d1c7ff429a9d75a3b4920411b233` |

`ux08-delivery-contract.md`'s final timing paragraph still cites the older
4.776 s/156 ms missing-join run. Retain that original failure, but when reconciling
closure evidence also report build 4's later 2.894 s/35 ms valid warm run. Only the
usage correlation/measurement contract and historical warm stall bound improved;
the 0.9 s phase exit, cold duplicate, current theme load and UI display gates
remain open. No report/status row was edited by this audit.

## ACP progress responsiveness frontier — 2026-10-03

[Retained actual P6 verification](../agent-overhaul-closure/p6-restoration-monitor-storage-production/verification.md)
records staged215's main-queue ping sent→landed maximum94.839792ms for32 admitted
ACP activity callbacks with512 retained tasks, passing the unchanged100ms predicate.
Staged217 repeats the same2161case workload at318.892042ms and fails that predicate:
exit1, no timeout, Source/full-bundle invariance. The earlier single pass remains
evidence, but current responsiveness acceptance is OPEN after the later failure.

These values measure main-queue scheduling during ACP progress. They measure no
queued-dispatch interval, first displayed UI frame, cold/warm voice audio or backing
latency. Exact provenance is the retained fixed215/fixed217 worker stdout/run files,
TaskACPActivityHeartbeatSelfTest's existing bounded callback fixture and
MainActorStallProbe's sent/landed endpoints. There is no distinct317ms sample in this
review; an earlier task description assumed one and was corrected.

App221 per-stage distributions require their actual bounded sample/stage
qualification and Source/bundle invariance. They can support cause attribution;
they cannot replace the unchanged100ms verdict or close UX00/UX10 displayed-frame,
voice or motion gates. No threshold change, selected passing rerun, new user-path
timer or owner process shutdown follows from this audit. This tree changes only
review artifacts and runs no Source/native/model/build/index work.

### Qualified stage221 checkpoint

The retained observed221-worker run exits1 without timeout and with Source/bundle
invariance. Both workloads qualify32actual samples/19stages with no overflow.
Small-history sent→landed maximum is96.324167ms; the same512-history workload is
124.089334ms and fails the unchanged100ms predicate. These qualified stage
observations support attribution only. Their closer timing does not accept the
gate or erase217's retained318.892042ms failure; responsiveness remains OPEN.

### Qualified cost repair224/225 checkpoint

[Actual paired evidence](../agent-overhaul-closure/p6-restoration-monitor-storage-production/paired224-225-cost-qualified.json)
retains original224's118.702875ms history failure. Fixed225 passes the unchanged
2206-case production-path fixture three times, with qualified burst and drained
pings during32 admitted ACP callbacks:

| Retained tasks | Main-queue ping sent→landed maximum, three runs |
| --- | --- |
| 0 | 50.450958 / 46.728 / 49.636167ms |
| 512 | 65.259125 / 61.994375 / 70.935333ms |

All six measurements pass the unchanged100ms predicate. The heartbeat86,
storage104 and supplementary15-mode/45-control compaction fixtures are identical
between variants. Only AgentTaskStore, durable TaskStore and TaskEventJournal
differ across1086 compiler inputs. All13 required related flags exit0 without
timeout and with Source/full-bundle invariance, including owner isolation.
Paired evidence SHA-256:
`96fbade52f4953e4d7107083da23d0df394e2bb0d1bed9d4add96c2fa7a489db`.

The responsible producers avoid an intermediate mapped ID array, reserve retained
export length before producing identical bytes, avoid diagnostic confinement work
when its observer is nil, and compact from actual terminal events. Existing
retention predicates, event/export contents and atomic witness/SQL/export admission
remain intact. This is repeated bounded workload proof, not universal retained
journal or live-load performance.

Earlier217/221 failures remain retained. Worker223 separately records a
1927.571458ms small-history maximum with one1834ms callback; its cause remains
unattributed. The225 repairs cannot establish that outlier's cause. These endpoints
measure neither dispatch/backing time nor first displayed frames or voice audio.
Full UX-10 display, voice, live-load and motion gates remain OPEN. No native test,
Source/build/model/index action or owner process shutdown ran in this UI review.
