# Selected voice policy evidence — 8 October 2026

Historical first-pass evidence below. The [independent-review follow-up](review-fixes/README.md) supersedes the resume capability, Catch-up retry, resource admission, census and timeline claims. It retains RED19/GREEN0 actual consumers and distinct native PCM proof, while keeping Settings SIGSEGV open.

The app-generated voice is Pocket or supported Kokoro. The selected voice must report ready before a reply can enter its backing. An unavailable or failed voice leaves the answer written, with the approved plain message. A failure cancels the partial head and untouched remainder through the existing clause owner. Completed clauses remain acknowledged. No replacement voice is selected.

The incorrect producer was `AgentSpeechSynthesizer.prepareForStream`: cold Pocket selected the Apple backing, Kokoro could enter an unready backing, and allowed-voice failure selected Apple again. The Apple text renderer and its direct acoustic diagnostic constructors are removed. A later review found a reply reset could also clear a selected-voice failure; the retained `a250fbb5` probe characterizes that gap before the final selector correction.

## Evidence boundaries

`producer-probe.py` extracts nine real owner method bodies from the named revision. Only logger privacy annotations are removed. Backings, clause splitting, logging, audio settlement and surrounding fields are deterministic substitutes. `original-probe.swift` retains `c6d850c`; `failed-readiness-original.swift` retains `a250fbb5`; `fixed-probe.swift` retains the repaired owner. The same assertions exercise unavailable Pocket/Kokoro, next ready Pocket, persistent failure on a new reply, partial/untouched cancellation and no Apple fallback. This is executable producer-method evidence with substituted dependencies; it is not an original native Apple playback run.

The app self-test bodies exercise the real synthesizer, streaming buffer, reply delivery, shadow projection, capture, scheduler, permission proposal, task manager and Catch-up consumers using recording or deterministic PCM dependencies. The PCM fake independently advances enqueue, played, completion, pause, resume and interruption. Receipt tests retain token, phase, stale callback, exact ownership and cleanup invariants. Their markers explicitly say simulated PCM: neither the fake nor native software callbacks prove that a person heard audio.

`PreparedPCMSpeechBacking` retains the existing raw player transport for the parallel acknowledgement agent. It contains no text synthesis. The first batch created no instance; the follow-up instantiates it only in the actual native authored-PCM fixture. Production acknowledgement wiring still belongs to the peer. The acknowledgement integration and native transport acceptance belong to that agent.

## Retained source contracts

| Contract | Original final marker | Repaired final marker |
| --- | --- | --- |
| Availability API and approved copy | `VOICE_AVAILABILITY_SOURCE_FAILED` | `VOICE_AVAILABILITY_SOURCE_OK` |
| Selector and error routes | `VOICE_ROUTES_SOURCE_FAILED` | `VOICE_ROUTES_SOURCE_OK` |
| Apple sink/direct constructors | `VOICE_SINK_SOURCE_FAILED` | `VOICE_SINK_SOURCE_OK` |
| Legacy voice preferences | `VOICE_SETTINGS_SOURCE_FAILED` | `VOICE_SETTINGS_SOURCE_OK` |
| Normal launch preparation placement | `VOICE_LAUNCH_SOURCE_FAILED` | `VOICE_LAUNCH_SOURCE_OK` |
| Catch-up audio absence | `CATCH_UP_VOICE_SOURCE_FAILED` | `CATCH_UP_VOICE_SOURCE_OK` |

The `.log` pairs retain the actual source check results. Source checks establish source contracts, not native execution.

## Inherited build prerequisite

The first actual app build failed because the committed remount fixture at `TaskAuthoritySelfTest.swift:372` calls `AgentTaskStore.recoveredReadHistory()`, which is missing from the committed store. The unchanged call was introduced by `811f3bb4` and is present at this branch's inherited `55d402ee` base. The canonical uncommitted store has the required read-only seam. Historical commit `5f9a538b` restored that small existing-only API; it is now dropped and replaced once by the shared `20d8f9b8…` cherry-pick (`9a63761b`): it reads marked canonical rows/journal, refuses failed/unsafe stores and applies the same authority/identity/witness check as load. It creates, repairs and dispatches nothing. The fixture and its thresholds remain unchanged; the authority companion is included in same-slot verification. This is a build prerequisite, not broader recovery acceptance.

## Native batch

The single coordinated command is `RELAY_ID=claude2-no-apple ../heavy.sh 'python3 Tests/Reports/no-apple/run-checks.py'`. The driver runs copied-source probes, `make webrtc-audio`, the debug build in the shared `wt-scratch/voice`, then the requested flags and four receipt companions. Its private control FIFO permits explicit repairs and targeted rebuilds in the same slot. Each attempt is retained in `checks.json` with its log, exit and exact final marker; `binary-pin*.json` pins each built executable and source commit. Tests use their isolated stores/preferences and cached-or-absent model paths; they never authorize a real voice download.

The final restored build exits 0. Eleven of the twelve requested native flags exit 0 with their successful final markers; Settings prints its successful assertions and then exits -11 (SIGSEGV), so it is **failed**. The four migrated receipt companions and the unchanged task-authority companion also pass. The wrapper exits 1 because of Settings; this is not a wholly green batch.

