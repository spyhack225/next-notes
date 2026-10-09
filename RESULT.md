Round-2 producer fixes for no-apple / relay claude2-no-apple. Read the full Round-2 REVIEW.md and RULES-2. Starting reviewed tip: `3b1f1038`. Four commits, one per assigned finding; no install, push, merge, GUI opening, owner-store seeding or foreign cleanup. Findings 3 (Settings UI) and 8 (peer counters) remain integration-owned; ModelsSettingsTab was not edited.

| Finding | Commit | Original / fixed evidence |
| --- | --- | --- |
| 5, census | `47b5a9c7` | 21 mutations: original misses Swift env arguments, C arguments and bare shell stdin synthesis (3); fixed misses 0 |
| 1, presentation | `33a19729` | Actual capture/audio/VoiceSession/Island: 4 publication/suppression failures -> 0 |
| 2, stale failures | `677e8caa` | Actual isolated Settings writer/file adapter: 9 availability/new-entry failures -> 0 |
| 4, unknown pressure | This report's commit, titled “Reobserve unknown pressure through the existing optional model guardian” | Actual guardian/notification/preparation consumers: 2 stranded-owner failures -> 0 |

Finding 1 cause: IslandOwnership enabled publication unconditionally; VoiceSession used that flag in ordinary sessions, even when Pocket/Kokoro exposed no qualified resume capability. The presentation owner now reads that actual capability and releases an already-published projection when it becomes unsupported. An unsupported route cannot publish reducer commands or suppress legacy Island writes. The regression selects each actual production route to check capability, then substitutes only its receipt-incapable player; actual capture renders, provisionally pauses, discards “mm hmm” and physically resumes the retained scripted output. Awaiting-resume/pending proof remains diagnostic; no resume receipt is invented. Receipt-capable simulated/native companions still pass. Earlier green checked the new capability property and capable-fake reducer behavior, never ordinary Island publication through an unsupported player. Native Pocket/Kokoro physical playback and positive post-resume proof remain unverified/unimplemented.

Finding 2 cause: the file failure setter compared the engine string after its await. Returning to Pocket made an old Pocket error current again; explicit recovery of a concurrent failure had the same race. File admission now captures engine, the actual Settings writer's in-memory selection revision, and the preparation revision. Failure settlement checks that exact request. Reply failure uses the captured reply request plus its existing playback token. Explicit preparation advances its revision; cancellation still cannot latch a failure. No persisted preference/store, model pass, await or implicit retry is added. The regression holds the actual file adapter's external generator across Pocket -> Kokoro -> Pocket (with and without explicit preparation), a concurrent playback failure/retry, and old cancellation. It then invokes the same adapter for a new clause and verifies actual entry, not only a ready label. Settings writes are guarded by usesHarnessPreferencesForTesting and restored. Native expensive generation alone is substituted. Earlier green reset the latch with a helper and checked sequential errors; it never held an admitted old clause across real recovery/selection.

Finding 4 cause: unreadable/unknown kernel values became warning at cold seed, with no future read unless a kernel event arrived. The existing guardian now retains one utility timer ONLY while the seed is unknown. It re-reads every two seconds, keeps unknown deferred, and stops on a valid read or kernel event. Reads occur outside the state lock; admission is revalidated under that existing lock. The existing notification retries the existing Pocket/Kokoro owners and background lane; known warning/critical values still require kernel recovery, genuine model errors still require explicit retry. No foreground path waits on the timer, and no second voice preparation owner exists. The unchanged fixture injects unreadable, unreadable, normal, supplies no normal event, and verifies both actual owners initialize exactly once (Pocket also warms once), stop showing preparing, and stop polling. A separate real receive(.critical) check retires the unknown retry without admitting optional work. Kernel reads and expensive native entries are scripted; actual callbacks/scheduler/admission are production code. Earlier green manually posted a normal event after warning/critical, so it supplied the very recovery trigger missing from the unknown seed. This is a liveness regression, not real kernel-pressure or reference-machine performance evidence.

