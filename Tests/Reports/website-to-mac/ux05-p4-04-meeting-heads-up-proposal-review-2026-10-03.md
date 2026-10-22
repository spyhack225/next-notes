# UX-05 / P4-04: meeting heads-up proposal review

Current status: final169 packet accepted by two static reviewers for conditional
scoped UI integration. Original/fixed runtime and native acceptance remain open.
Historical findings and held intermediate packets below remain retained.
No canonical Source, index, build, model, native interaction or owner-store mutation
ran in this UI tree. Runtime root owns integration and native proof.

## Frozen input and ownership

Packet: knowledge worktree's
`Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-04-meeting-host`.
Manifest `9578dffec58ba5f80ec7a3f9468c36a5e6339b7efa8a005664e5f6dad2cd0933`
matches all50 retained file pins, independently checked with zero mismatches.
The four current canonical UI files match the packet baselines:

| File | SHA256 |
| --- | --- |
| DesignSystem.swift | `4834688eb005804071731afa6a359aa68434cdc3fd99cd62f5ac444bf57c1fe4` |
| IslandState.swift | `c336aac3c8c2de5015c457fdfbe96bd34fda78de4633171591db668fd3f351b8` |
| IslandView.swift | `4d53c60d50e954863ca330961b1bcf5f006899daffce1867d82d567f3aa1bf09` |
| AgentSettingsTab.swift | `e7432003a343b2e9a7901cae4676b78216098823bad4d142cb640f4f9e341f31` |

Historical Island/theme ownership belongs to this UI work, currently frozen; no
competing active owner was identified in our subtree. New settings section, startup,
scheduler/trigger publisher, assembler, host and fixture remain runtime-root work.
Whole snapshots must not replace newer canonical Agent/runtime hunks.

## Material priority gap

The fixed proposal's `ProactiveService.handle` guards `environment.isDictating`
before assembly (line109) and after assembly (line120). It does not guard a live
listening turn or pending approval. `IslandState.showHeadsUp` (line486) calls the
existing notice producer `push`; `refresh` (line587) selects `notice?.kind` before
`liveKind`. Thus the new low-priority heads-up has no publication/priority contract
preserving the listening waveform/Done or pending approval card. The notice lifetime
is8–30seconds and can extend while hovered. This is a source-confirmed priority
gap, not a claim that physical UI interruption was observed.

The actual prepared sink uses IslandState, but its fixture injects
`pendingApproval: { nil }` (ProactiveSelfTest line24), and its mode list contains no
listening or pending-approval cases. Prepared118 checks therefore do not cover this
overlap. A boolean microphone guard alone would also not protect an interaction
that begins after the notice was published; the existing state-priority seam needs
to preserve the active controls at that transition.

Root confirmed the finding and requested the producer owner repair it with actual
isolated pending/listening negatives after freezing the original shape. Preserve the
original9578 packet. Re-review the revised exact pins before releasing any UI hunk.
Do not add a conversational wait, second confirmation, timer, queue, store or audio
owner. The original and corrected consumer flow must be measured by root; no fixed
verdict is supplied by this review.

## Material public-log exposure

The independent second UI reviewer identified another producer contract gap.
`showHeadsUp` routes the full typed card through `push`, whose inherited logger
(IslandState line767) interpolates `String(describing: kind)` with
`privacy: .public`. The new associated `IslandHeadsUp` value contains the meeting
title/attendees and retrieved brief or memory lines (ProactiveBrief lines33–42).
This introduces that private context into the public log interpolation. The current
fixture checks no actual logger payload. This review confirmed the source expression;
it did not capture a native unified-log entry.

Root received this additional hold. Fix the owning logger's metadata contract,
preserving visible user content and excluding that content from public metadata;
do not scrub the brief to conceal the log issue. Exact producer-level negative
coverage and revised frozen pins remain required before UI release.

## Essential context lost at the title budget

The second reviewer also traced loss of timing and people to the actual builder.
ProactiveBrief lines40–42 append “in N minutes” and the attendees after the full
event title, then truncate the entire combined string to140characters. An event
title of140characters or more removes both essential facts. A conference-only
brief can have no detail lines, leaving no other place for those facts in the
Island, notification or recorded session text. The prepared fixture's short
`Pricing\nreview` title does not exercise that input.

Root received the producer finding. Preserve time and attendee context within the
existing bounded builder and test the same long-title input before/after. The
Island's existing one-line heading may additionally clip visible content, but no
physical clipping measurement was made; it does not justify guessed heights or
a layout acceptance claim.

## Other bounded presentation contracts

