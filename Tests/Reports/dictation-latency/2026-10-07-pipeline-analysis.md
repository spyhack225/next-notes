# Dictation pipeline audit — 2026-10-07

Scope: the macOS production path in the current canonical working tree, including its pre-existing, uncommitted latency work. Reference hardware: this Mac is Mac15,12 (M3 Air), 16 GB. Owner history is analyzed locally; retained evidence contains timing fields, counts and verdicts. No dictated text, owner recordings or account material is exported. Public repository speech and deterministic tone/noise fixtures supply the tests.

## Finding

We have been comparing a pipeline that does much of its work during speech with a pipeline whose expensive finishing work frequently begins at release. Network latency is smaller than our cleanup latency. Parakeet is not the leading explanation for the observed multi-second waits.

Read-only history snapshot:

| Measurement | Next Notes | Wispr Flow |
|---|---:|---:|
| Successful holds measured | 35 of 40 observed holds | 47 |
| Release to successful outcome, median | 4,208 ms | 563 ms |
| Release to successful outcome, p90 | 17,460 ms | 1,288 ms |
| Worst | 25,685 ms | 3,642 ms |
| Network component, median | local | 85 ms |
| Stored compressed audio chunks | — | 47/47 |

These are historical, unmatched samples, not a paired accuracy or performance experiment. Wispr numbers are its own `e2eLatency` and `clientNetworkLatency` fields. The presence of `opusChunks` is consistent with the roadmap's streaming observation; the database alone does not prove the timing of its server's individual stages.

Next Notes' retained timing ring has only 9–10 relevant samples. Median drain is 5 ms; transcription after drain 6 ms; the recorded first-partial span 1,581 ms; cleanup 3,175 ms (p90 17,124 ms); insertion 14 ms, worst 391 ms. The release-to-ASR worst is 21,267 ms despite a warm transcription worst of 346 ms: startup can consume time before the ordinary tail clock even starts. Historical run `processSeconds` ends before insertion and must not be presented as identical to Wispr's complete delivery measurement. The first-partial span starts at listening, rather than acoustic speech onset: hesitation can inflate it and speech captured during model startup predates it. The replay measurement below uses the start of fixture feeding explicitly.

## The actual path

### 1. Key-down and ingestion

`DictationController.beginDictation` captures the destination, output profile and context at key-down. It requests microphone access, asks the selected engine for its PCM format, then subscribes to `AudioCaptureHub` **before** waiting for model startup. The shared hub owns one `AVAudioEngine`; wake, meetings, dictation and voice receive separate buffer copies. There is no temporary audio-file round trip in normal dictation.

The normal input tap requests 2,048 native frames: about 43–46 ms at 48/44.1 kHz. A bounded delivery worker resamples with `AVAudioConverter` to 16 kHz, mono Float32 for Parakeet. The engine's FluidAudio converter takes its fast extraction path for that format; it is not normally resampling a second time. Compare mode intentionally captures Apple's int16 format and adapts for Parakeet.

Capture order is preserved by one audio stream and one feeding task. Thirty seconds of pending PCM can accumulate during startup; exceeding that cap drops newer packets and counts them. The 180-second retained recording cap belongs to retry/compare storage, not to the normal engine feed. It does not truncate a successful long dictation, but it prevents complete retry/comparison of a longer recording. The signed baseline engine separately retains the complete hold in memory. The 8 October source candidate discards only successfully transcribed committed prefixes from that ASR array; absolute offsets preserve all remaining/backlogged audio. Its native acceptance is pending.

**Confirmed accuracy defect:** immediate hub unsubscribe invalidated its worker and discarded already accepted packets at release. An isolated actual hub callback held packet zero while packets one and two queued. Original Stop reported success but delivered `[0]`; corrected Stop delivers `[0,1,2]`. The controller now stops admission synchronously and joins the existing delivery drain before closing its audio stream. No fixed settle delay was added. The same boundary covers release during startup. The callback and stream have their existing finite bounds. This proves accepted software packets are preserved; it does not prove preservation of hardware samples that have not yet reached the tap when capture stops. Requested callback size is not a measurement of the device's actual I/O period.

### 2. Segmentation and partials

The current working tree already uses `DictationSegmenter`: 20 ms energy frames, a 3-second segment floor, 500 ms pauses (300 ms past 8 seconds), and a 14.5-second maximum. Pause cuts keep silence on both sides; forced cuts choose the quietest 60 ms. Each successful segment's text is frozen. The live recognizer repeats only the open tail, rather than the entire utterance.

The segmented path addresses the historical quadratic repeated-transcription cost documented in the roadmap. It is still repeated batch inference, not a cache-aware streaming encoder. Every open tail can be decoded several times. Pauses below the segment floor do not commit. Quiet audio can be mistaken for silence because the gate is energy based (RMS 0.01), and a forced cut in uninterrupted speech can split a word. Those remain accuracy risks; lowering the floor or substituting a different model without a speech corpus would be an unverified change.

The new first-pass request is at 400 ms of available audio; later requests keep the existing one-second cadence. This gets initial words onto the display sooner without doubling the workload throughout a long hold. Actual display time also includes input delivery, model work and UI scheduling. An empty model answer cannot be displayed as words.

**Confirmed scheduling defect:** when a segment finished while more speech existed, the engine withheld its committed-prefix update until another tail pass finished. The producer now emits the commit immediately, allowing both UI and incremental cleanup to consume it without that extra model pass.

### 3. Parakeet execution and finishing

The pinned dependency is FluidAudio 0.15.6 (`4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`). `ParakeetModels` loads TDT v3 int8 on CPU + Neural Engine, with CPU-only fallback if ANE loading fails. Loaded weights are reused across holds. Startup warming is already in place. Decoder state is fresh per independent segment; carrying decoder state blindly across non-overlapping segments would not provide a valid streaming cache.

