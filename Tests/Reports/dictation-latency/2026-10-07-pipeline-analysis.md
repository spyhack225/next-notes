# Dictation pipeline audit — 2026-10-07

Scope: the macOS production path in the current canonical working tree, including its pre-existing, uncommitted latency work. Reference hardware: this Mac is Mac15,12 (M3 Air), 16 GB. Owner histories were read only as timing fields, counts and enums. No dictated text, recordings or account material was exported. Synthetic repository fixtures supply the audio tests.

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

Capture order is preserved by one audio stream and one feeding task. Thirty seconds of pending PCM can accumulate during startup; exceeding that cap drops newer packets and counts them. The 180-second retained recording cap belongs to retry/compare storage, not to the normal engine feed. It does not truncate a successful long dictation, but it prevents complete retry/comparison of a longer recording. The engine separately retains the complete hold in memory.

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
