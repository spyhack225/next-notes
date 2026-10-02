# Actual original/fixed playback projection verification

Installed original92 reproduces 13 assertions (8 pure, 5 actual native); fixed93 passes the IDENTICAL 33 checks. The existing reducer flag uses the same amended expectations before both builds: original92 has 6 command mismatches; fixed93 passes 10 traces and its actual capture/approval/streamed-output flow. VoiceSession remains shadow-only; no commands execute or live Island ownership changes.

## Confirmed cause and producer

VoiceContracts.swift owns the incorrect shadow state. Its provisional interruption kept the speaking projection and represented only already-playing outputs as paused. A first playback acknowledgement arriving while physically paused replaced that state with playing/speaking. Matched interrupted playback removed output without clearing speaking. Model response completion hid acknowledged playback before it drained, and onset/model completion/drain could displace a pending approval. The patch repairs those exact transitions, preserving current OutputID and turn guards. It adds no store, timer, queue, audio owner, model pass, product wait or live UI change.

The nonplaying projection helper preserves an existing proposal, then listening while held/paused, then thinking for retained response. It never reconstructs speaking from historical heard/playing. Model completion preserves speaking only when it is ALREADY visible with acknowledged playing output and a free floor. inputDiscarded/approvalResolved resume behavior remains unchanged and open.

## Actual original failure and identical fixed consumer

Both native cases use the unchanged capture.beginSession(false), real Apple playback and its existing positive-buffer acknowledgement, RealtimeAudioSession and VoiceSession listener. The first case acknowledges playback, then drives the real cumulative-speech producer into confirmed pause. The second intercepts the actual callback at the existing listener, drives confirmed queued pause, then forwards that callback exactly once while still paused. Both retain token/generation/output ownership, reject a different capture, stop through the actual owner, close the session and preserve owner stores/defaults. No synthesized receipt, fake backing or model/microphone input is used in these native cases.

Original92: callbacks acknowledged true in both modes; late pausedBeforeForward true. Eight pure contract failures and five native failures (playing pause, two stop projections, late queued pause and the unchanged legacy output comparator). Original late callback reports shadow playing versus actual paused, divergences1. All onset/identity/model/owner controls pass. Fixed93:33 checks PASS; both native modes divergences0. The recorded exact native events also replay with no invariant violation.

The preparation prediction of pure9 was wrong; actual pure8 is retained and independently reviewed. There was no fixture change after the original result. The preparatory claim that AVSpeechBacking would appear in stdout was also wrong: existing Log.agent.info writes unified logs and the class is private. app92-playback-route.log contains two selected=settings <private> entries. Apple attribution comes from the pinned explicit engine override, fresh single-flag system backing route and real positive callback; it is not a visible logged class name or proof a person heard audio.

## Identity and regressions

Only ONE Source file differs between the 1041-entry original92 and fixed93 compiler manifests: VoiceContracts.swift 1544a4e8…→574f296c…. Common native fixture8c3e6bb0…, reducer expectations56fa3ed9…, and additive registry2ab37… are identical. Every build has no Source drift; full installed bundle maps remain unchanged across checks. This is a coordinated dirty-workspace proof, not a clean-checkout compilation claim.

Fixed93 binary SHA256: 97185b8d0db11a3e798e0dc6a8774b9c689ce8977a69b17c48422147a72bbb1d.

| Focused flag | Actual marker |
|---|---|
| `voice-playback-projection` | `VOICE_PLAYBACK_PROJECTION_OK: 33 checks` |
| `voice-session-reducer` | `VOICE_SESSION_REDUCER_OK: 10 traces and actual capture/output producers` |
| `voice-duplex-work` | `VOICE_DUPLEX_WORK_OK` |
| `concurrent-voice` | `CONCURRENT_VOICE_OK` |
| `voice-work-lifecycle` | `VOICE_WORK_LIFECYCLE_OK` |
| `voice-conversation` | `VOICE_CONVERSATION_OK` |
| `voice-turns` | `VOICE_TURNS_OK` |
| `voice-turn-routing` | `VOICE_TURN_ROUTING_OK` |
| `voice-delivery` | `VOICE_DELIVERY_OK` |
| `realtime` | `REALTIME_OK` |
| `duplex` | `DUPLEX_OK` |
| `voice-suspend` | `VOICE_SUSPEND_OK` |
| `voice-suspend-live` | `VOICE_SUSPEND_OK: paused PCM retained token and queue; resumed and drained; next clause restarted` |
| `tts-stream` | `TTS_TOKEN_STREAM_OK` |
| `playback-ledger` | `PLAYBACK_LEDGER_OK` |
| `voice-scheduling` | `VOICE_SCHEDULING_OK` |
| `tool-review` | `TOOL_REVIEW_OK` |
| `store-isolation` | `STORE_ISOLATION_OK: 21 files and 32 defaults unchanged` |
| `ui-strings` | `UI_STRINGS_OK` |
| `task-worker-attempt` | `TASK_WORKER_ATTEMPT_OK: 1352 cases` |

Additional latency instrumentation PASS is persistence/consumer instrumentation only, not measured product latency. Native projection recording PASS and reducer recorded-trace replay PASS. Actual voice latency gate exits1/VOICE_LATENCY_ABSENT because the original haiku16k.wav is missing; no regeneration/substitution or gate promotion. Pipeline/barge/rapid baseline comparison and core acceptance are not re-established here; inherited wake/computer and aggregate quality gates remain open.

Actual four-field observations: reducer121 events,39 each field,output18,no unavailable; lifecycle59 events,19 each field,output9,no unavailable; concurrent106 events,37 effects/turn/output and33 floor,output17,floor unavailable4; duplex61 events,27 effects/turn/output and24 floor,output20,floor unavailable3. All observed divergences0; unavailable is not equivalence.

## Explicit remaining scope

No post-resume positive receipt/epoch exists yet. inputDiscarded still uses historical heard as playing; a pre-pause acknowledgement arriving AFTER resume is not fenced by this paused-only repair. approvalResolved restoring speaking, actual pending Gate/card precedence, all-backend resume coverage and physical audible/display/latency evidence remain open. P3-06a parent remains in progress; P3-03a/b, OutputScheduler, P3-09/live UX05 and P3-06b ownership switch are not promoted. Phase6 recovery/retry/IM-16 and model quality gates are unchanged.

See independent-source-fixture-review.json, app92-93-independent-actual-review.* and retained raw logs/manifests. preparation-notes.md/SOURCE-HANDOFF.md/preparation-manifest.json are historical unexecuted handoff records, superseded for verdicts by this actual report.
