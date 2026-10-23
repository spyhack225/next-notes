# Silero VAD + Smart Turn v3.2: implementation and qualification

23 October 2026. **Candidate implemented and native-tested; rollout held.** The
pinned upstream model and CoreML export both fail the retained synthesized
mid-sentence pauses. No installed app or saved engine choice was changed by this
work. The TTS peer's separate owner-requested Phonon preference is preserved.

## What is implemented

- Native, pinned CoreML Smart Turn v3.2 and recurrent Silero v6 wrappers. Every
  constituent compiled file has a SHA-256 and length pin; downloads stage and
  verify before publication. Ordinary downloads retain the existing 4 GiB reserve.
  The application adds no Python or ONNX runtime dependency.
- The existing cleaned 16 kHz capture stream feeds both models and Apple/Parakeet.
  Silero uses exact 512-sample frames and 64 samples of recurrent context. Gaps
  reset recurrence; ordinary echo, playback-generation and duck ownership remain.
- Smart Turn keeps eight seconds of current-turn PCM, one native prediction and
  one replaceable pending request. Speech revisions revoke older results. Model
  timeout revokes authority, and cancellation still joins native work.
- One decoder metadata box tracks session/epoch/native generation, conservative
  completed 80 ms shifts, produced publications and ordered applied snapshots.
  Apple reports this result's recognized audio end, never a maximum discarded
  volatile range. A known pending local publication cannot bypass the fence via
  a degraded fallback.
- Commit checks the selected snapshot and installs its successor reset atomically.
  The existing ring recovers **all** post-cut PCM, including chunks already
  consumed by the retiring decoder. The existing six-second ASR backlog admits
  that replay once. Replay cannot own live partials or EOU until actual native
  catch-up. No second microphone, ASR queue, store or usage ledger is introduced.
- Existing irreversible-effect and playback authorities remain authoritative.
  Speculative work does not become a committed action through a semantic result.
- A durable native endpoint collector, independent model probe, upstream export
  differential and offline scorer retain partial, failed and missing coverage.

Admission is `--voice-smart-turn`, or an explicitly owned self-test model root.
The candidate is not promoted to an ordinary default or user settings flow while
qualification is red. Artifact roots require `.nextnotes-turn-fixture`; native
application replays are cache-only for owner ASR assets.

## Actual verification

| Check | Observed result | Boundary |
|---|---|---|
| Optimized full application build | PASS, 1060.07 s | Final frozen source; no installation |
| Final application policy controls | `TURN_POLICY_OK` | Authored metadata, token, reset/replay and pending-publication controls |
| Offline scorer controls | 21 checks pass | Authored scoring controls; no native timing claim |
| CoreML completed question | Median 2.50 ms, p95 4.20 ms, n=30 | Repeated prediction of one fixed snapshot, not independent accuracy |
| Silero native onset | About 93–126 ms across seven paced inputs | First two >=0.6 classifications; not physical duck or zero-preroll cold onset |
| Smart Turn protected snapshots | FAIL, all six pause variants | Same unfinished split-synthesized prefix; 30 repeated predictions each |
| Upstream differential | All 13 classification decisions agree; max probability difference 0.00150 | Same PCM, upstream zero-prefix/normalization/Whisper features; no ONNX latency claim |
| Production endpoint replay | 21 trials saved, child exit 0 and joined | Real capture/Apple/Parakeet/Silero/Smart Turn/tick/commit, no replies/tools |
| Owner preservation | PASS, 25 store/settings files and 143 meeting files unchanged | Size, nanosecond mtime and streaming SHA-256 across native runs |

The first isolated test-bundle launch omitted the standard framework rpath and
failed in dyld. Adding `@executable_path/../Frameworks` and re-signing the dedicated
bundle repaired packaging. The original failure is retained; no source change
or installed-bundle modification was needed. The collector now inspects the
bundled framework and Mach-O rpath before spawning a child; an actual malformed
placement is rejected without execution. [Packaging controls](bundle-preflight-controls.json).

## Latency and mid-sentence pauses

Each row has three production replays of an independently trimmed synthetic WAV.
Latency is speech-end ground truth to the real `commit.emitted` consumer event.
Only single-commit trials receive the descriptive latency below. These small
samples do not meet the required latency acceptance cohort.

| Input | Premature/duplicate trials | Single-commit latency | Exact final-tail check |
|---|---|---|---|
| Completed question | 0 / 3 | 304–362 ms; median 334 ms | FAIL 3 / 3, native ASR wording differs |
| 200 ms pause | 0 / 3 | 284–386 ms; median 375 ms | Pass 3 / 3 |
| 400 ms pause | 3 / 3 | Invalid as a single-turn comparison | Pass 3 / 3 |
| 600 ms pause | 3 / 3 | Invalid as a single-turn comparison | FAIL 3 / 3 |
| 900 ms pause | 3 / 3 | Invalid as a single-turn comparison | Pass 3 / 3 |
| 1200 ms pause | 3 / 3 | Invalid as a single-turn comparison | Pass 3 / 3 |
| 1500 ms pause | 3 / 3 | Invalid as a single-turn comparison | FAIL 3 / 3 |