FluidAudio pads a short inference to its native 15-second encoder input. Under 300 ms, our input helper pads to its minimum; under 100 ms, the hold is skipped. The dependency's longer-input route uses chunk processing and merging. Keeping ordinary segments under 15 seconds avoids that second path, but a failed segment or backed-up worker can still leave a longer final tail. There is no batch timer intentionally holding ordinary dictation until a full 15 seconds has arrived; the fixed shape is a compute floor.

At release, the engine reuses a completed tail covering speech, awaits an already adequate pass, or starts just the uncovered tail. A second manager shares the existing weights so a fresh final pass need not sit behind a stale partial actor. This is useful but does not make shared ANE hardware infinitely parallel.

Per-pass `.realtimeASR` ownership, already in the working tree, releases compute between passes so cleanup can run while the key is held. Apple recognition still has controller-owned lane lifetime. The scheduler remains cooperative; native calls already entered cannot always be stopped immediately. Voice, ASR and model activity are not serialized by an added hold-wide lock.

### 4. Cleanup, parsing and structure

`CleanupRouter` applies deterministic Stage A, renders explicitly spoken structure, chooses the existing semantic engine, guards its answer, applies structure again, then validates/renders the optional layout plan. Dictionary correction follows; file references are tagged last. Explicit list, quotation, code and table rendering remains deterministic even if a model refuses or times out. Target profiles, grammar and tone preferences remain intact.

MiniCPM's shared runtime already has resident-only dictation admission, an interactive scheduler class and a nonisolated residency snapshot. A cold load no longer belongs inside its generation deadline: a staged Apple fallback answers while warming continues. Existing launch, pressure-recovery and fallback warming are retained. No new cold model load is launched at key-down: native load/context preparation can overlap ASR despite cooperative scheduling, so that speculative change was removed before handoff. Stored model choices are preserved.

Model generation rewrites its input. With 20–30 generated tokens/second, a 100-token rewrite alone costs 3.3–5 seconds. MiniCPM's approximately 1,400-token system prefix and GPU model/context preparation can add prefill/cold-start cost. `mmap` does not establish that Metal tensor preparation or model compilation is only a sub-second SSD page-in. Keeping one verified local file resident and reusing its real prefix helps; system-owned Apple models still consume the Mac's memory even if their weights are outside our process.

Incremental cleanup already sends finished committed sentences during speech and checks that their prefix still matches the final deterministic text. This session also stops rerunning its full rules and sentence split when only the open tail changes: the exact frozen prefix is processed once per change. The actual producer originally invoked its rules twice for two identical committed prefixes; the regression now requires one invocation. If ASR, deterministic parsing or spoken structure changes that prefix, correctness requires cleaning the affected final text again. An ASR segment boundary does not always end a sentence, so some work must remain open.

**Confirmed prefix defect:** the matcher claimed to squeeze whitespace but consumed only one character of a run. Equivalent double spaces, tabs and paragraphs could invalidate a good head. It also accepted a prefix ending inside a revised word (`Report` matched `Reported`), risking incorrect reuse. Actual matching now consumes complete whitespace runs, checks the word boundary, and preserves the remainder's internal paragraph breaks.

**Confirmed cleanup serialization:** the router waited for the head before submitting the independent tail. In a real-router regression, a head finishes only when the tail starts; the original discarded its polishing after grace and the corrected producer keeps both polished parts. Their waits now overlap. A second actual-session regression confirmed that head grace could expire while tail cleanup continued, discarding a polished head that was ready by delivery. The same group task now publishes its completed result in its existing group metadata. After the tail returns, the router takes that ready result without another wait, task, model pass, or grace. The default two-second head grace remains unchanged. This preserves the existing semantic route, layout feature and guard.

**Confirmed Apple deadline defect:** the formatter raced its response against a timer inside a structured task group. Swift joins cancelled children before that group returns, so native response work ignoring cancellation defeated the deadline. An actual formatter fixture with a blocked response failed the original 250 ms caller bound. The corrected path uses the existing bounded-wait gate and forwards cancellation to the same response; warmth-dependent quality budgets and fallback stay intact. A timeout bounds the caller, not the physical lifetime of already entered native work.

Layout planning already starts beside semantic cleanup. A rules route now has a bounded grace; the semantic route retains its scaled plan budget. A long or cold plan can still exceed two seconds. Cancelling useful formatting or shortening every quality deadline merely to lower a latency percentile would lose functionality.

### 5. Context, dictionary, tags, persistence and delivery

Screen harvesting starts at key-down on a background task. Final mention scoring and file tagging run off the main actor; candidate/loose-match limits reduce repeated phonetic matching. Debug arithmetic used to take seconds on a long transcript and many candidates. Ordinary builds now default to release optimization; `CONFIG=debug` remains explicit for development.

Dictionary correction runs regardless of the cleanup setting. Apple ASR also consumes capped dictionary and harvested-name bias phrases; the current Parakeet implementation has no recognition-time vocabulary-bias call. Its guarantees come from post-recognition correction and tagging. That matters for unusual names: a dictionary can correct a known variant, but cannot recover arbitrary words omitted or replaced by the recognizer.

**Confirmed feature defect:** the finishing producer gathered screen context only inside `cleanupEnabled`. Turning polishing off therefore passed an empty context to file tagging. The actual finishing-path regression starts from an already recognized sentence, supplies a captured profile/context, and observes real narrowing, dictionary, tagging, history callback and insertion boundary. Original output lost the tag; corrected output retains `@src/login.ts`. It performs no microphone/model call or external insertion and uses the harness preference domain. File tagging uses the captured target and screen context, after dictionary correction. It cannot invent paths absent from the harvested context. Context inspection itself is limited by application accessibility support. A slow or unavailable tree can leave a less useful candidate list.

