# Speculative voice usage correlation: original failure

The installed five-turn run failed the unchanged `agent.voice` pass-to-turn join. This audit read only the synthetic `NextNotesSelfTest-44333/usage.jsonl`; no owner history was opened. The parent retained the original output at `../installed-five-turn-baseline-red.log`.

`isolated-usage-metadata.json` preserves feature/pass/provider/locality and application-generated IDs, the synthetic source SHA-256, counts, and exact measured joins. Of 40 voice rows, 24 are model passes (17 route, 7 answer); 22 lack both turn and conversation IDs. Each of the five measured turn IDs has exactly one summary and zero model-pass rows. The remaining two model-pass rows belong to the extra committed response during measured run 5.

## Confirmed producer

`VoiceConversationCoordinator.prepareResponseIfUseful` calls the real frontend speculation producer before installing usage correlation. `LocalVoiceFrontend.speculate` starts an unstructured producer task inheriting that absent task-local. The native route and answer recorders copy IDs at construction; they are immutable thereafter. At final commit, `respond` creates a different, late UUID and installs it around `LocalVoiceFrontend.stream`. An exact speculation hit adopts the already-running or completed producer and its buffer without constructing another native recorder. Consequently, the commit-side task-local cannot tag that original producer. `UsageLog.flush` and the strict consumer join correctly expose this failure.

The three `.swift.txt` files are untouched source snapshots with hashes in `source-manifest.json`. `proposed-producer-fix.patch` was the review artifact prepared before any app source edits: reserve the usage UUID for the existing prospective capture turn before speculation, retain it through revision and commit, and require committed correlation to match when adopting a speculative slot. The proposal creates no extra usage file, pass, inference wait, or recorder rewrite.

## Verification limits

This is original-failure evidence and a source proposal. No source was edited, no compiler was started, and no new model run occurred during the audit. The real baseline also failed on run 5's extra commit/missing EOU stages and a main-actor stall; correcting correlation does not close those findings or prove the phase latency requirements. A final installed rerun must retain the existing join assertion.

## Prepared change after parent approval

After the parent released the build slot, the approved source hunks and recorder regressions were applied. `prepared-source-manifest.json` hashes the prepared sources. The frontend also checks correlation before its same-key/same-revision early return. The existing speculation flag now covers five correlation cases using the actual speculative slot/task-local inheritance and real pass recorder over scripted generation. No Swift compiler or model evaluation was run by this worker; source preparation is not verification. Root must build and run the flag, then repeat the original installed five-turn native flow.

## Installed result supplied by parent

The parent built and installed the prepared source (46.48 s build). The installed speculation flag passed; its launch log prints `VOICE_SPECULATION_USAGE_OK: 5 cases, 9 actual recorder rows; scripted generation`. The original native file-fed fixture rerun also passed `VOICE_LATENCY_OK`: one warmup, then five measured turns, each with one committed turn, local EOU, an actual first-audio acknowledgement, and a summary joined to real frontend pass rows. `isolated-usage-current-metadata.json` records the exact five joins from synthetic pid 48453. No owner usage history was read.

Measured speech-end-to-first-audio median was 2.894 s and p90 3.729 s; worst measured main-actor stall was 35 ms. This proves the original missing-usage-join failure resolved on the real coordinator/native frontend consumer path. It is a baseline: no 0.9 s budget was supplied and it is not a phase exit. The original cold run's extra duplicate commit was not independently fixed or proved resolved by a warm rerun. The related voice-frontend flag failed and remains under parent investigation. File-fed audio is not physical microphone/room-loop evidence.

The reproducible `../run-usage-correlation-driver.py` copies the archived/current producer methods and unchanged strict join validator, actual recorder/log, and current speculative recorder cases. Both modes were prepared without a compiler; their eventual runtime results remain pending. Native inference is fatal in that driver, and fixture capture/context/summary projection limitations are recorded in each source manifest.

## Root compiled producer regression

Root ran both prepared modes serially. Original compiles successfully and exits 1: the real preparation producer writes one pass without a turn ID and the unchanged native-run usage validator reports no pass sharing the committed turn ID. The old frontend also fails the changed-turn speculative recorder case. Current compiles successfully and exits 0 with `USAGE_CORRELATION_OK`: the before-commit pass has its reserved ID, the strict join finds it, and all five existing recorder correlation cases pass. Raw logs/manifests are in `../usage-correlation-driver-original` and `../usage-correlation-driver-current`.

Related installed CORE passes 21/22; the sole failure is the recorded wake 17/24 hit, 3/32 false-accept baseline. Dictionary/spoken-form tests pass 30 tests in two suites. The separate voice-frontend rerun with retained diagnostics passes all 15 route cases and actual generation/prefill overlap. Its initial unexplained failure remains recorded rather than being asserted fixed.