Finding 5 cause: ordinary Swift/C received only the first two patterns, excluding quoted executable arguments, and shell detection required an argument after the command. The shared scanner now checks quoted command tokens in source languages and bare end-of-line/pipe commands in scripts, retaining wrapper/exec coverage. Only speech synthesis is counted; media playback commands are not newly banned. Every exception is still an exact reasoned line with a bounded count. Four existing language-word-list lines are newly visible and explicitly allowed; total 24 exceptions. All 21 retained mutations require both native scanner exit1 and VOICE_SINK_SOURCE_FAILED, so a scanner crash is not accepted as detection. Earlier green's 17 mutations omitted ordinary source executable arguments and shell stdin/end-of-line invocation. The requested two escapes and a C counterpart fail original/pass fixed; exec coverage stays detected. Final actual repository census is forbidden=0, exceptions=24, files=908.

Exactly one normal heavy.sh FIFO60 slot (`RELAY_ID=claude2-no-apple`) built original and fixed, ran the unchanged producer fixture, the 12 requested flags, four receipt companions, authority63, residency and scheduler. No gate override or concurrent own heavy process. Original/fixed builds completed in 276.29s / 82.75s (debug compilation, not product latency). Actual producer marker: `VOICE_POLICY_REVIEW_FAILED: 15 assertions` / `VOICE_POLICY_REVIEW_OK`. The three new Swift fixture hashes match exactly across retained source/binary pins. The RED source contains only isolated test seams beyond the reviewed product producers; red-source.patch plus the three retained fixture files reconstructs that source. Fixed source hashes match the final branch source; commit/report-only work follows the built snapshot.

11/12 requested flags pass. Settings still prints its OK assertion marker then exits -11 (SIGSEGV); it is a FAILED PROCESS, not a pass or a voice-removal crash attribution. All four companions, authority63 and the two related flags pass. Store isolation preserves 21 files/0 owner defaults while its embedded browser18 / TOOLLOOP_PRODUCTION_FAILED stays open. Prior/current normalized diagnostics are identical: delivery13, duplex2, nested browser18 + final failure; other compared voice flags have0. See diagnostic-comparison.json. Root passes do not promote those scopes, the model quality/default, the phase or broader Agent readiness.

| Check | Exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `red-build` | 0 | `NO_FINAL_MARKER` |
| `producer-red` | 1 | `VOICE_POLICY_REVIEW_FAILED: 15 assertions` |
| `green-build` | 0 | `NO_FINAL_MARKER` |
| `producer-green` | 0 | `VOICE_POLICY_REVIEW_OK` |
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
| `apple-resume-owner` | 0 | `APPLE_RESUME_OWNER_OK: 55 simulated PCM checks; native playback unverified` |
| `apple-playback-timeline` | 0 | `APPLE_PLAYBACK_TIMELINE_OK: native authored PCM callback/cursor/owner checks; audibility unverified` |
| `task-authority` | 0 | `TASK_AUTHORITY_OK: 63 cases` |
| `residency` | 0 | `RESIDENCY_OK` |
| `scheduler` | 0 | `SCHEDULER_OK` |

Final standalone census: `VOICE_POLICY_SOURCE_COUNTS forbidden=0 explicit_nonplayback_exceptions=24 files=908` and `VOICE_SINK_SOURCE_OK`. Mutation markers: original `VOICE_CENSUS_MUTATIONS_FAILED` (3 undetected/21) and fixed `VOICE_CENSUS_MUTATIONS_OK` (0/21). All logs, source/binary pins, fixture invariance, cleanup and exact original/fixed patches are retained in [round-2 evidence](Tests/Reports/no-apple/round2/README.md).

Mac: arm64, macOS27.2 / 26B5091g. Fixed binary SHA256: `5cb6650f8ae25fb67d0931ecbd1e7af8501c6a9fe258d75b3ed48a0401c211b4`. Original: `2aea8ed8170b577725247f7fe7cb9991ce2ab781a08f354a130831e076e6f5ef`. Slot exited1 solely for the Settings failed process (expected RED excluded), then released its claim. After verifying no process used it and exact source/binary invariance, only wt-scratch/no-apple was removed (2,109,678,190 logical bytes); the driver removed its exact temporary batch directory. Shared voice scratch, owner stores/models and foreign processes/files were preserved. Pre-existing untracked LAST-MESSAGE-previous files and RESULT-previous2.md are untouched.

