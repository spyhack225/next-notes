# Meeting freeze investigation — 7 October 2026

**Update after the owner's live Google Meet reproduction:** the allocating path is now identified: `NeedleServer.ensureRunning` recursively awaits an already-completed startup task, retaining async frames. The live stack contains hundreds of repeated frames plus `swift_task_alloc`, and the heap grew to about 10.9 GB. An unchanged producer regression fails on the original source; the repair passes failed-start and native concurrent-start cases. See [LIVE-FINDINGS.md](LIVE-FINDINGS.md) for current status. The maintained full-app startup and four focused release checks pass. A visible-window395-second real recording saved and finished without the former runaway (sampled live peak1.421 GB), but responsiveness under competing work and broader listening/notes quality remain open; a fresh quiet-load recording is still needed.

The initial investigation below established severe process-memory growth. The owner's Next Notes process rose from about **0.9 GB to 21.0 GB** during today's first live meeting and from **0.7 GB to 44.5 GB** during yesterday's. Speech delivery slowed, generic microphone-consumer backlog drops were logged, and the interrupted recordings were recovered after restart. The app's resource policy did not contain either event.

At the end of the initial review, the allocating producer was not identified: bounded installed-app and UI diagnostics did not reproduce the original growth. The subsequent live reproduction resolved that gap. This report does not mark the original product flow fixed until the repaired app passes that flow.

## Scope and evidence

Read-only review of all **13 saved meetings**, meeting metrics and usage logs, macOS diagnostic reports and retained unified logs; source review from capture through notes and recovery. Machine: Apple M3, 16 GB unified memory, 256 GB storage, macOS 27.2 build 26B5091g. Native diagnostics used the installed app, version 0.2.24 (1), executable UUID `5FA38DBC-549F-3DED-B68F-06CB08FDC147`. Source/executable hashes are in [source-pins.json](source-pins.json). Current source has concurrent uncommitted changes; source review and the standalone UI fixture must not be assumed byte-identical to installed production code.

No dictation implementation was edited. The initial review changed no production source, owner preferences, meeting files, models, or installed app. Generated fixtures ran in separate harness processes; the owner app remained open. Subsequently, the real Google Meet reproduction used normal recording, and the owner explicitly authorized force-quitting the paused runaway app. The helper startup producer and its existing self-test were then repaired. Raw diagnostic logs were read locally and reduced to metadata. This directory contains no owner meeting titles, participants, or transcript content.

The owner confirmed that **the Next Notes meeting window is visible during the failures**. Reproduction must include that visible production window. This required the visible production window in reproduction; the subsequent stack identified the startup helper as the allocating producer. Hidden-recording success and long-duration graphics behavior are not established.

## Actual incident timelines

The following times are EDT. Footprint is the process's Mach `phys_footprint`, not RSS and not all physically resident RAM. It accounts for charged memory including compressed/swapped allocations. A 44.5 GB footprint on a 16 GB machine is possible. RSS fell while paging, so a small RSS did not mean the app was small. Recorded peaks are sampled lower bounds.

| Incident | Time / elapsed | Process footprint | Observed consequence |
|---|---:|---:|---|
| Oct 6, 15:48:40 start | +1 s | 0.735 GB | Pressure already `warning`; swap used 8.97 GB |
| Same | +6 s | 3.276 GB | No live transcription pause |
| Same | +11 s | 24.472 GB | Swap used 13.23 GB; audio queues/active input both zero at this sample |
| Same | +30 s | 37.387 GB | Partial transcript lag 16.66 s |
| Same | +52–53 s | 44.295–44.489 GB | Final transcript lag 39.60 s; RSS about 64 MB at last event |
| Oct 7, 10:05:34 start | +2 s | 0.906 GB | Pressure `normal`; swap used 8.30 GB |
| Same | +7 s | 0.905 GB | Active speech input 616 KB |
| Same | +11 s | About 5.06 GB | Rapid growth after first speech finals |
| Same | +15 s | 8.958 GB | Swap availability 391 MB; health check took 2.28 s; pressure still `normal` |
| Same | +33.5 s | — | First retained capture-backlog drop error |
| Same | +35 s | 14.501 GB | Health check took 9.66 s; pressure `normal`; active input 768 KB |
| Same | +46–50 s | 20.424–20.998 GB | Final speech lag 25.66 s; context update 3.35 s |