All 15 replays with 400–1500 ms pauses committed during the protected interval and
then committed again. Retaining the sentence ending in some cases does not repair
the early turn. Some ASR results also omit or misrecognize final words; attribution
between native recognition and early segmentation requires a paired follow-up.
Per-trial pacing p95 errors stayed below 5.04 ms.

The unfinished phrase “I want to book a table for” receives about 0.984 completion
probability; completed table requests receive about 0.974–0.978. A single threshold
cannot reject those prefixes while accepting those finished inputs. No threshold
overfit or text-shape workaround was applied. Prefix and suffix were synthesized
separately, which changes intonation: retain these failures and add continuous
human-speech controls before making a general model-quality claim.

The full scorer exits 1, as expected: premature/duplicate turns, nine unverified
final tails, missing audible stages, insufficient samples and absent required
cases/phases remain red. Raw `warm` labels are repetition ordinals; residency was
not independently sampled, so this run does not qualify warm/cold behavior.
After retaining this original trace, the collector metadata was corrected to label
every fresh session `cold_capture`; no capture, model or endpoint policy changed.

## Evidence and reproduction

- [Main native source pins](final-source-pins.json), [verified source commit](source-commit-verification.json),
  [main build receipt](final-app-build.json),
  [compressed build log](app-build-final.log.gz), [policy log](final-policy.log).
- [Native endpoint trace](native-endpoints.json), [summary](native-endpoints-summary.json),
  [full score](native-endpoints-score.json), [joined-child receipt](native-endpoints.json.receipt.json).
- [Native model calls](native-models.json), [summary](native-models-summary.json),
  [original source pins](model-source-pins.json), [receipt](native-models-receipt.json).
- [Upstream results](reference-model.json), [differential](export-differential-summary.json),
  [artifact pin](onnx-reference-artifact.json), [resumed receipt](reference-resumed-receipt.json).
- [Original synthetic fixtures](fixtures/fixtures.json), including all failing WAVs.
- [Preservation verdict](preservation-verdict.json) and before/after hashes; paths
  for meeting files are hashed to avoid exposing owner titles.

`Tools/voice_turn_benchmark.py collect --root <owned-root> --binary <dedicated-VoiceTurn-executable>
--output <trace.json> --repetitions 3` uses the actual application collector.
The command and exact executable hash are retained in the receipt. Score with
`python3 roadmap/in-progress/VOICE-TURN-DETECTION/benchmark/score.py --trace <trace.json>
--out <score.json>`. Standalone graph and upstream diagnostic entry points are
`Tools/VoiceTurnNativeProbe.swift` and `Tools/voice_turn_onnx_reference.py`.

## Alignment, resource lifecycle and remaining acceptance

ASR peer reviewed snapshot/finality, conservative frontier, generation ordering and
lock order. Its pending-publication, superseded-reset, complete successor replay
and freshness findings were repaired. The authored helpers do not replace a held
native drain regression or worst-case capture-lock timing under paging.
Dictation-only Phonon/Voz choices do not replace voice Apple/Parakeet. TTS metrics
remain separately owned; this task did not load TTS or change physical devices.

The first independent diagnostic refused before model load at 215,412,736 writable
bytes. Its refusal is retained. After owner cleanup, writable space recovered
above 5 GiB; the resumed diagnostic exited 0, joined in about 7.8 s and sampled
371 MB peak RSS. This is a diagnostic memory observation, not a product ceiling.
All native children joined before cleanup. Only this task's obsolete binaries,
joined reference graph and its new component compiler bundles were retired;
owner/peer caches, settings, models, recordings, history and installed app remain.
The useful dedicated current candidate and synthetic fixtures are retained.

Remaining gates: continuous human/multilingual/noisy speech, all shipping provider
pairs, original/fixed paired current-app baseline, zero-preroll cold onset,
physical routes/echo/duck, concurrent ASR+voice, pressure/reopen/cancellation soak,
complete speech-end→audible response and held native replay/lock-wait regressions.
The 32-recipe suite includes the new 600 ms regression without dropping the
original 700 ms recipe. Seven materialized synthetic cases do not complete it.
Parent roadmap acceptance and default rollout remain held.


## Collector reporting and packaging follow-up

The metadata-only follow-up also passed a full optimized app build (763.43 s) and
`TURN_POLICY_OK`. Two actual fresh capture runs both now report `cold_capture`;
the child exits 0 and joins. These are functional regression controls, not an
additional latency/quality acceptance cohort. The original 21-trial trace, labels,
source pins and failing verdict remain unchanged. The known malformed bundle is
rejected before execution; the current signed candidate passes preflight and
launches without the prior missing-framework error.

[Source delta pins](collector-metadata-source-pins.json),
[build receipt](collector-metadata-build.json),
[compressed log](collector-metadata-build.log.gz),
[functional verdict](collector-metadata-verdict.json),
[raw controls](collector-metadata-controls.json),
[child receipt](collector-metadata-controls.json.receipt.json),
[packaging negative control](bundle-preflight-controls.json).
The repeated [owner preservation check](preservation-metadata-verdict.json) also
passes: the same 25 stores/settings and 143 meeting files are unchanged. The
joined control fixture root was retired; the useful corrected candidate remains.