**Confirmed measurement defect:** history recording cleared `releasedAt` before release-to-insertion measurement. An actual microphone/controller hold failed its new span assertion despite successful delivery. The producer now retains the same key-up timestamp across history filing; the unchanged native regression passes. This repairs measurement rather than being claimed as a speed improvement.

History is filed before external insertion so the words remain recoverable if insertion fails. Its append is synchronous on the main actor and can contribute disk latency. Moving it off-thread must retain ordering with edits, pruning and deletion; a casual fire-and-forget append could resurrect deleted rows.

Insertion prefers an accessibility write verified by caret movement, otherwise uses the pasteboard. The fallback intentionally waits 40 ms before paste and 80 ms before it reports delivery; optional Return follows successful placement. Clipboard restoration runs later and preserves an intervening user copy. App-switch activation has bounded polling and settle time. Removing those waits without actual destination receipts could paste old clipboard content or submit before paste arrives. Injecting provisional words into arbitrary external applications would also require a reliable way to replace exactly our text while preserving user edits; many supported apps cannot expose that range. Live provisional text therefore belongs in our nonactivating UI, with one final external insertion.

### 6. Presentation

The inherited notch/HUD implementation now automatically exposes live words and keeps raw text visible under “Writing it out…” and “Tidying up…”. This session additionally gives the Dictation screen its complete live transcript with automatic scrolling, rather than hiding it behind history. Enter stops an active button recording on that screen. It does not start an idle recording or intercept Return in another application.

The original island verification found an invisible panel retaining mouse interception after a problem card was hidden. Dismissal now releases mouse interception and clears the hit rectangle immediately. The original island flag failed and the corrected flag passes. Native Computer Use was not approved to access Next Notes, so normal window interaction and Enter remain visually unverified. Synthetic native island rendering was inspected and shows raw words under the polishing label.

## Optimization choices

| Option | Assessment |
|---|---|
| Keep ASR warm; capture before model readiness | Already wired; cold startup can still be slow and pending audio is bounded. |
| Freeze pause segments and run only the open tail | Already wired; real audio evidence below; preserve multilingual TDT and validate forced-cut WER. |
| Earlier first partial; immediate committed updates | Implemented here; no increase to sustained refresh frequency. |
| Publish completed semantic text while final layout remains pending | Actual finishing router/controller original regression fails; fixed debug passes; optimized publication/physical paint acceptance remains. Final external insertion/tags/formatting stay intact. |
| Cancel the actual parked checkpoint, not just its caller deadline | Original scheduler fails12assertions and actual native cleanup fails3owner/successor assertions. Fixed61082 passes unchanged cases, native prefix/control, races and priority tests. Owner11.447s stall attribution remains open. |
| Compact layout transport with source-constrained grammar | Three native transports are faster in isolated warm diagnostics but fail5/10/6existing assertions. Archived after rejection; geometry does not prove semantic grouping. |
| Live full text, notch/HUD text and raw text during polishing | Wired; native appearance still needs a normal owner dictation. |
| Clean committed groups while speaking | Already wired; redundant parsing, matching, overlapping waits and late-result retention repaired here. |
| Pre-clean closed spoken structures | High priority follow-up: incremental Stage A and final spoken-structure rendering can disagree, invalidating the head. Carry the existing parser state and reuse only closed, stable structures; incomplete lists/code/tables must retain final parsing. |
| Keep real deadlines when native work ignores cancellation | Apple producer repaired through the existing bounded gate. |
| Cold-model fallback and interactive cleanup admission | Already wired; existing launch/pressure/fallback warming retained. |
| Use one resident verified model and cached prefix | Existing owner policy; stored roles preserved. Memory pressure and explicit other-model choices still matter. |
| Pre-stage Apple cleanup and layout | Already wired; prompt-specific and one-use; context changes can miss the staged prompt. |
| Bound layout waiting | Rules route already bounded; semantic quality/layout budget preserved. |
| Release optimization | Default build changed here; avoids shipping debug ASR and phonetic matching. |
| Cache-aware streaming ASR | Promising for true one-chunk finish; requires multilingual/real-dictation accuracy and resource evidence before model replacement. |
| Overlap/context at forced ASR cuts | Could reduce split words; needs timestamp-based ownership/deduplication and original-script WER, not string concatenation. |
| Prompt-lookup speculative decoding | Attractive for copying cleanup input; requires llama.cpp integration and exact guard/feature/latency evaluation. |
| Emit bounded edits instead of a full rewrite | Can reduce output tokens substantially; offset validation, structure, corrections and tone need a real quality contract first. |
| Batch multiple LLM sequences | Existing runtime owns one native context. A width of two tasks does not establish two independent decode sequences; native capacity/residency evidence is required. |
| Rules-only short-text default | Would drop chosen semantic cleanup; rejected as a benchmark shortcut. Existing explicit busy preference retained. |
| Adaptive faster partial refresh | Could reduce the one-second steady cadence; measure encoder duty and ASR/voice/cleanup contention before increasing sustained inference frequency. |
| Preserve unreported hardware audio at key-up | Timestamp a final callback covering the boundary rather than adding a guessed sleep; requires actual microphone/acoustic/rapid-turn proof. |
| Recognition-time term bias for Parakeet | Could improve names, but extra CTC/enhancement passes need latency, hallucination and corpus evidence; existing dictionary correction remains. |
| Discard successfully committed recognition PCM | Implemented in the source candidate through the existing array/absolute offset, preserving failed/backlogged and retry audio.18 original/current actual-engine cases preserve slices/events/results with substituted native boundaries. Native replay pending. |
| Reuse the committed transcript string | Implemented in the same candidate; replaces its array rather than adding a second store. Empty/Unicode/failed/overlapping cases match. Native consumer proof pending. |
| Scalar phonetic matches | Integratedc5d295b;4487 component assertions and31 unchanged dictionary tests pass. Context narrowing saves16–18ms on the measured200-candidate fixture, without changing tags/scores. |
| Full-audio quiet speech benchmark | New explicit diagnostic retains all reference/input audio. The historical RMS-trimmed replay cannot prove quiet-tail accuracy. Native speech controls remain pending. |
| Reduce capture callback size or adopt sink input | Existing opt-in sink needs actual microphone/route/rapid-turn proof; don't guess from a requested tap buffer size. |
| Move history append off main actor | Possible small win; needs serialized mutation ordering and durability proof. |
| Remove paste/app-activation settle waits | Small ceiling versus cleanup; requires destination-specific effect evidence before changing delivery reliability. |
| Cloud cleanup | Can be fast, but needs explicit dictation cloud consent; local behavior remains the requested default. |
| Pipelined successive holds during finishing | Separate ownership/order/receipt contract; existing D-13 observation gate remains open. No second task queue was added here. |

