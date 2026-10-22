# UX-04: saved Activity Timeline proposal review

Status: two disjoint static UI reviews, no canonical Source application, compiler,
native interaction or mounting lease. Runtime root owns serial integration.

Packet: `Tests/Reports/agent-overhaul-closure/p6-08-activity-ui-frontier/saved-timeline-preparation`.
Manifest `719ef22eb15f09511e3b70713f3a060ad6d3b945427f2b270c5e4e2ba70607cb`
matches all19 listed files. COMMON patch
`171a6754f9531532893d51f98b55b7d3222772d3ee5759bcf2c717590e6036eb`;
producer patch
`33fbd86e0497432d00c1af64078146f2e855b22c7c38aaacd8b1b76b9c94dd06`.
Current ActivityView still matches the baseline
`3b6785726fd7d8c0db5b19aa4624228c21bcaa9ae46bb3f0a17973afbbbd9477`.
COMMON/fixed ActivityView is
`867fc0823a3c331cacb5d528e5f91ef3448174497b03ef635e4666b8a47d0567`.

## Preserved contracts

The foreign “Your companion’s” header, accent “activity,” and subtitle are preserved
exactly. AgentPaneScroll/AgentSplit, DS treatments, filters, live heartbeat, grants,
rail/navigation/actions and existing audit row accessibility remain. HistoryRow is
extracted as a shared child rather than replaced. Saved rows are actionless immutable
values: they add no approval, receipt, health, effect, retry or delivery authority.

JobReport factors its existing marked readonly ledger probe. The appearance task reads
on a utility lane and passes one immutable snapshot to drawing, not a second product
ledger. Row projection does not read files, query SQL or initialize receipts. The
existing whole Activity pane still constructs shared owner-backed state and reloads
audit history; the isolated child fixture does not prove blanket owner-read isolation.
Full-history cost and native large-history redraw latency remain unmeasured.

## Three required UI amendments

1. **Saved steps need date context.** They appear inside task rows outside the existing
   day groups, but shared HistoryRow prints only hour/minute. Steps across days or
   years are ambiguous. Add absolute date/time context to saved steps while preserving
   the existing day-grouped audit row's compact rendering.
2. **Loading/error/empty states collide.** savedJobs is nil initially while the async
   appearance read runs. SavedJobs draws nothing, while dayGroups independently says
   “Nothing here yet.” That panel can remain after saved jobs appear or beside “Saved
   task history is unavailable.” Everything/Work must account for loading, loaded
   saved rows and error state; Approvals/Wake behavior should remain unchanged.
3. **Saved status reads as live.** jobState returns task.status.humanState from the
   appearance snapshot. “Waiting for your answer” or “Working” can remain after the
   task changed. Qualify the visible text as “Last saved state” or equivalent. Keep
   the existing “Right now” rail as the separate live surface.

Root received these findings. Exact UI hunk release is withheld pending amended frozen
pins and review; this is not a request for another human approval. Root may continue
its independent work while the packet owner prepares the bounded amendments.

## Verification limits

The prepared35 checks/six original missing-feature predictions are not executed
verdicts. The proposal uses actual isolated3tasks14events through Manager/backend/
executor/backing and hosted SavedJobs/HistoryRow body observations. Those observations
qualify consumer inputs only, not paint, keyboard/focus/VoiceOver or physical actions.
Missing body qualification must invalidate the comparison. Source/schema/receipt
preservation, no replay and malformed-journal refusal remain required controls.
Canonical application and unchanged original/fixed execution remain root-owned.
UX-04, full P6-08 and broader accessibility/latency/quality gates stay open.

## Additive copy/date37 packet: scoped UI release

The amended `saved-timeline-copy-date37-preparation` packet retains the parent
packet unchanged. Two independent static reviews accept the three amendments.
This review independently checked all19 listed pins, with zero mismatches, and
the current canonical ActivityView still matches its exact baseline.

