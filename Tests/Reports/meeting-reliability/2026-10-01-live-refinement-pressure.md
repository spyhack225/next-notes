# MR-03: optional live-refinement pressure admission

## Confirmed producer

The native generated recording exposed two real `meeting.reconcile` passes that
loaded the shared local language model during capture. This is independent of
recording-start notes prewarm. Live understanding's automatic local setting makes
these legitimate normal-condition passes; streaming ASR does not remove their cost.

The optional producer checked the stored setting and cadence, then resolved the
Agent provider and called its ordinary required completion. Pressure was not
checked at scheduling, after provider resolution, or after native ownership and
compute waits. Consequently optional refinement could reload a model after the
guardian had released optional allocations.

## Responsible seams changed

`MeetingContextStore` now checks admission before scheduling, running and applying
an optional refinement. `ModelCompleter` rechecks after its existing awaits. The
resolved local provider uses `NotesModelRuntime.completeForOptionalUse`, through
the same background/native ownership lane, existing optional load/prefill checks
and token checkpoints. Pressure arriving during a wait cannot promote the request
to required work. Denied completion records cancellation rather than success.

Ordinary required completion retains `optional: false`; interactive streams and
voice ownership are unchanged. No new queue, live store, model choice or provider
fallback was introduced. The explicit store dependency defaults to the existing
shared store and permits isolated actual-store fixtures.

## Signed before/after verification

The same generated regression fixtures run through actual store scheduling,
`ModelCompleter`, usage recording, the local provider and private runtime lanes.
Native model loading is replaced only at its existing optional test seam. Tests
include warning at entry, changing pressure during setting/provider/completion
awaits, normal/user-off behavior, actual persisted context, held ASR scheduling,
held native ownership, pressure after loading, cancelled usage and required-call
admission. The fixture asserts zero additional native weight opens.

| Same installed flag | Original producer routing/guards | Repaired producer |
| --- | --- | --- |
| `--selftest-meeting-reconcile-llm` | `install-24629`: exit 1; 23/46 new checks fail | `install-25062`: exit 0; 46/46 new checks pass |
| Existing grounding tests | Preserved in the same flag | Preserved and pass |
| Required completion under critical pressure | Exact missing-file failure after a new load attempt | Same contract |

The before variant disables only the new context admission calls and routes local
optional completion to the original required runtime call. Source files were
restored byte-for-byte immediately after building; the restoration manifest and
generated logs remain in the local validation directory.

Two fixture defects were corrected before this accepted comparison: the isolated
store must save its meeting before context ingestion, and each missing-model test
request must reset its selection so the production fallback cannot load installed
weights on a later request. An earlier draft did load a built-in model through
that fallback. Its results are not the accepted comparison; the final fixtures
preserve production fallback behavior and assert zero native opens.

Signed related checks pass: resource policy, resource/windowing/writer coverage,
contention, voice duplex work, concurrent voice, usage logging and duplex.
Duplex still emits the same two shadow-reducer divergence diagnostics as the
earlier baseline while its functional verdict passes; this is no new reducer
equivalence or Agent-readiness claim.

Store isolation initially failed when the owner's audit changed during the run.
The audit writer retains its self-test no-disk-write guard. A separate idle rerun
passes: 21 files and 31 preferences unchanged. The initial failed result is kept.
No owner app was terminated or preference changed to obtain that result.

Raw generated evidence is under
`/private/tmp/meeting-reliability-validation/refinement-final/`, with the before
logs and source-restoration manifest beside it. Physical exhaustion survival and
the separate equal-configuration native efficiency comparison remain open.