## Acceptance and limits

Original cleanup-router regression: five failures; corrected router: pass. Original actual capture boundary: only `[0]`; corrected actual boundary: `[0,1,2]`, immediate admission closed. Full native controller self-test: pass, including startup release, retained audio, cancellation, stale delivery and return to idle.

Original real-time 60-second fixture: trailing 300 ms silence → 119 ms final; release on speech → 369 ms final. Busy time 9.5/21.0 seconds (16/35%); disagreement against a whole-buffer decode 0.007. The two conditions ran at different host load; this is not a stable device-floor measurement. Disagreement against another recognizer pass is not ground-truth WER.

Standalone MiniCPM cleanup eval still reports three assertion failures: grammar repair left “what you need for me,” a long dictation retained “you know,” and `UI/UX` differed from the literal `ui ux` expectation. Fast model generation does not establish perfect cleanup. Owner isolation reports 21 files and 33 defaults unchanged, but its embedded unrelated browser/tool-loop fixture fails in both original and corrected bundles. That inherited aggregate failure is not a dictation pass.

Final build, replay, independent-script accuracy, related regression and artifact-cleanup results are recorded below.

The requested two-second polished result remains an acceptance target, not an achieved universal guarantee. Already-visible text persists immediately at release. A fresh fixed-shape ASR pass, a cold fallback, a long final clause, a prefix invalidation, or an unfinished structure plan can still take longer. Completing cache-aware recognition and reducing rewrite tokens require quality evidence; they cannot be claimed from these bounded fixes.

## Final staged build and measured results

Final signed optimized bundle: `/Users/sergekadjo/Library/Caches/NextNotesBuild/install-75337/Next Notes.app`. Built with `make app CONFIG=release` in 669.13 seconds; 13 touched source/build hashes remained unchanged through compilation. The app binary hash and exact source pins are retained in the evidence directory. No replacement of the installed daily app was performed: `AGENTS.md:1792–1809` explicitly holds installs pending the native shutdown contracts. Native Computer Use was denied for Next Notes, so normal Dictation-window Enter/scroll interaction is unverified.

Compiler-idle, real-time optimized replay on this M3 Air:

| Input / ending | First nonempty partial | Recognition after release | Encoder busy | Independent word error |
|---|---:|---:|---:|---:|
| 60.5 s / 300 ms after speech | 505 ms | 100 ms, awaits existing pass | 8.4 s / 14% | 5.1% |
| 60.2 s / on speech | 502 ms | 89 ms, fresh tail pass | 8.3 s / 14% | 5.1% |
| 121.1 s / 300 ms after speech | 502 ms | 112 ms, awaits existing pass | 17.0 s / 14% | 5.1% |
| 120.8 s / on speech | 495 ms | 84 ms, fresh tail pass | 16.9 s / 14% | 5.1% |

The independent script's whole-buffer WER is 4.4% for one copy and 3.7% for the doubled copy; segmented WER is 5.1%. Different chunk merging/context on the full-buffer long route changes its answer. Segmentation adds roughly 0.7 percentage points on the single copy, and is not accuracy-neutral on this corpus. Numbers/name rendering can contribute to strict lexical WER. This is **recognition only**, not release-to-polished-insertion timing or a paired Wispr accuracy comparison. The debug run under compiler load was 276/295 ms after release and 488/731 ms to first partial; host load and optimization both differ, so their separate contributions cannot be inferred. Voice load was not controlled; these are not the roadmap's ASR-plus-voice device-floor acceptance measurements.

### Final functional and quality verdicts

- Final release bundle: `CLEANUP_ROUTER_OK`, `CAPTURE_OK`, `ISLAND_OK`, native `DICTATION_OK`, and both real-model replay runs `DICTATION_SEGMENTS_OK`. Native key-down-to-capture was 90 ms with a deliberately delayed 1.5-second engine start; about 39,801 of 40,000 expected pre-roll frames reached the fake recognizer. This proves capture/startup ownership, not microphone recognition accuracy.
- Earlier completed debug source checks: ten flags in `ready-checks.json`, plus native dictation and island. Dictionary tests: 30 tests, 137 parameter cases, pass. Original producer failures and corrected results remain in the [evidence folder](2026-10-07-evidence/README.md).
- Final optimized MiniCPM evaluation: 42 cases, resident before the leg, median 601 ms, warm median 583 ms, warm maximum 5,121 ms, **CLEANUP_FAILED: 3 assertions**. Exactly the same three expectations fail in the earlier run: R6 preposition repair, C21 literal `ui ux`, and C21 filler removal. One prior direct optimized attempt exited with SIGTERM/status 143 before a verdict; it is not counted as a pass. The final normal LaunchServices run completed and retains its genuine failing verdict.
- A further quality-gate weakness is visible in C18: the standalone model changes `npm run dev dash dash host` to `npm run dev on host`, yet the case passes because it checks fencing and `npm run dev`, not the exact command payload. This is evidence that the existing evaluator misses corruption, not proof that the actual pre-rendered production router does the same. A production-path literal-code/quotation regression and exact payload contract remain necessary before claiming those outputs are protected. No grader was loosened or output scrubber added here.