The card uses typed event identity/actions, bounded title and at most two factual
lines. It retains existing Island body/action layout and DS styles. Open/Not now
route through the existing sink; no approval or effect authority is added. The
Off/Show setting uses a native Picker and plain consumer copy, with no spoken
ownership option. Reading duration is a shared DS token rather than a new task
timer: minimum8, maximum30, minimum plus0.05seconds per character. No physical
reading, focus, VoiceOver, wrapping or small-screen layout acceptance is claimed.

The independent runtime review marked the bounded source slice ready, but did not
cover the priority gap above. Root now explicitly holds host118 from mounting.
Prepared41 original targets and77 controls are predictions, not native outcomes.
Notification posting, actual Open/Not now/Turn off behavior, owner isolation,
shutdown integration, first display, motion/latency, P3 ownership and broader
P4-04/UX-05 acceptance remain open.

## Revised157 packet: two fixes accepted, priority transition still open

Additive `interaction-privacy-context-revision` manifest
`079199958686169f581cefe79948f4c4e9b1bdc1bb3d845a2c622f68232f3b9f`
matches all51 pins, independently checked. The four current canonical UI preimages
still match the historical baselines. Original9578 remains retained unchanged.

The logger now consumes the exact category-only `noticeLogLabel` operand; its
COMMON version retains the old associated-value operand for comparison. Brief
separately budgets the event title and time/people suffix within the same140character
bound. Known synthetic canaries and a long conference-only input exercise those
actual producers in the identical prepared fixture. These two fixes are accepted
by two independent static reviewers, pending native before/after verification.

The service checks `sink.canShowHeadsUp` before retrieval and before publication.
The actual live sink checks Island pending/current kind and Activation mode. The
same ledger treats deferred interaction rows as eligible on the next existing tick.
The fixture adds listening/pending states before and during actual retrieval and
checks release produces one delivery. This repairs the prior/during-publication
gap through the existing seams, with no new conversational wait or queue.

The transition **after** a heads-up is already published remains unhandled.
Island `refresh` still takes the existing notice before any live state. Actual
`DictationController.beginDictation` sets `.starting` (canonical line1331), and
Island's existing observation of dictation state calls `refresh`; that path has no
notice clear. At notch placement a new dictation can remain covered by the heads-up
until expiry, even though the host checked eligibility earlier. Prepared157 has no
actual dictation-after-shown case. Exact UI release remains withheld for this
producer priority correction and original/fixed production-path proof.

The actual voice and approval call sites narrow this finding: `beginAgent` calls
`showAgentListening`, which clears the notice, and `PermissionGate.present`
synchronously raises `IslandState.propose`, replacing the prior heads-up. An
injected pending supplier changing alone is therefore not evidence of the actual
new-approval failure. Preserve these existing transitions and other notice
contracts; fix the passive heads-up's priority at the existing seam, without
initializing owner-backed sources just to test it.

Prepared157/52 predicted feature failures are still unrun. Source pins and static
test call-site coverage do not establish native pixels, focus, VoiceOver, actual
notification effects, owner-read isolation or latency. Runtime root owns the serial
Source/native slot and the required bounded verification.

## Final169 packet: conditional scoped UI release

Two independent static reviews accept the additive
`post-publication-dictation-revision` packet. Manifest
`8284488f95950f0ad49fd98305410999ba356ad963f7d28cfb7f5c275e7fe328`
matches all55 retained pins, independently checked with zero mismatches.
Historical157/manifest07919995 remains unchanged. The four canonical UI baselines
listed above still match; current Core also matches
`881bff421bc879a2d96b6f8051a0410d1a5eb32b0863648df6166349d8e76a4b`.

Island's COMMON initializer weakly attaches the existing optional controller and
stores the HUD-placement closure, whose default is the existing Settings getter.
The fixed refresh branch applies only when the stored notice is agentHeadsUp and
the real controller passes its existing shouldShowHUD/notCommand/notch predicate.
It uses the existing card producer and capture flag. The notice/deadline remain
retained; other notices and bottom placement retain their old priority. The new
branch reads no Activation owner, and the injected diagnostic closure avoids
Settings owner reads. No new await, timer, queue, store, save or permission is added.

The identical COMMON/fixed fixture adds12 real Controller.state→refresh checks to
the retained157. Starting/listening/finishing/error are projected by the actual
Island refresh after a real typed heads-up was shown. Idle restores the retained
notice with the same deadline; bottom placement and an ordinary reply preserve old
priority. The confined diagnostic setter refuses a foreign root. Explicit temporary
UsageLog and constructor callbacks establish no engine, capture, selection, record
or outcome callback, and the existing queue is flushed before cleanup. start(),
global observation and key-down are not invoked. This is actual presentation-state
consumer coverage, pending execution, rather than physical microphone evidence.