Underlying selected rows are in [incident-metrics.csv](incident-metrics.csv) and [incident-metrics.json](incident-metrics.json). Events are ordered by `endedAt`, when their process sample was recorded. `startedAt` can precede a long speech/health operation by many seconds.

In the retained Oct 7 10:06–10:07 subsystem window, there are **316 capture delivery backlog errors**, first 10:06:07.525, last 10:06:44.137. Memory growth preceded these errors. The sequence supports memory growth followed by scheduling/paging delay and consumer backlog. These generic messages do not identify the subscriber and cannot be counted as meeting capture loss; the later live investigation checks the meeting’s own counters separately. They also do not identify the allocator for those earlier incidents. The Oct 6 equivalent query returned no retained events, which is missing evidence rather than evidence of no drops.

Neither ordinary audio backlog nor output recording size explains this scale. Resource rows show queued speech bytes zero and active bytes under 0.8 MB. `writerBytes` is cumulative saved PCM payload (`writtenFrames * 4`), **not retained writer memory**. The saved audio payload at these samples is kilobytes to low megabytes.

A post-restart, non-recording footprint snapshot around 12:02 EDT shows approximately **1.7 GB** for the owner app, with substantial `IOAccelerator`, `IOSurface` and unmapped graphics charges. See [owner-postrestart-footprint.log](owner-postrestart-footprint.log). This is a useful allocation-category baseline and a reason to include full-app rendering/native graphics in the next isolation pass. It is **not** an incident allocation trace or proof that graphics caused the 21–44 GB growth. The isolated meeting view does not reproduce the full app's graphics ownership or every other mounted scene.

The owner began both incidents with roughly 8–9 GB of swap already used and 7–9 GB of immediate storage available. That reduced headroom. It does not explain a single app growing by tens of gigabytes within seconds, and clearing disk alone is not a fix for that producer.

## What happened to saved meetings

[meeting-inventory.json](meeting-inventory.json) covers all retained records. Earlier September meetings ran for minutes; the available evidence does not support saying every historical meeting crashed. Recent records repeatedly carry `interruptedAt` with unknown interruption reason. The three Oct 6/7 recordings were completed by recovery after restart.

Today's metadata retains an end timestamp only 24 seconds after start, while the surviving audio contains approximately **58.893 seconds**. Yesterday's 15:48 record retains 13 seconds while surviving audio contains approximately **136.188 seconds**. The 14:20 Oct 6 incident retains one second and approximately 1.254 seconds of audio. Saved end timestamps can lag the actual writer when the app becomes unresponsive.

The current `done` status means later processing finished; it does not prove the original meeting captured continuously. Persisted `captureGap=false`/missing-frame zero on the interrupted record cannot override later unified-log drop evidence. Recovery can only process surviving audio and transcript, not speech never captured. Do not promise complete notes for these meetings solely because recovery succeeded.

## Pipeline review and resource costs

| Stage | Existing implementation | Finding / optimization implication |
|---|---|---|
| Microphone + system capture | Shared mic hub plus independent Core Audio process tap; 16 kHz meeting input | Full-duplex source; hardware capture, conversion, wake/voice and full-app overlap remain unisolated in this incident. Shared capture belongs to the concurrent dictation work and was not edited. |
| Track delivery | Ordered detached drains, bounded newest 1,024-packet streams | Bounded packet count, not a universal byte limit. Packet format/size and retained native buffers still need physical-path measurements. |
| Audio writer | Two tracks, bounded five-second track pairing, writes at most 30 seconds per chunk | Current deterministic writer tests verify exact contents and release. Stereo 16-bit 16 kHz file payload is **64 KB/s, 230.4 MB/hour** (decimal). Retention/storage costs are separate from heap growth. |
| Live speech | Two short-window producers share the existing serialized native ASR lane; 300-second pending allowance per track | Float pending allowance is roughly **19.2 MB per track / 38.4 MB combined**, excluding current/native/upstream buffers. Actual incident queue samples were far smaller. Short windows preserve live latency; extending them blindly would worsen interactivity. |
| Context and live assistance | Final-segment extraction, 360-segment evidence buffer, occasional model refinement | First refinement cadence counts summed segment durations; overlapping tracks can reach a 60-second speech budget before 60 wall-clock seconds. Optional admission checks pressure. Current incidents have no completed live-refinement/notes usage row; absence does not exclude started or hung native work. Needle passes recorded zero calls/cards near the start. |
| Stop and final transcript | Background ASR windows, channel-by-channel file read | Reads a whole channel into Float samples: **230.4 MB/hour/channel**, roughly 461 MB for a two-hour channel before windows/native temporaries. Optimize via incremental reader at this existing seam, retaining silence boundaries and absolute timing. This post-stop allocation cannot explain first-seconds live growth. |
| Speaker separation | Whole system-channel samples plus native diarizer | Same duration-linear input risk after stop. Needs long-file peak measurement and chunk-boundary speaker consistency before changing segmentation. |
| Notes | Token-budgeted map/reduce, bounded collapse, progress and truncation checks | Important quality protections already exist. Owner meeting-notes role is MiniCPM5-2B Q4_K_M. Today's recovered generation took 31.175 s overall; recorded completion 28.896 s / 130 output tokens (~4.5 tok/s). This is a single observation after restart, not the prescribed controlled ASR+voice throughput benchmark. |
| Optional background work | Index crawl + full SQLite root replacement; TTS native setup elsewhere | OS disk-write reports show heavy startup I/O. Coordinate through the existing compute/recording admission seam; measure first. No second scheduler/store is justified. These are overlap candidates, not the confirmed runaway allocator. |