### Handoff and next priorities

The bounded source fixes are retained uncommitted on canonical `main`, alongside the existing owner's edits; no whole-file staging, branch, worktree or owner-store migration was performed. The task-only patch preserves the captured pre-task working-tree baseline. The roadmap status was updated locally; `roadmap/` is deliberately Git-ignored, so that update is retained locally rather than force-added.

Next implementation priorities are: (1) structure-aware reuse of closed cleanup prefixes with exact literal payload protection; (2) fewer generated cleanup tokens through evaluated bounded edits or prompt-copy speculation; (3) recognition context/bias and forced-cut quality evidence; (4) paired complete-delivery benchmarks including cold starts, rapid holds, names, quiet speech, real microphone endings and concurrent voice. The current evidence does not prove a universal sub-two-second polished result, parity with Wispr accuracy, or broader native-shutdown readiness.

Removed 17 confirmed obsolete task bundles plus the disposable doubled WAV after process checks, reclaiming 3750452 allocated KiB (3.58 GiB). The current useful signed release bundle, shared caches/models, original source pins, exact patch and compact evidence are retained. Exact paths and sizes are in [`cleanup.json`](2026-10-07-evidence/cleanup.json). No unrelated caches, models, recordings, user data or unresolved worktrees were swept.

### Latest complete-path evidence

The [continuation report](2026-10-07-live-preview-and-layout-wire.md) now includes signed62791's two real-time121s replays: raw recognition47/36ms, completed cleanup publication423/424ms, final6433/6320ms; all30 heads retained and raw/final WER5.1%. Layout hits its unchanged6s timeout twice. Early observable publication is verified; physical paint/insertion and the universal2s polished target remain open. Short final2251/1863ms still exposes a head wait, and fresh-process ASR startup22.732s is distinct from live-text latency after start. Pre-clean heads currently omit their attempt trace; zero model/cache counters cannot classify those waits. Small cancelled-waiter, RMS reuse and bounded visible-text candidates preserve content and await final signed consumer verification.


## 8 October continuation and source adoption

The source candidate now uses absolute sample offsets to discard successfully committed PCM and a single accumulated committed string/count. The18 original/current cache-only engine cases preserve all audio inputs, stream events, final strings and key-up plans. Normally drained121s peak logical PCM falls7.744MB→0.2784MB; a failed/backlogged model pass still retains needed audio. This is not native WER, native latency or total-process memory proof. The exact three-path patch is applied only after all peer native/compiler work joins, with all original hashes matching signed68784; signed fourth-build verification remains pending.

The accuracy evidence is still insufficient to declare parity with Wispr. Owner history has13 edited rows but only one retains both original ASR and final output; that one has normalized edit distance6/15 before cleanup versus1/15 afterward. A user edit may rewrite intent, so this is feedback rather than independent acoustic ground truth. It supports retaining semantic cleanup while fixing its speed; it is not a general quality benchmark. The21 Oct7 non-command timing rows show14over2s, median3.207s and98.05% median cleanup fraction among slow rows. Four of six layouts time out. See [the current exact evidence and acceptance](2026-10-07-live-preview-and-layout-wire.md).


## Latest quiet-speech finding and fifth build — 8 October

The fourth signed476d whole-input acoustic control is now run: independent full-buffer WER4.4%, streamed WER9.6% twice, and both key-up decisions skip new inference as `committed-only`. Original signedcff also omits the public final phrase in two actual Core finishing runs: the script ends “Great, I will send the summary tonight.”, while delivered output ends “Great.”. Completed cleanup publishes337/406ms after release; final4875/4926ms hits the4.8s layout timeout. A fast ASR return that discards words is not an acceptable speed result. The full reference's exact quiet words were not retained in that older diagnostic, so its WER alone does not prove which tail words it recognized.

The responsible key-up producer tests coverage of above-threshold speech rather than all accepted PCM. Fifth source now requires captured sample coverage before reusing a result; an uncovered remainder goes through the existing final-tail inference. Same native models, segment thresholds, queues and fallback are retained. Four actual-engine cases with substituted native boundaries fail2 originally and pass4 after this repair. This is coverage proof, not native recognition or latency acceptance. Native candidate, literal-silence/noise controls, quiet partial scheduling and pause-cut quality remain open. Necessary additional final work is measured rather than counted as free.

Fifth diagnostic output retains explicit public replay reference, raw and final text files for independent comparison. Its phase fixture exercises the real native parked-cancellation path, but Runtime/Scheduler instrumentation remains unchanged until the original missing-phase assertions run. The owner11.447s cleanup stall is still unattributed. Source is frozen through the shared signed build and no inference overlaps the compiler. This candidate is uninstalled; the AGENTS native-shutdown installation hold remains.

Computer Use now permits read-only Next Notes inspection: the observed window shows no selected or visibly recording meeting. No interaction was taken. This replaces the earlier access-denied limitation for observation only; actual button/Enter/live-paint, physical capture, external insertion and concurrent ASR-plus-voice acceptance remain unverified. Exact current results and lifecycle receipts are in the [continuation report](2026-10-07-live-preview-and-layout-wire.md).


## Confirmed quiet-pipeline failure and native phase baseline — 8 October

The signed fifth app (`7b3c7349`, uninstalled) still fails quiet-word acceptance. On the independently aligned 52,566-sample public last-turn window, direct Parakeet recognizes all seven words, “Great, I will send the summary tonight.” Streaming through the actual engine returns “Great.” with the 300 ms ending and “Great. Yeah.” at file end. Both streamed results have 85.7% independent word error. First nonempty partials arrive at 3,084/3,087 ms; final-tail work is 103/79 ms. Captured-sample key-up coverage is necessary but does not repair an already frozen incorrect segment.

