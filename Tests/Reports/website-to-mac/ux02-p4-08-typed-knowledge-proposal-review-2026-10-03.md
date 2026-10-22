# UX-02: typed knowledge answer consumer review

Status: read-only review of the knowledge worktree's proposed P4-08 typed route.
No Source application, compilation, native interaction or fix verdict by this UI tree.

Packet:
`/Users/sergekadjo/Library/Caches/NextNotesBuild/AgentOverhaulWorktrees/run-04a3f48d3dea/knowledge/Tests/Reports/agent-overhaul-closure/next-implementation-review/p4-08-production-routes/typed-route`.

## Ownership and bounded UI changes

No active conflicting AgentView/AskView owner exists in this UI tree. Canonical
AgentView `f5f3f0a6f2d1ea832ccc236ec4d6fc165ffd9e3bbabb62e64b55b5d767fa2a1d`
and AskView `137f24e8f62c394f1997ee5deec5069914f45e35886bdf8f2dc88648e51de322`
match the packet preimages at review time. Root retains canonical application,
composition with memory fields, compiler/native/model and index ownership.

COMMON extracts the existing ClaimRow into KnowledgeClaimRow without changing its
text/chip fonts, FlowLayout, spacing, selection, actions or help text. The Ask lookup
continues to select the first retrieved citation matching a claim's chunk ID. The new
AgentView message Group retains the existing bubble, role caption, outer typography
and sizing. Its citation navigation copies the existing Ask handler: exact meeting
UUID/time for meeting sources, generic sections for conversation/routine/dictation,
no action for unavailable targets. No theme or portrait change is included.

Those navigation limits, unavailable-source no-op and native focus/VoiceOver behavior
are inherited or unverified; this proposal does not establish exact nonmeeting source
navigation, physical chip activation or visible citation acceptance.

## Required presentation producer correction

The draft has a source-confirmed presentation contract mismatch, not yet reproduced
through its compiled actual handle fixture:

1. KnowledgeAsker.answer validates citation IDs and strips citation markers. Its
   KnowledgeClaim.text remains otherwise the model's text.
2. Existing finishTurn computes AgentReplyRenderer.scrub(reply), which removes raw
   tool markup, registry IDs and step counters before the saved reply is produced.
3. Proposed finish passes knowledgeAnswer.claims unchanged into recordAssistant.
4. New AgentView.messageRow renders those raw claim.text values instead of the cleaned
   message.text whenever knowledge fields exist.

A cited response carrying `filesystem.read` or `<tool_call>` can therefore have a
clean returned/saved text but render the raw strings through its new claim rows.
Any legitimate handoff-note prefix added to reply can also disappear when claims
replace the complete message text. The responsible saved-message/presentation
producer must keep the displayed claims and complete reply contract consistent.
A Text-level scrub would mask retained incorrect presentation data and is not the
requested producer fix. The separate existing Ask raw-claim path is inherited and
must not be counted as repaired by this new route.

Root received this finding before the next canonical original/fixed pair. Required
verification: unchanged actual handle → KnowledgeAsker → saved-message fixture
with raw marker/registry and complete presentation controls, checking the exact
claim values consumed by the new rows. Add the fixture COMMON before both compilers;
retain a real original failure and identical fixed result. No Source edit or native
test was run here.

## Point-in-time preparation pins

Manifest `8f1220de4cbff7c2eb0c122f148d7f4d802b6538b39a65e9c87d9e09bd49aa84`;
COMMON patch `868c9eaada4a350afb8807e5767d3df6b84fe82ac43e2873ca457a3d978c2c6c`;
producer patch `6c03ae2175b6955a5e2a778f1a49995a69bc3accf14c6ea85ff76a13af4f91a3`.
The packet's33 checks/nine predicted original targets are preparation arithmetic,
not a native verdict or frozen admission. Any amendments require fresh pins and
paired proof. No blanket owner-read isolation, normal nested authority, native
appearance, first displayed-frame timing, latency or broader roadmap gate follows.
UX-02 remains in progress.

## Qualified staged original161 / fixed162 evidence

[Root verification](../agent-overhaul-closure/typed-knowledge-production/verification.md)
and its paired JSON retain original161's18 missing-feature assertions and fixed162
PASS for the same59 expressions across11 modes. Actual process exits and final
1062-input Source/bundle invariance are retained separately from preparation pins;
the final compiler pair differs only in RealtimeAgent.swift and
RealtimeAgent+ToolLoop.swift. Both use the same fixture
`538c6f9dc410214a2f0ce589d57096edb41de3b5d470f11a93ea76cc02388084`,
authored fragments, answering provider, isolated corpus and actual publication receipt.
These are staged diagnostics, not installed or native source-chip acceptance.

The responsible finish producer now parses citation markers before rendering each
claim, matching the canonical reply order. It preserves a handoff prefix as uncited
text, filters to actually allowed citation IDs, drops only empty rendered claims and
keeps canonical equality plus the12,000-character saved-message cap authoritative.
Longer source rows are omitted rather than reproducing content outside that row.
This resolves the reviewed raw-claim presentation path in the actual fixture. The
existing renderer's missing closing answer-tag pattern was repaired separately and
did not by itself resolve the producer mismatch.

Intermediate fixed158/159 still failed markup and are retained. Actual160 exposed
parser/render whitespace ordering and a separate fixture scheduling error: the second
upstream provider pull did not acknowledge downstream presentAnswer. COMMON corrected
the fixture to observe actual respondingMessage publication before releasing the same
second authored fragment. All59 expressions remained unchanged before161/162. This is
a consumer receipt, not fabricated publication, a product observer or a user-path wait.

Successful library answers resolve one existing provider and stream through the actual
KnowledgeAsker/graph-reader/presentAnswer/saved-message route. Genuine ask failure
falls back once on that provider. File search, remote input, gate unavailability,
read-review requirements and combined action requests retain their planner path;
an action word used as a question topic remains a library question. Seven related
flags pass, including voice/duplex, UI strings and isolation21files32defaults. These
diagnostics hash owner bytes/defaults; this is not a zero-I/O claim.

Quick162's initial sampler failure is INVALID. Its corrected runner retains the actual
child but times out before any scored case at the unchanged300-second diagnostic
budget; no score or quality pass follows. Latest scored quick156 remains FAILED3/10
against9/10. Full CORE, native source-chip navigation/focus/VoiceOver, live/installed
acceptance, reader-scaled memory and Assembler budgeting remain open. UX-02 stays in
progress and this UI tree performed no Source, native, build, install or index action.