Round-2 source files changed:

- `Sources/NextNotes/Agent/Duplex/IslandOwnership.swift`
- `Sources/NextNotes/Agent/Duplex/UnsupportedResumePresentationSelfTest.swift`
- `Sources/NextNotes/Agent/Duplex/VoiceSession.swift`
- `Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift`
- `Sources/NextNotes/Agent/Speech/KokoroAgentVoice.swift`
- `Sources/NextNotes/Agent/Speech/LongFormRenderer.swift`
- `Sources/NextNotes/Agent/Speech/UnknownPressurePreparationSelfTest.swift`
- `Sources/NextNotes/Agent/Speech/VoiceFailureEpochSelfTest.swift`
- `Sources/NextNotes/Agent/Speech/VoicePolicyReviewSelfTest.swift`
- `Sources/NextNotes/Core/Compute/ModelResidencyPolicy.swift`
- `Sources/NextNotes/Support/Settings.swift`


Will conflict with uncommitted work: `Sources/NextNotes/Core/Compute/ModelResidencyPolicy.swift` (supplied dirty inventory and review). Preserve canonical cleanup warm recovery alongside the existing cold seed/admission notification and new unknown-read retry. The complete prior branch also retains the six earlier integration overlaps: AgentTaskManager, AgentTaskStore, ModelResidencyPolicy, NextNotesApp, AgentView and IslandView. The shared task-store prerequisite stays applied exactly once and is untouched this round. Committed peer Settings/ACK/Mini integrations must reconcile synth/Settings changes; no combined build was run. The owner tracks findings3/8 in its integration manifest; relay sending is not read confirmation.

Unverified/open: audible/native Pocket/Kokoro quality and post-resume proof; real first-launch download/offline recovery and Settings interaction; real unknown-pressure kernel behavior; device/full-duplex/release performance; combined peer/UI build; Settings crash cause and inherited model/Agent gates. No installed release was changed.


## Round 4 — current reply settlement and executable census

Base `62da58a3`. Speech producer/test commit `f6265ca2` (“Settle current failed reply independently of selected voice request epoch”); census/evidence commit titled “Catch shell command strings and stdin speech sinks with retained round-4 proof”. Own worktree only. No install, push, main merge, GUI opening, manual owner-store access or seeding or foreign cleanup.

Confirmed cause: the reply epoch equality guard preceded all current output settlement even though selection or cached preparation does not replace that output. Current token/text validation now always admits its failure settlement; only the selected voice failure latch checks the request epoch. Partial/queued text receives interrupted/unheard receipts, the failed output snapshot stays failed, lifecycle/audio state clears and subsequent streamed text settles unheard through the existing owner. Explicit stop closes that text admission. No replay, voice switch, model pass, queue, timer, retry or added await. Four actual RealtimeAudioSession/StreamingSpeechBuffer/synthesizer/file-adapter cases cover Pocket/Kokoro × selection/cached preparation, including invalid token/text, queued/subsequent text, exact release/audio state, new-selection availability and new file-consumer entry. External synthesis/playback alone is scripted. The original nine failed consequences per case are 36 total; fixed has zero. The same four fixtures each retain 17 assertions.

Confirmed census cause: ordinary source patterns only found exact quoted command tokens, while shell command position did not consume stdin-only exec. The scanner now detects Process shell arguments, system/popen shell strings, piped exec with no argument, echo pipes and bare/end-of-line commands. The unchanged 29-case fixture requires exit1 plus VOICE_SINK_SOURCE_FAILED, rather than accepting scanner crashes. Original misses six; fixed misses zero. Six existing prompt/conversation/UI-copy lines have exact count-bounded exceptions. No whole-file exception or renamed synthesis allowance. The operation exception check applies to files with explicit operation allowances, preserving the existing unexpected-operation mutations. Final census: forbidden0 / exceptions30 / files908.

