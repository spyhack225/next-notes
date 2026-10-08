# Corrected actual-source legacy parity

The root-executed corrected probes pass exact legacy comparisons and the production guard for both the source-selection safety implementation and the optional comprehensive prompt variant. Baseline fails only the new warning-paragraph assertion; fixed and comprehensive pass the unchanged original longform checks, new separator assertion and 33 source-evidence checks.

| Variant | Compile | Run | Exact legacy comparison | Production guard |
| --- | --- | --- | --- | --- |
| Original HEAD + common new separator assertion | PASS | FAIL: separator only | Reference | Reference |
| Guarded source-index option | PASS | PASS | PASS | PASS |
| Guarded option + comprehensive selection prompt | PASS | PASS | PASS | PASS |

The same original stubborn + real brief case actually runs 12 map chunks, two collapses and one dropped part in all three. The comparator checks exact generic prompts, tokenizer inputs, model output budgets, typed results and markdown, permitting only the generator's explicit two added newlines before the final warning. The production simulation explicitly requests the option while SelfTest is false, and still executes the legacy path with no grammar calls.

Initial executions remain intact in this directory: both baseline/fixed compiled, both failed eight longform assertions, and comparison/guard failed. Six original collapse/drop assertions failed because the shared brief stub omitted actual labels and no longer overflowed the window; two added assertions also relied on an impossible no-context drop assumption. [Boundary repair](BOUNDARY-REPAIR.md) explains why exact real pure source boundaries replace that shim. No transcript/window/drop assertion was made easier. The new separator assertion now augments the original unchanged stubborn+realbrief case.

Corrected root outputs are in [corrected](corrected/summary.json), including unchanged original failure logs, successful fixed/comprehensive logs, comparisons and guard traces. These are actual generator/source tests with stub provider/meeting/telemetry boundaries and native Apple tokenizer absent. They prove legacy parity and the specific warning-assembly repair; they do not prove native whole-app acceptance or semantic notes quality. Third-release native checks and exact private owner replay remain pending.