Exact UI release is conditional on root's preimage recheck, limited to the reviewed
UI common/producer hunks. It includes the four existing UI paths and new
ProactiveSection; Core/App and all other host producers remain root-owned.
Whole snapshots must not overwrite newer shared work. Exact pins:

| Artifact | SHA256 |
| --- | --- |
| Dictation priority COMMON patch | `1ae131e41dba8f81b69e374a0042b18915c259d03edc35129aa0d8f390afd50b` |
| Dictation priority producer patch | `8dd98760da81374853a6cc768af8591594ee7bb641cba8b8816af80f029fe18d` |
| IslandState COMMON | `c63147cc45fdeda06eeef37279d6ecfb8e666090a505d387d6eefbce64b8a20e` |
| IslandState fixed | `cfe3df2e93238216842363068679f7f2428dad98d59dd65898c5dcbdbb701b0d` |
| DesignSystem COMMON | `37fec51b566a91206b63db27783aea81ba49f649fd2272be87e4e2a6ef9d35c3` |
| DesignSystem fixed | `292eb62ebd4fe7ac2ef6c53ab364462d9dbce22da260ba5725ffd637a301a1d6` |
| IslandView COMMON/fixed | `b3f16a10633566193899456852c88630be03c73d6d8b53873f7ec01a705e7806` |
| AgentSettingsTab COMMON/fixed | `bc09314f9ccd14da60e49d4f801ff575d4aad1871f9b2a348312b63aedc9eb71` |
| ProactiveSection COMMON/fixed | `c9fb707649953c20fbf362281ead45ecaaacd440b8aef31c6415f46fe564f370` |
| Fixture COMMON/fixed | `15b09dec0069fa8accbf659a46b7dabf28a40012979f7015b2c6f691986ccb3d` |

This releases source integration, with no canonical Source/native work performed
here. Prepared169/56 predicted original failures remain unrun; parse success is
not full typecheck or a verdict. Root must preserve identical inputs and relevant
guards while proving the original RED/fixed flow. Whole-startup owner isolation,
physical UI/Stop/notification/actions, focus/VoiceOver, display/motion/latency and
broader P4/P3/UX-05 quality gates remain open. No installation or whole-pane native
UI access is granted by this review.

## Privacy composition after bounded284 acceptance

The separately frozen [rebase packet](p4-04-notice-privacy-rebase-2026-10-03/README.md),
manifest `addea3dbd530946f821926c87b4c5680c3bce5c298c3546b8f6cfea5fae06696`,
supersedes the Island composition instructions above. Runtime root reports
corrected original282 primary RED2/37 and privacy RED2/284, followed by the same
fixtures passing fixed284 and all28 related checks. Parent rechecked canonical
Island SHA `395dd955947d227b608e7a229111ecf9c5cc31694ad0761a43368c28b03607db`.
Those checks establish the separate privacy prerequisite, not P4 completion.

Independent static review matched20 pins and reconstructed all five relative
patch stages. Parent separately verified packet hashes, root input pins, the
retained final169 fixture and the exact single-string amendment. The admissible
P4 COMMON patch `bf0bb4cd…` produces Island `de227516…`; producer patch
`e26cccea…` produces `c7daea91…`. Both preserve the root's actual push, conditional
observer and public logger block byte-for-byte. The new heads-up case has a
constant category; the diagnostic helper forwards the same actual Kind policy.
The `c3fc…` comparison branch is HELD and is not an integration path.

Root approved a separate paired COMMON amendment, `ad3eb119…`, changing only
F27's expected category from `notice` to `agentReply`. Apply it before BOTH P4
variants; resulting fixture SHA is
`653b591d31197f69bb43a9022f513574e400f52aa80b7ab479d3587426af67bc`.
All canaries, check expressions and case inputs remain unchanged. Frozen169
remains untouched. Retire the historical predicted56 original-failure count:
the accepted prerequisite changes that baseline, and the amended pair must be
qualified from actual observed results.

Exact relative Island integration is statically accepted on the accepted395
preimage, subject to root rechecking the complete18-file P4 owner composition.
Amended169 compiled original/fixed verdicts and related checks remain UNRUN.
Root8 exercises actual reply/proposal log operands; helper F26/F27 do not prove
actual heads-up logging. Physical display, actions, focus, microphone, VoiceOver,
motion, latency and broader P4/UX-05 acceptance remain open. This review performed
no canonical source, compiler, native, index, installation or owner-quit action.
