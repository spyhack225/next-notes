# Start-lane wait protocol dispatch — copied contract verified, production unchanged

This is a metric prerequisite fixture, not a dictation latency or native-model
result. Root ran the copied original/current driver serially. Both compiled; the
original returned zero through the actual existential expression and failed one
assertion; the proposed protocol requirement returned 1.25 and passed all four.
Root then verified the original installed Dictation consumer also loses 1.25 in
disk-loaded ASR usage and applied the exact protocol requirement. Installed app 17
now passes the unchanged actual consumer/disk assertion, usage-log and store
isolation checks. This worker edited no
`Sources` file and ran no compiler/build/model.
Root holds the external owner's authorization for the minimal protocol requirement.

`original-TranscriptionEngine.swift.txt` is the complete current production file,
including `AudioChunk`, `TranscriptionChunk`, the full actor protocol/default
extension and `TranscriptionError`. The proposed full copy adds only the getter
requirement `var startLaneWait: TimeInterval { get }` plus its comment inside the
protocol. The existing default `{ 0 }` and all other declarations remain intact.
`prepared-source-manifest.json` hashes both snapshots, the fixture/driver and the
actual producer/consumer source files. No imports, types or protocol methods are
replaced by stubs in the compiled source copy.

## Read-only production provenance

- `ParakeetEngine.swift:43,47` stores its measured wait and exposes the actor-owned
  getter. Lines 100–102 measure elapsed time around the actual
  `ComputeScheduler.shared.acquire(.realtimeASR)`, before the cancellation
  generation check. No other assignment clears that value in the inspected file.
- `DictationController.swift:624` holds `(any TranscriptionEngine)?`. `runTail`
  retains that exact engine at line 1698 before clearing the controller's property
  at 1706. After finishing the engine and injection, line 1958 reads
  `let laneWait = await engine?.startLaneWait ?? 0`; the value is passed to
  `UsageRecord.dictationRows` and written to `stages["laneWait"]` by
  `UsageRecord+Dictation.swift:84`.
- `TranscriptionEngine.swift:32–44` currently has no such requirement. Its getter
  exists only in the extension at line 52. The suspected first broken contract is
  therefore the protocol dispatch seam: reading through the actual existential
  can select the extension's zero instead of the actor's measured getter. This
  is now demonstrated by the original copied-driver run: actor 1.25, existential 0.

## Exact bounded fixture and limits

`LaneWaitDriver.swift` supplies two actors satisfying the entire real protocol.
The measured actor sets its value to **1.25** in its scripted `start()` and retains
it through `finish()`, mirroring the measured actor getter's shape. The other actor
implements no getter and must retain the real extension default. Four assertions
exercise concrete positive dispatch, the **exact optional-existential consumer
expression** after finish, default-engine zero and absent-engine zero.

This tests language/protocol dispatch with the real source seam. It does not run
Parakeet, obtain a real compute-lane wait, call the complete dictation tail, write a
usage row or prove the installed user flow. Existing usage-log tests can validate
row persistence, but accepting a directly supplied positive number there does not
exercise this existential read. Root must separately verify source application,
installed integration and relevant owner regressions.

Prepared directories contain the exact protocol/fixture Swift inputs, raw
compiler/run logs and manifests: `prepared-original/` and `prepared-current/`.
The root launch logs are archived exactly as `original-red.log` and
`current-green.log`. Observed results:

| Actual copied input | Compile / run exit | Concrete | Optional existential | Default / absent |
|---|---|---|---|---|
| Complete original protocol | 0 / 1 | 1.25 | **0, wrong** | 0 / 0 |
| Original plus getter requirement | 0 / 0 | 1.25 | **1.25** | 0 / 0 |

Read-only byte comparison verified the historical proposal is the identical full
original source plus **only** the getter requirement/comment; both prepared inputs
match their retained snapshots. That read-only check occurred before application;
the live protocol now matches the proposed requirement exactly. The copied producer
contract and installed actual consumer result are verified within the fixture scope.

Root's fixture-only app 14 ran the real Dictation flow with a parked engine
reporting 1.25 and a disk-usage assertion, while retaining the original protocol
and controller. It failed that actual metric assertion plus stale-tail and
additional timing/capture checks: **all seven errors remain recorded** in the
[installed original report](../../dictation-metric-tail/2026-10-01-installed-original-red.md).
Root subsequently applied the exact requirement; app 17's unchanged installed
Dictation assertion verifies the 1.25 getter reaches the disk-loaded old ASR row.
The same run passes all five target tail/identity/dispatch assertions, plus the
existing usage-log (26 cases) and store-isolation (21 files / 31 defaults) checks.
Exact logs, full frozen registry/source manifests and binary
`0ee52308a47c409b115d0a0050719a5476c08a9132cf336fe053b185b83cb85c`
are retained in the linked report's `installed-current17/`. All original seven
errors remain recorded: the two additional timing/capture observations passed
this run without a causal repair claim. This supplies no real Parakeet contention
or Phase 2 latency exit evidence.

Root's executed serial commands, in this order (do not rerun without its slot grant):

```sh
python3 Tests/Reports/agent-overhaul-closure/latency/lane-wait-dispatch/run-driver.py --mode original --run
python3 Tests/Reports/agent-overhaul-closure/latency/lane-wait-dispatch/run-driver.py --mode current --run
```

Each command invokes `swiftc -swift-version 6 -parse-as-library` on the full copied
protocol and fixture, using a fresh temporary module cache/binary. It writes its
exact compiler command, hashes and exit codes to `input-manifest.json`, plus raw
`compile.log` / `run.log` in that mode's prepared directory. An original regression
exit 1 is expected; a compile failure is recorded separately and never counted as
red behavior. No owner store/model or app build is involved. The runner compiles
only when explicitly passed `--run`; without it, it only prepares those inputs.