One normal heavy.sh FIFO slot built original and fixed and ran the same affected round-2 batch. Native RED source producer equals 62da58a3; only the synth producer differs between RED/GREEN Sources. Swift/census fixtures retain identical hashes; final Sources equal the GREEN pin. Debug builds took 283.62s / 23.19s, not a product latency measurement. Binary SHA256 original: `b12eebd5f505f2dd8aec9809f8357a9f6433f84b2871eb61010f35e0c3dc860b`; fixed: `b8f2c3c7568dbb1a429341b0500e3086ba06617a3e81f87300011e5f53ff27bd`.

11/12 requested roots pass; all four receipt companions, authority63, residency and scheduler pass (18/19 focused flags). Settings remains a FAILED PROCESS: its SETTINGS_OK assertion marker precedes -11/SIGSEGV. Wrapper exit1 includes that failure and excludes expected RED. No Settings crash attribution or promotion. Native PCM companion still reports receipts2/callback observations206/muted=true. Isolation21files/0ownerdefaults coexists with nested browser18/TOOLLOOP_PRODUCTION_FAILED. Delivery13/duplex2 divergences also remain; all six normalized diagnostic streams equal round2. These are inherited open scopes, not root-pass claims of resolution.

| Check | Exit | Exact final root marker |
| --- | --- | --- |
| `webrtc-build` | 0 | `NO_FINAL_MARKER` |
| `red-build` | 0 | `NO_FINAL_MARKER` |
| `producer-red` | 1 | `VOICE_POLICY_REVIEW_FAILED: 36 assertions` |
| `apply-fix` | 0 | `NO_FINAL_MARKER` |
| `green-build` | 0 | `NO_FINAL_MARKER` |
| `producer-green` | 0 | `VOICE_POLICY_REVIEW_OK` |
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
| `apple-resume-owner` | 0 | `APPLE_RESUME_OWNER_OK: 55 simulated PCM checks; native playback unverified` |
| `apple-playback-timeline` | 0 | `APPLE_PLAYBACK_TIMELINE_OK: native authored PCM callback/cursor/owner checks; audibility unverified` |
| `task-authority` | 0 | `TASK_AUTHORITY_OK: 63 cases` |
| `residency` | 0 | `RESIDENCY_OK` |
| `scheduler` | 0 | `SCHEDULER_OK` |

Census markers: original exit1 `VOICE_CENSUS_MUTATIONS_FAILED` (6 missed/29); fixed exit0 `VOICE_CENSUS_MUTATIONS_OK` (0/29); repository exit0 `VOICE_SINK_SOURCE_OK`. Fixture invariance and git whitespace checks pass. Raw logs, full source/binary pins, patches, fixture hash comparisons, normalized diagnostics and cleanup are retained in [round-4 evidence](Tests/Reports/no-apple/round4/README.md).

Files changed: AgentSpeechSynthesizer.swift; VoiceFailureEpochSelfTest.swift; check-sink.py; speech-source-allowlist.json; review-fixes/test-census.py; this RESULT.md; PERFORMANCE-STANDARDS.md; round4 retained reports/scripts/logs. None of this round's producer/test files is listed in MAIN-DIRTY-SOURCES.txt as “will conflict with uncommitted work”. AgentSpeechSynthesizer still requires manual reconciliation with peer ACK/Mini work; PERFORMANCE-STANDARDS must preserve peers' evidence. No peer files/processes/claims or staged changes were changed.

Not verified: physical Pocket/Kokoro output or quality; production positive resume receipts; live first-launch/download/offline Settings recovery; combined Settings/ACK/Mini build/interaction; release latency, native device duplex and reference-machine ASR+voice performance. Settings UI and peer counter/PCM integration remain integration-owned. The existing shared task-store prerequisite was not edited. No model/default/quality gate, phase or broader readiness is promoted.

Own scratch removed after wrapper completion (2078752 KiB prior allocation); own batch temp removed by finally. Existing untracked brief/history/session files were preserved. Completion and exact remaining contracts were sent through agent-relay; sending does not confirm reading.