| Check | Exit | Exact final marker / build result |
| --- | --- | --- |
| `producer-original-compile` | 0 | `NO_FINAL_MARKER` |
| `producer-red` | 1 | `VOICE_PRODUCER_PROBE_FAILED: 9 assertions` |
| `failed-readiness-original-compile` | 0 | `NO_FINAL_MARKER` |
| `failed-readiness-red` | 1 | `VOICE_PRODUCER_PROBE_FAILED: 1 assertions` |
| `producer-fixed-compile` | 0 | `NO_FINAL_MARKER` |
| `producer-green` | 0 | `VOICE_PRODUCER_PROBE_OK` |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `app-build` | 0 | `Build complete! (26.36 sec)` |
| `tts` | 0 | `TTS_OK` |
| `tts-stream` | 0 | `TTS_TOKEN_STREAM_OK` |
| `voice-conversation` | 0 | `VOICE_CONVERSATION_OK` |
| `voice-delivery` | 0 | `VOICE_DELIVERY_OK` |
| `voice-scheduling` | 0 | `VOICE_SCHEDULING_OK` |
| `duplex` | 0 | `DUPLEX_OK` |
| `concurrent-voice` | 0 | `CONCURRENT_VOICE_OK` |
| `voice-turn-routing` | 0 | `VOICE_TURN_ROUTING_OK` |
| `catch-up` | 0 | `CATCH_UP_OK` |
| `settings` | -11 | `SETTINGS_OK: 12 pane(s), Formatting listed, headings contain U+0020, each form built, profile captured, auto-send policy, every pane fits the narrowest host` |
| `ui-strings` | 0 | `UI_STRINGS_OK` |
| `store-isolation` | 0 | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |
| `voice-playback-projection` | 0 | `VOICE_PLAYBACK_PROJECTION_OK: 33 checks` |
| `voice-playback-resume-receipt` | 0 | `VOICE_PLAYBACK_RESUME_RECEIPT_OK: 48 checks` |
| `apple-resume-owner` | 0 | `APPLE_RESUME_OWNER_OK: 53 simulated PCM checks; native playback unverified` |
| `apple-playback-timeline` | 0 | `APPLE_PLAYBACK_TIMELINE_OK: 53 simulated PCM checks; native playback unverified` |
| `task-authority` | 0 | `TASK_AUTHORITY_OK: 63 cases` |

The final source/binary pin is [binary-pin-attempt-6.json](binary-pin-attempt-6.json), source `3dd06c6f`; prior pins distinguish each earlier build. The first failed build is retained. The running driver's initial unanchored parser incorrectly selected a quoted `_FAILED` source line from build-2 warnings as a marker; `3dd06c6f` anchors future marker parsing to actual verdict lines. Build exits and logs remain the authority, and later build records contain no such false marker. Raw `checks.json` is retained unchanged. The final driver also requires a proper native final marker (missing/absent is refused); its repaired verdict predicate was replayed against the retained actual records and identifies Settings as the only final failed check.

TTS reports `VOICE_POLICY_ROUTE_COUNTS unavailable_backing_calls=0 ready_route_selected=true stale_answer_replayed=false` and `VOICE_POLICY_SOURCE_COUNTS forbidden=0 explicit_nonplayback_exceptions=13`. The actual spoken-approval cases `unavailableVoice` and `failedVoice` both report `fired=0 onset=false` through the real permission path. Settings preference normalization also runs in TTS, where it exits cleanly. Catch-up exercises the actual task completion that retains the audio notice.

## Settings failure — open

Both initial Settings runs print `SETTINGS_OK` then exit SIGSEGV. Their owned crash PIDs41059/41211 have parent Python38774 and main-thread `objc_release → AutoreleasePoolPage::releaseUntil → objc_autoreleasePoolPop → swift::runJobInEstablishedExecutorContext`. Only sanitized process/exception/frame metadata is retained in [settings-crash-metadata.json](settings-crash-metadata.json).

A close-release ownership hypothesis is disproved by actual panel traces (both original flags are already false); the speculative panel assignment is fully reverted in `92d08ec1`, and `SettingsWindow.swift` has no final diff. A bounded native build with only the new preference-fixture call omitted still crashes (attempt4). A second build additionally restoring the original voice preference setter/initializer still crashes (attempt5). Pure helper functions remain compiled but unused in that probe. These are component-isolation comparisons, not a complete original-app baseline. Their exact hashes and explicitly dirty pins are retained in [settings-baseline-probe.json](settings-baseline-probe.json). The committed sources are restored exactly before final build6; final Settings still crashes. No Settings crash repair or native Settings pass is claimed. Its allocating/releasing producer remains unassigned and belongs to further UI/harness investigation.

Store isolation exits0 and its outer final marker is `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged`. Its nested browser production probe still prints `TOOLLOOP_PRODUCTION_FAILED`, the test-wiring defect identified in the brief; outer invariance does not establish nested tool-loop success.

## Remaining acceptance

No app was installed, pushed, merged or opened. Fresh normal launch/background download, physical Pocket/Kokoro audio, UI interaction and external VoiceOver were not exercised under the no-GUI/no-owner-store constraints. Numeric preparation progress remains nil because the existing Pocket initialization API publishes readiness/preparation/error but no fraction. No latency, release performance, voice audibility, broader agent quality gate or default-model promotion is claimed.

The source census has explicit exceptions for `UI/Settings/ModelsSettingsTab.swift` (catalog only, owned by the parallel Settings agent) and `Tools/tts_benchmark.swift` (standalone historical developer benchmark, never linked into the app). The Settings screen was not changed in this branch; integration must adopt that agent's screen. The deprecated `agentVoiceIdentifier` shim is unused by synthesis.