The current source has already removed speculative notes warmup from recording start. Historical SHA-256/model-download allocation fixes and earlier buffer fixes should not be presented as new fixes for these events.

## Concrete safeguard failure

`MeetingSession.checkResourceHealth` uses the existing five-second cadence. It queries storage off the main actor, then awaits transcriber snapshots. It pauses live speech only for a **critical DispatchSource pressure event**, with healthy capture, recent successful audio saving and sufficient disk. Optional-model admission also follows that pressure snapshot.

Today's samples remained `normal` through 14.5 GB; yesterday stayed `warning` through the sampled 24.5 GB resource row. Every incident resource row reports `paused=0`. The measured process footprint and swap values are logged but do not govern action. In addition, the health operation itself stalled to 9.66 seconds while the Mac was paging. This is direct evidence that the present policy did not contain these incidents; it is not evidence that the OS will never send a critical event.

The injected-warning test does verify optional-model unload in about 24 ms, releasing approximately 129 MB while retaining speech. That proves the release path when invoked. It neither reproduces a real exhausted machine nor releases tens of gigabytes from the unidentified producer.

## Verification performed

All measurements below are process footprint unless explicitly RSS. GB/MB are decimal. Native SDK device-specific allocation is unavailable in these harness measurements.

| Check | Result | Limits |
|---|---|---|
| Installed `--selftest-meeting-resources` | PASS: generated two-hour/two-track input, 230.4 million samples; peak logical 12.8 KB / capacity 1.049 MB; exact writer and loss/readback cases | Deterministic producer exercise, not two wall-clock hours or hardware capture |
| Installed `--selftest-meeting-resources-live` | PASS: actual cached Parakeet loads/inference; internal sampled ASR peak **164 MB**; notes completion peak **296 MB**; pressure release ~24 ms | Generated tones; local harness model choice is not proof of owner MiniCPM role; no physical capture, voice or full-app overlap |
| Installed `--selftest-meeting-finals` | PASS: native English/French fixtures; live recall .865–.956, final .872–.963; zero wrong-language cases; final RTF .0287; external sampled peak **134 MB** | About 113 s wall time; replay faster than real time; generated speech. Some other model-free checks overlapped, so timing is descriptive |
| Health / integrity / backlog / resume / reconcile-LLM / retention flags | All six PASS; health 90 checks, integrity 67 checks; backlog 180 s input with no loss; resume 4/4 resumable | Isolated fixtures, not whole-system freeze acceptance |
| Standalone actual meeting-view/component rendering | 35 s peak **124 MB**, final124 MB; 120 s / 50 level updates per second peak/final **198 MB** | Generated session and dependency/theme stubs; current repo UI source, no native capture/models/full-app/island. Modest growth over two minutes requires longer observation; cannot claim a proven long-duration plateau |
| Installed owner-store isolation | `STORE_ISOLATION_OK`: **21 files / 33 defaults unchanged** | Same run also emits **TOOLLOOP_PRODUCTION_FAILED** in embedded browser A02 fixtures despite exit code 0. Treat overall run as mixed, not blanket green; no production changes here introduced or repaired that failure |

