# Meeting reliability integration — 2026-10-01

Implementation remains in progress against the unchanged MR-01–MR-06 contracts.
Only generated audio and isolated stores/preferences were used. No private
meeting content or raw owner logs are included, and the owner app was not killed.

## Confirmed producer repairs

The existing meeting record now stores interruption, supported capture boundary,
missing capture frames and missing saved originals separately from processing
state. Recording repair persists unknown interruption before dispatch; a row left
only processing retains its normal Stop. Store merges preserve facts across stale
pipeline saves. Final transcript replacement refuses a damaged source while
allowing the complete source to improve. Notes and regeneration preserve facts.

The first rejected writer chunk releases abandoned arrays. A successful write
counter is no longer sufficient recovery authority when original samples were
trimmed. Writer finish closes the file before the final-pass reader sees it:
the same six-second fixture went from 94,208 to the full 96,000 visible frames.
A bounded progress snapshot can be read while native writing occupies the actor.
No lock spans native writing and no new audio queue/store was added.

Actual Quit now snapshots already-published saved-source loss, writer failure
and capture-loss counters before persisting its interrupted row. These external
facts may precede their queued MainActor warning callbacks. The original Quit
producer failed four assertions; the repaired actual Quit/fresh-reader flow passes.
This does not recover uncommitted sound after an arbitrary OS kill or establish
power-loss durability.

Capture loss, stopped delivery, missing system capture, storage risk, file
rejection and metadata rejection have distinct warning producers. Silence is
healthy delivery; saving lag alone is risk, not confirmed loss. Notifications
cannot replace the persistent in-app warning. Failed initial system capture
retains its gap even after successful retry.

Remembered normal/warning/critical pressure controls optional loads and rechecks
after waits. Required work and active native/voice ownership remain protected.
Recording start no longer speculatively loads the future notes model. The equal-
configuration normal-operation latency/resource comparison remains open; a real
cold notes load took 150.8 seconds in the first native diagnostic.

The native speech replay exposed independent live-context refinement loading the
same runtime during capture. Its optional producer had called required completion
without pressure admission. Context scheduling/provider resolution and local
completion now recheck after existing waits through the same native lane. The
accepted original-routing variant fails 23 of 46 new checks; the fixed signed
variant passes all 46 and the existing grounding cases, including required-call
admission and zero native weight opens in the fixture. See the
[refinement report](2026-10-01-live-refinement-pressure.md).

Model-file verification exposed an independent transient-memory producer:
Foundation reads retained autoreleased chunks until the surrounding pool drained.
The actual selected 1,561,318,368-byte model went from 1,570,473,448 to 7,586,224
bytes sampled physical-footprint peak with the identical checksum. The hashing
producer now drains each chunk. Twelve focused checksum/error/cancellation checks
and the signed actual downloader/artifact consumer `MODEL_LIBRARY_OK` pass.
This is verification memory, not attribution of the historical meeting's RSS peak.
See the [focused report](2026-10-01-model-verification-memory.md).

## Before/after evidence

| Regression | Before | After |
| --- | --- | --- |
| Actual recording repair → final pass → notes → done → fresh reader/regeneration, including damaged saved system track | Disabling interruption producer/track coverage gates: 10 failed assertions | Signed `MEETING_INTEGRITY_OK: 69 checks` |
| Quit before health poll or queued error/gap callbacks | Signed old producer: 4 failed assertions | Signed `MEETING_HEALTH_OK: 92 checks` |
| Writer rejected chunk retained capacity | 458,688 bytes retained, release assertion fails | 0 bytes, assertion passes |
| Strongly retained writer finish → fresh file reader | 96,000 accepted; 94,208 readable frames, assertion fails | Exact 96,000 frames readable, assertion passes |
| Separate app seed exit / fresh app verification | Reopening fixture rejected existing directory | Seed deliberately exits 73; fresh app passes 19 checks without reseeding |

Producer-disabled regression bundles differ only at the targeted guards; these
are controlled regression proofs, not a claim that the entire old binary was
reconstructed. Writer comparisons use the identical standalone production fixture.

## Signed integrated checks

The initial 23-case suite used signed staged bundle `install-15606`. Eighteen
passed immediately. Four initially failed checks were repaired and passed in
`install-18642`: health/integrity visual output, fixture-directory reopening and
store isolation's unattended approval. Dictation remains failed because the
staged process has no microphone permission; its 43 downstream assertions were
not exercised and are not counted as passing.

Passing relevant installed checks: resource policy, resources, metrics, settings,
resume, backlog, tap retry, audio retention, capture, residency, UI strings,
usage log, store isolation, duplex, contention, voice duplex work, dictation
hygiene and transcript finals. New health/integrity flags pass, as do the two
separate-process stages. The scripted tool-loop flag passes after the fixture
repair; this supplies no model quality/default promotion.