The next incorrect producer decision is confirmed in `DictationSegmenter.advance`: with every frame below the shared RMS floor, three seconds of recognizable quiet speech is classified as one continuous silence run. The pause rule cuts that run in half at sample 24,000, inside the spoken turn. The engine also suppresses live-tail requests while no frame exceeds that floor. The model itself can recognize the complete phrase. This evidence distinguishes broken admission/segmentation from an incapable recognizer.

The identical input fails two original component assertions. A cache-only pause-cut candidate requires observed above-floor speech in the open segment before declaring its trailing RMS pause. It passes those assertions, preserves four ordinary pause/hard-cap controls and keeps long quiet input under the existing hard cap. **Native fixed recognition is not yet verified.** Mixed louder-to-quieter speech can still create a false pause; the separate accepted-PCM live-cadence candidate also adds inference during silence/noise. Exact native zero/DC/noise, quiet words, normal long input, duty cost and concurrent voice evidence are required before adopting it. No threshold reduction or nonzero-is-speech policy has been promoted. See [the original native words](2026-10-07-evidence/fifth-release/quiet-native-word-verdict.json) and [original/fixed cut evidence](2026-10-07-evidence/quiet-cut/acceptance.json).

The actual native cleanup phase regression now runs and fails four original assertions: context, cancelled prefill without stale counts, cancelled first-token observation, and the real parked-checkpoint span are missing. Its existing cancellation controls still join while ASR holds the lane in 2.280 ms; the successor reuses 256 of 650 prompt tokens and decodes 394. Runtime/Scheduler are unchanged for this original result. The targeted instrumentation proposal uses the existing trace and task correlation; it adds no model pass, queue, store, wait or timer. This is a diagnostic repair, not attribution or a fix for the owner's 11.447-second warm cleanup stall. [Original native receipt](2026-10-07-evidence/phase/phase-original-receipt.json).

An additional cache-only context fast path avoids constructing transcript phonetic keys when there are no candidate names to match. Against the actual signed build's dictionary module, 582 exact-field comparisons pass, including Unicode, candidate counts, limits and retained metadata. Public long text costs about 1.9 ms per original call; the empty candidate path becomes constant work. This is a component CPU saving, not measured end-to-end delivery improvement. [Exact comparison](2026-10-07-evidence/empty-context/acceptance.json).

All native children joined and all 1,171 source/resource pins stayed invariant. The development heavy slot was released to the meeting peer for the shared native noise controls; product microphone/model/speaker overlap is unchanged. The owner application and defaults remain unchanged. The universal two-second polish target, quiet accuracy, physical live display/insertion and ASR-plus-voice floor remain open.


## Sixth source preparation and verified producer chunks — 8 October

The empty-name context optimization is integrated as `6a805d1`: 13 source lines plus its actual dictionary-module comparison evidence. All 3,365 other index entries were unchanged. It preserves 582 exact-field cases; the signed full-app consumer check remains pending. The authorized four-path source gap also applies the existing native completion/checkpoint phase spans and dictation hold/run correlation. Original native phase RED4 is retained; the repaired native run has not happened yet.

The next quiet-audio actor comparison uses the exact same public 52,566 samples and the production actor's feed/schedule/drain/finish code, with recognizer/converter/scheduler/registry boundaries substituted. Original fails nine assertions across five cases; candidate passes all five. The first model request moves from sample 48,000 (3 s) to sample 8,000 (0.5 s; actual voiced onset is 0.409 s). A stalled original partial leads to a final tail containing only 28,566 samples; the candidate's fresh final pass receives all 52,566. Three exact-zero holds of 1,600/6,400/52,566 samples invoke the model 1/1/2 times originally and zero times in the candidate, which delivers one empty final. The fixture returns an explicit diagnostic marker, not recognized speech: **these results prove request/input/lifecycle behavior, not native accuracy, first visible words, native CPU duty or full duplex.** Same retained worker, final and consumer tasks all join. [Exact original/fixed actor proof](2026-10-07-evidence/live-coverage/live-producer-acceptance.json).

The component compiler first rejected the fixture's non-Sendable condition closure. Only that harness contract was corrected, and the failed log is retained. The corrective original/candidate compile joins in 8.84 s with 245.76 MB maximum RSS; original/candidate runs take 0.21/0.14 s and 12.5/12.8 MB RSS. These are bounded component resource measurements, not model/owner latency. The ordinary development resource gate passed at 7.542 GB swap and 7.368 GB free; no exception was used. The machine slot was released after all children joined.

The shared native no-speech controls further expose the input contract: direct Parakeet gives no words for authored zero, constant DC and seeded low RMS noise. The existing complete-audio engine emits two words for digital zero in both endings, but none for DC/noise. These are finite authored controls, not ambient noise or a concurrent voice soak. [Native noise measurements](2026-10-07-evidence/fifth-release/fifth-noise-native-word-review.json). A mathematically all-zero guard avoids making recognition requests from absent acoustic signal; it neither classifies nonzero audio as speech nor removes a low-level word from the answer.

The four-path quiet/quality proposal remains cache-only pending shared source review. It contains the observed-speech pause boundary, existing live cadence over accepted PCM, exact-zero producer guard, maintained pause regressions and an optional independent word-error ceiling on both raw and full Core finishing replays. Explicit zero-error empty gold rejects any live or final text on no-speech input; checking only the final answer could hide live hallucinations. Explicit replay output also retains partial observations. It introduces no product setting, queue, persistent store, model or timer. Additional quiet/noise inference is a real cost and still needs native measurement. Final polish still exceeds two seconds in measured long replays, so the product target is open.


## Sixth compiled candidate and remaining critical path — 8 October, 05:28 UTC

