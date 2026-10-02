# Dictation metric tail and lane-wait dispatch — original red, installed current green

Root's fixture-only app 14 ran the actual `DictationController` path with the
original production controller and protocol. The flag failed with **all seven**
errors retained. Five are the stale-tail/metric targets; two are additional
original-flow failures. Root applied the protocol requirement and the post-metrics
generation guard afterward. Installed app 17 passes the unchanged Dictation flag,
usage-log and store-isolation checks. The five targeted assertions now pass; the
two additional timing/capture failures did not recur, without a causal fix claim.
This report is not a dictation, Agent or Phase 2 completion claim.

## Exact installed evidence

`installed-original14/` archives the exact root `dictation.out`, `dictation.log`,
`summary.json`, `build14-source-manifest.json` and full `install.log`, with hashes
in `evidence-manifest.json`. Installed binary:
`0239756c2ecd6c88044e1708ec3f53febd219a4eb348e4d36b2ee51982de0b1e`.
The install log retains its actual warnings; build completion is not a test pass.
The summary reports dictation exit 1, 53.436 s. Its separate worker-attempt exit 1
is also preserved in the exact summary and is not counted as dictation evidence.

The complete retained `original-controller.swift.txt` matches the build-14
controller hash. The full original protocol in the linked lane-wait report matches
the build-14 protocol hash. Root's executed fixture adds a positive actor getter
returning 1.25 and an assertion against actual disk-loaded usage rows; its registry
source is archived as `installed-original14/executed-NextNotesApp.swift.txt`, with
SHA256 exactly matching the build-14 manifest. Root reconstructed it by restoring
only the trimmed EOF newline; the reporting worker checked its entire byte hash.
The older `prepared-fixture.swift.txt`
is a historical review proposal lacking those additions and is not represented as
the exact executed fixture. Current `NextNotesApp` has changed since build 14;
its current hash cannot substitute for the executed source hash.

## Actual sequence and first broken contracts

The fixture uses the actual controller, shared microphone capture, hold IDs,
injected insertion callback, outcome sink and a temporary `UsageLog`. It pauses
the old engine's executor while the real tail's metric read queues behind it.
After the old insertion receipt exists and the controller is finishing, it cancels
that hold and starts a fresh successor. The successor must reach actual listening
and capture before the barrier is released. It then observes disk-loaded old ASR
usage, the successor's state/outcomes and the successor's own final delivery.
There is no fake capture, owner-store seed or changed producer suspension point.

Two responsible producers are exposed:

1. `runTail` owns an old generation but, after the existing actor metric read,
   finishes/fails against the controller's current mutable fields without another
   generation check. The installed original fixture confirms the old tail clears
   successor capture/state and files an outcome for the successor too early. A
   guard after the locally captured usage rows and before the outcome switch is
   now applied by root after the external owner's one-hunk handoff; preserving the
   old usage is part of its contract. Its session condition matches the retained
   proposal, although its explanatory comment differs. Installed current proof
   now verifies successor capture, identities, outcomes and final delivery below.
2. `ParakeetEngine` owns a measured getter, but the original protocol declared no requirement.
   The tail reads through an optional `TranscriptionEngine` existential and selects
   the extension's zero. The actual installed fixture confirms the positive
   engine's 1.25 value is absent from its disk-loaded ASR usage. The complete copied
   [protocol driver](../latency/lane-wait-dispatch/README.md) separately demonstrated
   original concrete 1.25 / existential 0, and all four checks green with the exact
   getter requirement. Root applied that exact verified protocol change **after**
   the installed original red. App 17's unchanged actual consumer/disk assertion
   now passes, preserving the positive measurement in the old hold's own ASR row.

## Every original failure

| Actual original error | Scope | App 17 |
|---|---|---|
| `STALE_METRIC_TAIL: old inserted tail cleared successor capture/state` | Target: stale owner mutates successor | Same assertion green |
| `STALE_METRIC_TAIL: old tail prematurely filed successor outcome` | Target: incorrect outcome timing/ownership | Same assertion green |
| `LANE_WAIT_DISPATCH: actual dictation usage lost the engine's 1.25 second measurement` | Target: real existential read→disk usage | Same 1.25 disk assertion green |
| `STALE_METRIC_TAIL: original usage was lost or successor outcome was misattributed` | Target: combined assertion; original does not identify which half failed | Same combined assertion green |
| `metric-tail held identities, outcomes or final delivery were incorrect` | Target: combined assertion; original does not identify every failed subcondition | Same combined assertion green |
| `key-down to capture took 0.28294694423675537s with a 1.5 s start` | Additional original timing failure | 89.162 ms this run; no causal repair claim |
| `the silent hold's outcome was tap, expected empty` | Additional original capture/outcome failure | Same silent-hold assertion passed this run; no causal repair claim |

The nonfailing note is also retained: pre-roll fed 36,772 frames of approximately
40,000 during the 1.5 s engine start. Both original additional failures remain
retained; a single current pass does not establish their causes or durable repair.

## Installed app 17 after-fix proof

`installed-current17/` archives exact Dictation `.out`/`.log`, usage-log launcher
log, store-isolation `.out`/`.log`, the complete root summary, build-17 manifest,
full install log and exact executed registry. SHA256s and focused exit/duration
records are in `evidence-manifest.json`. Installed binary:
`0ee52308a47c409b115d0a0050719a5476c08a9132cf336fe053b185b83cb85c`.
The registry hash matches the frozen build manifest. A byte comparison confirms
the entire `runDictationSelfTest` section and both metric fixture helpers are
unchanged between the archived app-14 and app-17 registry sources, including all
seven original assertions. The current controller/protocol copies match build 17;
`verified-controller-diff.patch` confirms the only controller change is the
post-metrics session guard/comment. The protocol matches the exact getter proposal.

| Actual installed check | Exit / duration | Verdict |
|---|---|---|
| Dictation | 0 / 53.091 s | `DICTATION_OK: every hold came back to idle` |
| Usage log | 0 / 1.275 s | `USAGE_LOG_OK: 26 cases` |
| Store isolation | 0 / 33.993 s | `STORE_ISOLATION_OK: 21 files and 31 defaults unchanged` |

The usage-log `.out` was absent in the supplied directory; its exact launcher log
contains the actual final marker and is archived without manufacturing an output
file. The full summary also retains separate worker-attempt-original and
onboarding-trace failures; neither is represented as green or as Dictation proof.
Current pre-roll is 39,801 / approximately 40,000 frames and key-down-to-capture is
89.162 ms. These are this run's observations, not a demonstrated timing repair.

The fixture replaces transcription/insertion effects, so it does not prove real
Parakeet contention, physical target readback or broader user-visible latency.
It does verify the repaired producer contracts through the unchanged actual
controller, captured successor microphone, held identities, effect receipt,
outcomes and disk-loaded usage. No source edit, compiler, build or native run was
performed by this reporting worker. Phase 2 latency targets remain open.