Logs are retained alongside this report. Native runs had an external 2.5 GB abort limit, and the UI fixture aborts at baseline +512 MB. No attempt was made to drive the owner's Mac into another freeze. The outer two-second sampler can miss brief peaks; the native probe's internal finer samples are authoritative for its short stages. `LIVE_TO_FINAL_RATIO: inf` in the speech log describes zero/zero wrong-language counts, not an infinite performance ratio.

macOS NextNotes `.diag` files found are **disk-write resource diagnostics, action taken: none**, not application crash stacks. One Oct 6 14:19:57–14:20:37 report shows 2.148 GB dirtied in 39 seconds, with FileIndexer/SQLite and Pocket TTS/CoreML stacks, footprint only 150→366 MB (max433 MB). It predates the separate 14:20:38 brief recording. It is evidence of I/O contention, not the allocation stack for the 15:48 or today's 10:05 runaway. No matching crash/panic stack identifying the allocator was found.

## Ordered work required before claiming reliability

1. **Completed for the captured live incident: identify the allocating producer.** The heap/stack pin startup recursion; the initial diagnostic proposal follows for historical context. Use a disposable meeting store, the installed identity/native grants, both physical sources, live context/agent settings and browser call, with ASR+voice running and the **actual meeting window visible**. Sample process footprint plus allocation categories at stage entry and growth; obtain a `vmmap`/allocation stack before paging dominates. Abort the diagnostic's own work at a small growth budget, preserving writer closure. Compare the visible full-app scene with capture-only, speech and context controls; prioritize graphics-category growth given the post-restart baseline. Do not disable the actual failing feature throughout and call that reproduction. Capture grants/browser routing and the full production scene are the main gaps left by the passing component tests.
2. **Startup producer repaired and original concurrent native cases pass; broader acceptance remains open.** Reuse its current lifecycle/ownership seam. If the source is native/OS, retain stack/version evidence, label any boundary mitigation explicitly and leave upstream repair open. No claim that restarting, freeing disk or changing notes models fixes the allocation.
3. **Repair the resource policy at the existing seam.** Use measured footprint/growth and paging headroom as independent inputs alongside OS pressure; measure/calibrate budgets on this 16 GB machine with ASR+voice. The observed blind spot needs regression coverage for `normal`/`warning` plus runaway process growth. Keep optional release and capture-saving behavior; make any deferral conditional on proven saved coverage. A delayed main-actor health tick cannot be the only emergency observation. This is a proposed mitigation until the allocating producer is repaired and the original flow passes. No new confirmation, second scheduler, extra model pass or sequential capture gate.
4. **Reduce confirmed post-stop linear memory and background contention.** Incremental file reads for final transcription/diarization, with exact timing/language/speaker regression evidence; schedule full index replacement and optional native setup through existing realtime admission. These improve long meetings and overlap, but are separate from this live freeze.
5. **Close the real-machine acceptance gap.** First bounded short reproduction, then 30–60 minute browser meetings and a longer saved fixture, foreground/hidden UI, both sources, ASR+voice. Record peak and memory slope, swap change, dropped/missing frames, live lag, stop-to-notes time and factual coverage. Require no accumulating memory growth, no new capture loss, responsive browser/app and preserved approval behavior. Set numerical budgets from measured baseline and the reference-machine contract; do not promote a model or declare all-meeting quality on synthetic recall alone.

## Reproduction and handoff

`extract_metadata.py` re-reads owner files without writing them and exports only the allowlisted metadata. `run_ui_probe.sh [--burst]` builds the standalone diagnostic from current source in an owned temporary directory and cleans it on exit. The fixture does not record audio or write owner settings. Hashes pin the source read during this investigation; changes by concurrent agents require repinning before comparing results.

The initial review created no full-app build or worktree. The subsequent producer repair reused the shared build cache and produced one separately signed release bundle, retained as the useful running build. The report and compact diagnostic source/logs are retained in the canonical checkout as investigation artifacts. The owner subsequently requested installation: the tested release is now installed, and the superseded owned staged bundle was removed after verification; the original installed bundle is retained for rollback. See the installation update in LIVE-FINDINGS.md. Temporary UI executable/extracted component and raw log extracts are removed after summarization; owner data, active processes, other agents' builds/worktrees and model caches are deliberately retained. See `cleanup.json` for the exact owned paths and bytes reclaimed.