The exact reviewed quiet/quality four-path proposal was applied at 05:08 UTC, before the coherent sixth source freeze. The signed, uninstalled sixth candidate `8d079a72` compiled in 810.30 seconds (819.16 seconds including bundling). Strict signature verification succeeds and all 1,173 source/resource pins are invariant. This supersedes the earlier cache-only status; it is **compiled, not native accepted or installed**. The candidate includes the native timing observations, exact-zero producer guard, quiet pause/cadence changes and independent live/final word-quality assertions. The root meeting peer runs its coordinated bounded checks first; model work requires a fresh ordinary resource gate. [Bundle receipt](../meeting-reliability/2026-10-07-quality-loop/sixth-candidate.json).

The actual MiniCPM formatter allows **eight seconds after admission for up to twenty words**, scaling to fifteen seconds for longer text. On timeout it cancels that same native job and then calls Apple on the original transcript. Therefore resident weights alone do not imply a quick answer, and fallback cost is sequential. The owner's 11.447-second warm cleanup fits this possible path but remains unlocalized until correlated phase observations exist. The 250 ms admission ceiling is separate and does not bound admitted context, prefill, scheduler parking or generation. Reducing the timeout would not repair those producers and could reduce successful cleanup.

Long layout is a distinct confirmed bottleneck. The global plan is launched by `CleanupRouter.finish` after key-up, even when all thirty semantic groups were prepared during the hold. It overlaps only the remaining tail cleanup. The actual 121-second replay takes approximately 6.3 seconds and times out layout at six seconds; completed cleanup can already be published around 0.42 seconds. Live semantic pre-cleaning does not pre-compute this whole-passage plan. A future overlap/incremental layout change must preserve cross-sentence enumeration, quotations, commands, paragraphs and exact remapping; a smaller or chunked prompt alone has failed quality checks and is not adopted.

Two further cache-only experiments are prepared without changing the frozen source: consuming the existing completed-head boxes without creating deadline workers, and verifying copied input-token proposals in bounded native batches through the same runtime/sampler. Their pure/producer fixtures are prepared but uncompiled; neither is an end-to-end speed or accuracy result. The token prototype remains explicit SelfTest-only and cannot become a default without exact native sampler/KV/cancellation and feature-quality evidence.


### Bounded next-component results — 05:40 UTC

The actual incremental producer/lane/splitter and extracted unchanged router resolution bodies pass742 checks: ready, expired, empty, whitespace, fallback-spoken, legacy-head and unfinished/cancelled deadline behavior. The formatter model boundary is substituted; the whole router/native product remains unrun. For300resolutions of30ready groups, the original makes9,000deadline calls in54.929542ms; the proposed path makes zero in3.432958ms. This saves approximately **0.172ms per30-group component resolution**, not seconds. The exact9-line proposal remains unapplied under the shared source freeze. [Producer comparison](2026-10-07-evidence/ready-heads/component-acceptance.json).

Copied-token continuation lookup passes19,138 independent reference cases, including overlapping/repeated matches, empty/short/no-match inputs, negative/zero/Int.max limits and full signed token-ID bounds. One-thousand lookups in100/1,500/6,000-token repeated inputs take0.955/14.359/45.808ms. These are helper CPU observations; repeated phrases may match earlier and they are not worst-case guarantees. Actual native batches, sampler numerical behavior, rollback/cancellation/cache and delivered quality are **unrun**. No input tokens are copied into a delivered result by production. [Lookup boundary comparison](2026-10-07-evidence/prompt-copy/component-acceptance.json).

Both small compiles join in3.515/1.000s with maximum sampled compiler child RSS164.18/143.92MB; both runs join in0.299/0.261s and maximum run RSS12.714/5.964MB. All1,173Sources/Resources pins stay unchanged. Relay589 admitted only these two immutable component compiles/runs under explicit max9GBswap/min6GBdisk/free≥60%; the ordinary max8/min6.5 gate **did not pass**. No model/native app ran, and the heavy slot was released immediately after the joined fixtures. This exception is not a product resource policy or full-duplex acceptance.


### Native phase diagnostic repair accepted — 05:45 UTC

The exact original four-failure native phase fixture now passes on signed sixth8d079a72. Actual private-S1 CPU completion emits context3.5µs (existing2,048-token context), cancelled prefill550.975ms with `counts=unavailable`, first-token551.644ms with `no_token=true`, and a single cancelled parked checkpoint1.716ms. Cancellation joins while the actual ASR scheduler reservation remains held in2.341ms; the refused successor does not enter and the later successor retains256cached/394decoded/650prompt tokens. This fixes missing/stale diagnostic observations; it does **not** attribute or repair the owner's warm11.447s cleanup. [Exact original/fixed evidence](2026-10-07-evidence/phase/phase-original-fixed-acceptance.json).

The launcher and exact native process join in11.332s with36samples: peak sampled charged footprint434.686MB and RSS983.826MB (different metrics, not continuous peaks). All1,173source/resource pins stay invariant. This runs only under the separately reviewed relay592 max9swap/min6disk/free≥60% CPU-phase exception, with240s/3GB/AppKit-drain guards. No physical ASR, Parakeet, Apple, Metal, full Core or owner application change occurs; ordinary resource gate remains refused. Exact quiet/noise/mixed-level native words and8/60/121s full-feature delivery are still required. Fifth original is retained for ASR/duty comparison, sixth candidate and explicit rollback retained; heavy slot released after all joins.


### Exact quiet native attempt contained during loading — 06:02 UTC

The separately reviewed exact7word ASR attempt on sixth8d079a72 does **not** establish a fixed word result. It is stopped during Parakeet loading when available disk falls below the explicit7GB scope threshold (start7.315GB, later6.847GB). Exact owned process90316 is asked to terminate through AppKit; launcher and native process both join in21.987s. Replay reports unavailable/CancellationError and `DICTATION_SEGMENTS_FAILED`; no retry, noise/fullCore call or background orphan is counted. Nineteen process samples observe peak charged footprint203.179MB/RSS579.076MB, with all1,173source/resource pins unchanged. [Guarded attempt](2026-10-07-evidence/sixth-release/quiet-fixed-receipt.json).

