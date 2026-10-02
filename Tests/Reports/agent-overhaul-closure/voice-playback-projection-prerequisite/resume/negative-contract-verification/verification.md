# P3-06a-5: stop historical playback from acknowledging a resume

Original installed app100 reaches the same two native Apple/capture scenarios and fails exactly four target assertions. Fixed app101 passes all 48 checks: the unchanged original 28 plus 20 common repeat-pause/resume controls. Both versions retain the same real native onset, captured backchannel classification, physical resume, token/generation and cleanup controls. The original four failures are R01 once, R02 twice and R03 once; no input, control or repeat-resume case fails.

## Confirmed producer failure and correction

The reducer's inputDiscarded transition promoted historical heard evidence into playing immediately. The actual speech-owner snapshot independently promoted historical clauseRendered/voiceShadowHeard into playing. A genuinely retained pre-pause native onset, forwarded after actual resume, could then manufacture speaking.

The same reducer now enters awaitingResume while retaining heard history and emitting the identical physical resume command. A firstAudio event cannot promote paused or awaiting output. The existing speech owner records accepted pause metadata in its current output and forwards resumePending through the existing lifecycle snapshot; the existing audio projection checks that metadata before historic played evidence. Existing prepare, stop and test restore reset it. Only those three producer files differ across the 1,046-entry original/fixed manifests. The common test, observers and metrics guard diagnostic are byte-identical.

Physical audio controls, microphone/model/effect owners and live Island ownership are unchanged. No additional store, queue, audio channel, timer, model pass, foreground await or physical playback gate was added.

## Verification

Original100: VOICE_PLAYBACK_RESUME_RECEIPT_FAILED: 4 assertions. Fixed101: VOICE_PLAYBACK_RESUME_RECEIPT_OK: 48 checks. Both preserve existing reducer ten traces and TASK_WORKER_ATTEMPT_OK: 1352 cases. Fixed101 passes 23 focused flags, including the original native suspend/pause/resume/drain/restart, duplex/conversation/lifecycle/delivery, projection33, acoustic replay, PCM reconfiguration, permissions and owner isolation21files32defaults. Both native traces retain zero divergences; actual reducer121 events retains zero compared mismatches. Full Source and signed bundle invariance is checked for every run. Exact source delta, native logs, build manifests and bundle maps are adjacent.

The added common repeat fixture initially did not compile: deliveryQueued requires its count: label. That failed compiler attempt is archived; the one syntax-only correction was frozen before both original and fixed native runs. No native result is attributed to that invalid compiler attempt.

The common metrics diagnostic emits only booleans/readability derived from already-captured guard signatures. It adds no owner read and changes no assertion. Both app100/101 worker runs pass1352 and report no size, mtime or digest change for either guard scope. This does not identify or resolve the retained app99 first-run metrics mutation anomaly.

Final101 quick is FAILED3/10 on Gemma 4 E4B,84.8s, unchanged9/10 bar. Tool awareness passes. Exact core acceptance exits2 at21/22; the sole failure is unchanged wake17/24hits,3/32false. Sources, full bundle and launcher/acceptance scripts remain invariant. The actual changed quick verdicts (email timeout→pass, browser pass→ungrounded) and bounded source attribution are retained in quick-attribution-notes.md and quick99-101-comparison.json; runtime causes are not claimed resolved. The original latency WAV and live gates remain open.

## Deliberate limit

This is the conservative negative prerequisite, not a positive resumed-playback feature. The current shadow output can remain awaitingResume throughout physically resumed audio, including later clauses. It must not drive live presentation until an exact current-owner qualified post-resume receipt is implemented and verified. The passing synchronous checks prove refusal of stale history, not new frames played, physical audibility, health, liveness, latency, other backend receipt authority, live UI ownership or a completed parent phase.