The final rerun reports `STORE_ISOLATION_OK: 21 files and 31 defaults unchanged`.
A separate Settings producer fixture exercises actual preference writers and a
fresh suite reader while the owner domain remains unchanged. Settings now use
existing harness preferences under self-test. The isolation test's malformed
computer mutation had depended on the owner's standing grant and waited for an
unattended approval when isolated defaults removed that grant. Its fixture now
uses the existing rejection seam and asserts no approval was requested; product
permission policy is unchanged. The metrics test's inherited asynchronous write
race was fixed by flushing before assertions; its blocked-writer before case
fails and after case passes.

Source build/linking and stable local signing succeeded. Two authorized unrelated
compile blockers were corrected earlier: a task-history fixture needed MainActor
isolation, and AgentView called missing repair methods. Removing the unavailable
button retains its visible history error and does not implement storage repair.
Existing foreign source/site changes were preserved.

The later signed bundle `install-25062` verifies nine focused flags: reconcile,
resource policy, resources, contention, voice duplex work, concurrent voice,
usage log, store isolation and duplex. The initial isolation run failed on an
owner audit change; its separate idle rerun passes 21 files/31 preferences
unchanged. Both verdicts remain in the raw evidence. Duplex's two shadow-reducer
diagnostics also occur in the earlier baseline; its functional verdict passes,
without proving reducer equivalence or broader Agent readiness.

## Warning visibility and scheduling

Actual stream rejection measured 15,232 dropped frames. The first rejection-to-
warning-publication delay was 100–122 ms under a controlled 100 ms MainActor load.
This is measured publication, not physical notification delivery. Actual file-
rejection and capture-gap views were rendered offscreen and reviewed: both
persistent warnings are visible. The recovered row shows “Partial recording”;
the detail shows “Recording interrupted — partial notes recovered” and the
supported saved-through time. Detail rendering captures its initial frame before
its asynchronous notes-file load; actual notes existence/content is verified
separately by the production notes/fresh-reader assertions.

The initial PNG failure was a diagnostic path-validator bug: Foundation normalized
an existing temporary base to `/tmp` but left a nonexistent descendant under
`/private/tmp`. Physical ancestor resolution fixes the producer while retaining
harness, temporary namespace, basename and output-containment restrictions.
The same requested views now render. All twelve Settings panes rendered; the
recording-retention explanation is visible. Signed bundle `install-21209` then
passed `MEETING_RETENTION_CHOICES_OK`: eight actual start/toggle/Quit/fresh-reader
configurations and 132 checks, including readable surviving samples and unknown/
kept protection. This checks writer admission for final/diarization choices;
those preferences are not per-meeting stored fields. A full-height actual Settings
form was reviewed, including the final-pass temporary-audio footer. Quit readback
proves surviving content, not a complete buffered-tail or power-loss guarantee.

## Measured resource evidence and remaining acceptance

See [resource attribution report](2026-10-01-resource-attribution.md) for actual
native load/inference/release results, CPU/wakeups, PCM cost and allocation bounds.
On M3/16 GiB, real guardian teardown took 219 ms, denied optional reload and kept
the actual ASR owner loaded. Total process footprint fell 90,391,728 bytes, including
other optional caches. This is a real native effect under injected admission
pressure, not OS exhaustion survival or a model-specific memory attribution.

The generated two-hour windowing fixture processes both tracks without sample
loss: peak logical audio 332,800 bytes, capacity 1,572,768 bytes. It proves a
windowing plateau through the production seam; it is accelerated synthetic input,
not a two-hour physical/native meeting. Native device/service allocations,
per-model fixed floor, the separate equal-build prewarm comparison,
accuracy/interactive latency and representative long physical voice/dictation
overlap remain open. Model-verification's transient reduction is measured
separately and does not supply those missing acceptance claims.

The final native former-prewarm attempt used that same verified bundle with live
understanding explicitly disabled in the disposable configuration. It captured
and read back all 2,908,098 frames on both tracks, but the strict stage guard then
detected changes in the owner's audit, conversation and metrics files. It exits
failed; the removed arm was not run. Abort evidence reports normal pressure,
generation zero, 8,301,473,792 immediately available bytes and no cancellation.
This is no accepted before/after pair. The guard remains unchanged.

The owner's recalled keep-audio intent still conflicts with the temporary incident
row. Current producer proof cannot retroactively identify its start-time setting.
No incident metadata or retained owner audio was rewritten or deleted.

Raw generated fixture logs and source/binary manifests are local under
`/private/tmp/meeting-reliability-validation/`; private incident evidence remains
in the build cache. MR task completion and the whole roadmap stay open until
these remaining acceptance contracts are satisfied.


## Resumed physical checks

See the [resumed acceptance report](2026-10-01-resumed-acceptance.md). The final
signed bundle, launched through LaunchServices, passes the real microphone
probe (including native/converted delivery after configuration recovery), real
system-tap probe with generated tone and the existing dictation fixture. The
original suite therefore has 23/23 entries with a passing signed result across
recorded runs, retaining the earlier grant-blocked failure; all 23 were not rerun
on the final bundle. Short positive hardware checks do not prove long physical
meeting coverage or warning visibility. The normal memory comparison remains
open after actual pressure/capacity rejections; the strict owner-store checks
pass in the completed former arm.