The filesystem observation is real: `df`, statvfs and shutil.disk_usage agree at6.8465GB after the attempt. The approximately470MB free-space change is not yet attributed to an allocating writer; no shared model/system cache is removed. This attempt used the narrower reviewed max8.5swap/min7disk/free≥60%/1GBfootprint/90s ASR-only scope, not the ordinary max8/min6.5 gate. Accuracy, native first partials and actual changed cadence duty remain open on this candidate.

The peer's independent native MeetingSession case reaches final7/7 words on both tracks but fails its live7word assertions: the RMS pause produces32,000+20,566sample pieces and an incorrect ending. All six native calls succeed, and the full52,566sample final clause is correct. That confirms continued upstream fragmentation in the meeting path, not a passing global word-count test or a dictation verdict. No production meeting pause/admission change is promoted.

### Cold load follow-up: native compiler timing, not warm-cleanup attribution

The guarded sixth run overlaps an actual ANE network compilation from 02:02:16.472 to 02:02:30.857 local (14.385s). All five installed public model assets satisfy the current downloaded-file producer thresholds and predate this run. The dependency loads component models sequentially. This supports investigating component load/compilation and startup readiness; it does not establish the warm owner11.447s cleanup cause or prove a parallel-load gain. The temporary ~470MB free-disk reduction recovered without task cleanup; readable scoped cache metadata did not identify its writer. No model/system cache was removed. See `2026-10-07-evidence/sixth-release/cold-load-readonly-review.json`.

### Per-pass silence is a separate producer contract

A whole hold with words can still contain wholly silent inference inputs. The actual copied Engine fed the unchanged public quiet seven-word PCM with sixteen seconds of exact digital zero before or after it. Original emits one leading and five trailing all-zero native inputs; the three-line candidate before ASR lane acquisition emits none. Ordinary quiet and entirely silent controls remain correct; nonzero request lengths and nonzero-sample counts match. Every worker, final task, consumer and sampled owned CLI descendant joins, with normal8/6.5 resource admission and1173 invariant source pins. Native recognition/converter/scheduler/registry are substituted; this verifies input production, not native word accuracy. Candidate remains outside canonical Sources pending a coordinated source gap. Both versions still perform fifteen growing-tail requests after quiet words before the hard cap: that larger cadence inefficiency remains open. Evidence: `2026-10-07-evidence/per-pass-zero/component-acceptance.json`.

The second sixth native quiet attempt was admitted by the ordinary gate (swap7.858GB/free7.310GB) but hit the6.5GB disk guard during model loading and joined in22.886s. It produced no recognition result; neither guarded attempt supplies fixed-word acceptance. Source1173 stayed invariant; sampled candidate footprint199.9MB/RSS651.6MB does not include the Neural Engine compiler service. No additional native retry is queued.

### Cold compiler follow-up excludes unrelated macOS messages

Both scoped native process logs map a445,187,200-byte file (the encoder weight size) during ANE compilation; the second network compile lasts15.379s. A mapping does not establish a created-file allocation. The “No persisted cache” message is from libMobileGestalt; the1/2/4s retry messages are AppIntents and overlap loading without proof of blocking recognition. Root-owned compiler temporary paths are redacted/inaccessible, and run-owned temporary files were removed after join. Created-file category/size/lifetime remains unobserved. A metadata-only observer passes8 authored controls (creation, unchanged/growth, deletion, symlink exclusion, truncation and exact owned-root refusal); no native attribution run is authorized or claimed.

Successive holds remain a separate producer problem: `canStartHold` returns true only for idle/error, and normal button/hotkey entry calls `reportRefusedPress` during finishing. The retained40-hold sample includes one actual finishing refusal; its D-13 observation gate is insufficient (100 holds required). Earlier option tracking already lists this contract. No Bool/session shortcut was applied: finalization currently reads mutable per-hold fields and checks the same session, so safe overlap requires independently bound hold data, ordered delivery and destination/selection refusal proof. This is code/metadata evidence, not a new actual controller overlap regression.


### 8 October: two Source7 shortcuts applied; native capacity default measured

The coordinated source gap applied only the exact per-inference digital-zero guard and completed-head deadline shortcut. Both source writers joined; the entire existing Git index was unchanged. The copied production Engine original fails two silent-inference assertions, while the candidate passes four cases; corresponding nonzero input lengths/counts match, with byte hashes still pending. The ready-head component passes 742 cases and saves about 0.172 ms for 30 ready groups. These are component results, not native word, physical paint, insertion or universal two-second acceptance. See the [source receipt](2026-10-07-evidence/source7-two-hunk-receipt.json).

The exact linked native library now reports logical default `n_batch=2048`, physical default `n_ubatch=512`, context default 512, and output maximum zero (the pinned header defines zero as logical batch maximum). Our Runtime overrides logical batch to 512 and uses a dynamic context, but leaves physical batch at 512. Every actual Runtime prefill chunk contains at most 128 tokens; generation/trial chunks contain one. A cache-only 128/128 capacity candidate preserves those submitted chunks. It may reduce graph/output reservation; actual allocation, numerical parity and workload performance are not yet measured. The model-free defaults executable initializes no backend, device, weights or context. Compile/run exit zero, all owned processes join, normal resource admission passes and 1,173 source pins remain invariant. See [native defaults](2026-10-07-evidence/native-batch/defaults-acceptance.json).

A separate cache-only allocator diagnostic copies the existing native context-construction seam and emits only numeric compute/output/KV/recurrent buffer metadata plus effective capacities. It restores the exact prior native log callback and user context, and prints no native log line, prompt, token or model path. The parser and model arms are uncompiled/unrun; CPU graph metadata would not establish MiniCPM Metal, owner warm-delay attribution, quality or the ASR/voice throughput floor. No capacity/default, copied-token, layout transport or signal-cadence candidate is promoted.
