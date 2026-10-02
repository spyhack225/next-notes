# Task harness history-read privacy — original46 / fixed47

The denied self-test reader decoded task JSON and exposed objective, result and
arguments through the real fresh Manager. Its write guard did not prevent reads.
`AgentTaskStore.load` now returns empty history before compatibility reads or SQL
opens whenever harness persistence is denied. The product/admitted reader after
that branch is byte-identical; explicitly injected temporary JSON AND SQL still
import, save/export and restore the same real control row.

## Original failure and same-input verification

- Installed original46: exit1, **10 failed assertions across40 checks**. The actual
  legacy and real tagged-export canaries reached the actual fresh Manager. Corrupt
  and directory inputs were decoded instead of being ignored. No default/shared
  task manager/store or owner task file was used in this reproduction.
- Installed fixed47: exit0, **the same40 checks PASS**, plus worker531 (prior491
  unchanged plus40) and all14 related flags. Exact logs/markers are archived.
- Real admitted temporary import, same SQLite authority, primary save/export and
  fresh Manager preserve the control row. Denied bytes/paths and save refusal stay
  unchanged. Non-file mirror injection constructs only the actual URL-bound store;
  no opening method is invoked on that mirror.
- Both conflicting flag orders refuse before app startup. An out-of-temp output
  candidate under this report refuses without creating the candidate file.

The synchronous dedicated `--selftest-task-harness-read` route executes before
SwiftUI `App.main`, AppDelegate or any owner-backed scene can initialize. Raw
presence of that flag routes even conflicting orders to fail-closed refusal.
Every other launch calls the original SwiftUI App entry. This is the isolation seam
needed to run the **unfixed** producer safely, not a substitute privacy repair.
The original and fixed builds use byte-identical integrated fixture/entry. No
ordinary original app was launched. Direct launcher mode was used.

For default store construction, nil injection is rejected before owner storageURL
or lazy mirror resolution; the fixed early return is before all compatibility
reads/SQL probes. `fixed-default-source-order.json` binds this reviewed source proof.
Existing store guards prove unchanged bytes, **not** absence of reads. The actual
canary producer/consumer and default branch order provide the read-isolation proof.

## Related gates and provenance

`fixed47-checks.json` records16 actual flags: dedicated40, worker531, durability37,
recovery56, authority58, restoration82, history-repair58, receipt-runtime5, review,
production tool loop, routine authority, schedule, usage26, store isolation21files /
32defaults unchanged, grader and voice scheduling. All exit0 with actual final OK.
The first normal worker invocation omitted the output argument and had no retained
final marker; it was NOT counted green. The corrected launcher retained the final
native logs for every admitted check. No extra tests were repeated after this pass.

Full Sources/Resources/Package/Makefile manifests, unchanged source/binary records,
original/fixed binaries' SHA256, raw compiler output and original/fixed sources are
archived here. These pin the tested dirty workspace, not a clean-checkout build of
all separately owned UI/model changes. Build44/45 never ran; build46/47 are the
actual privacy binaries. The separately owned ACP fixture/wrapper is packaged but
its protocol tests did not run in this privacy proof.

## Limits

This closes only the denied harness task-history reader contract. It adds no store,
query, await, timer, schema, permission or model pass. No owner task payload was
read/seeded for original reproduction and no owner migration was run. General
shareable full-pane isolation remains withheld: role/library metadata, defaults,
scene storage and prewarm need their own existing-owner contract. Normal local
model diagnostics retain their intentional model access.

Dedicated entry parser refuses conflicting flags and unsafe outputs; it does not
claim complete positional/value syntax validation or an App watchdog (the standalone
fixture is synchronous). Physical UI/native interaction is unverified. Liveness,
complete receipt coverage, recovery/retry, parent Phase6 and IM-16 hosting remain
open. Historical app13 quickFAILED3/10 remains the latest model verdict; no quality
bar, default or broader readiness is promoted by these functional checks.