- Manifest: `360f82ca844f6577ba5b879d675e842c261d84cad5035ca1e757f60a7118a4fa`.
- ActivityView baseline: `3b6785726fd7d8c0db5b19aa4624228c21bcaa9ae46bb3f0a17973afbbbd9477`.
- COMMON/fixed ActivityView: `2fc1b5ee0f8ef36d0b359e57d41d9552ace8f60b44650d68543728557ec005cc`.
- COMMON/fixed fixture: `843b0ada2cbc3c6b3ff509dd7aad709471065a1866dfbf9c62d606ade37c1f68`.
- COMMON patch: `d13e721daee7ab87b285b5db7849d885bb1a01d9c97369654e675e542827712c`.
- Producer patch remains `33fbd86e0497432d00c1af64078146f2e855b22c7c38aaacd8b1b76b9c94dd06`.

SavedJobs now says “Last saved” before the snapshot status and explicitly handles
loading, unavailable and no saved tasks. Everything/Work audit history says
“No activity entries,” so that separate history does not imply the entire pane is
empty. Approvals/Wake copy remains unchanged. SavedStep adds absolute year/month/day
above the unchanged HistoryRow time/content. The foreign companion header, rail,
filters, navigation, actions and DS treatments remain intact.

Release is limited to this exact baseline-to-COMMON ActivityView hunk, conditional
on runtime root rechecking the preimage before application. It grants no whole-pane
mounting, owner-store access, broad Source replacement or native slot. Projector,
JobReport, fixture, registration and producer execution remain root-owned.

The prepared37 checks retain all35 parent assertions and the same3tasks14events;
two added controls inspect hosted state/date values. Six predicted original failures
remain predictions until the identical original/fixed execution. Parse success is
not typecheck, paint, focus, VoiceOver, physical actions or large-history latency.
Whole-pane owner-backed initialization and the broader P6-08/UX-04 gates remain open.

## Root application checkpoint

Runtime root reports the exact four COMMON integration hunks applied for original
staged201, with the original nil producer retained. This UI tree independently
rechecked canonical ActivityView at the released target
`2fc1b5ee0f8ef36d0b359e57d41d9552ace8f60b44650d68543728557ec005cc`.
Root owns the serial Source/build/native slot. No installation, whole-pane mounting
or human action was authorized by this checkpoint. The original/fixed outcome
remains unreported here, so this source match promotes no acceptance gate.

Root's retained `original201-timeline37/run.json` now records exit1,3.08seconds,
Source/bundle invariance and the exact six T-F01–T-F06 missing-row assertions.
The fixture reached37checks, three actual tasks and14events, with qualified hosted
body/row observations. This is the original RED only; no fixed verdict or native
paint/interaction acceptance is reported by this checkpoint.

## Actual fixed202 paired outcome

[Paired production verification](../agent-overhaul-closure/p6-08-activity-ui-frontier/verification.md)
and `timeline37-paired-verification.json` retain original201's six exact failures
and fixed202's successful exit0 with the same37checks. Three real temporary task
flows and14committed events now reach actual SavedJobs/HistoryRow bodies. Only
AgentActivityProjector differs across1076compiler inputs. Source and signed-bundle
invariance hold. The measured body checkpoints change from zero saved rows/events
to three rows/14events, while the report source remains three tasks/14events.

Related durability37, authority58, worker1908, UI strings and store isolation
21files/32defaults pass. The first isolation run used the runner's default20second
budget and timed out; that result is retained. The identical test repeated under
the prescribed300second budget exits0 in36.3seconds.

This resolves the bounded historical row-projection regression and validates the
amended state/date consumers. Pixels, focus, VoiceOver, physical actions, whole-pane
owner isolation, large-history latency, owner-positive jobs CLI and full P6-08
revision/output/retry dependencies remain open. No app was installed; UX-04 stays
in progress.

Independent evidence review also checks the actual780entry NextNotes source
snapshots: only Projector differs (`1d2e80b6…` to `23598eadd…`), while UI
`2fc1b5ee…`, fixture `843b0ada…` and JobReport `7e343839…` are identical.
The root verification's phrase “date grouping” should be read as absolute date
context on saved steps: saved tasks remain waiting-first, with no added day-group
layout. The isolation retry's summary JSON omits a markerPresent field; its actual
run/exit0 and stdout supply the successful21files/32defaults evidence.
