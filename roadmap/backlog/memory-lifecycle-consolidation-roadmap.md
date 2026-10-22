# Next Notes Memory Lifecycle and Consolidation Roadmap

**Project:** Next Notes
**Baseline:** `78cebc9` (2026-09-25) — all anchors re-verified by grep on that date
**Written:** 2026-09-25, from the audit in
`roadmap/todo/next-notes-multi-agent-durable-jobs-memory-roadmap.md` §1–§3 (now deleted; the
substance is below and in `AGENT-OVERHAUL/REVIEW-LOG.md` §6)

**Status: not scheduled. Read §0 before planning anything here.**

**Sequencing revision, 2026-10-01:** P4-07a may start from its existing isolated
write/provenance contract without waiting for an aggregate Agent score. P4-07
and P4-11 still follow it, and all three remain required before lifecycle mutation.
This roadmap stays unscheduled; corpus/precision/recall/information-loss proof
is still required. [Implementation policy](../in-progress/AGENT-OVERHAUL/00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).

**Owner alignment revision, 2026-09-30:** model roles are independent and exact
verified artifacts are shared. Follow [SHARED-BRAIN](../in-progress/SHARED-BRAIN/00-README.md)
and [MODULES-ACTIVATION](../in-progress/MODULES-ACTIVATION/00-README.md). Consolidation uses the
existing memory-review model selection and workload/source consent; it does not
inherit the Agent or notes choice/consent merely because they share a file. Reuse
a compatible installed artifact through the existing library, download no new
model implicitly, and yield to interactive work without swapping out a voice lease.
Keep proposer/adversary/judge as background passes on existing providers, not a
requirement for three dedicated model files/runtimes. Log passes in usage.jsonl.
The ten-category fixture corpus and predeclared precision/recall/information-loss
criteria must be built before Phase B can be scheduled; task IDs/ledger/gates must
be written when scheduling, without presenting this proposal as executable today.

**Product bar:** this file is executed under AGENTS.md "What we optimize for" like every other
roadmap. Efficiency, speed and full-duplex conversation come first, and no new store, scheduler
or abstraction goes in without checking the existing seam first (the supersede chain,
`MemoryGuard.saysTheSameFact`, the extraction resume gate). Consolidation is background work: it
must stay off every path the user waits on, and a run that cannot be stopped must not start.

**Prerequisites, already scheduled:** **P4-07a → P4-07 → P4-11** in
`AGENT-OVERHAUL/05-PHASE-4-PROACTIVE.md`. This is Phase 4's authoritative memory
order; lifecycle implementation starts after all three, not merely P4-07a.
P4-07a preserves provenance and introduces hand-written MemoryEntry decoding;
P4-07 captures explicit statements; P4-11 repairs background review. Corpus design
can happen earlier without mutating memory or changing Phase 4's exit gate.

**Siblings:** `roadmap/in-progress/AGENT-OVERHAUL` (the spine; this file is sequenced behind its
Phase 4), `NextNotes-iMessage/`, `Phone-Calls/`.

---

# 0. Why this is not a phase of AGENT-OVERHAUL

Both directories under `roadmap/in-progress/` have a contract: a `STATUS.md` ledger with states, a
`00-README.md` per-task workflow, task ids with Depends-on lines, a strangler migration order, and
a phase gate with a report. Everything in `in-progress/` honours it.

**This work cannot have an honest gate.** §3's exit criterion is precision and recall against a
ten-category fixture corpus, **and that corpus does not exist yet.** Building it is itself work —
and AO §12's standing rule is that a limit or a threshold is only believable with a measurement
behind it. A phase whose gate cannot be evaluated is not a gate, and adding one would make Phase 4
unpassable for every other task in it.

The audit that produced this file also found that the original proposal's data model had a privacy
problem, which is recorded in P4-07a and summarised in §1.3.

---

# 1. Premise

## 1.1 What exists, and is finished

`Memory/` is **8,805 lines**, of which `Portability/` is 2,308 and the self-tests are
`MemoryReviewSelfTest.swift` (1,371) + `MemorySelfTest.swift` (759).

Capture is done. `MemoryReviewer.swift` (1,288) learns from dictation, meetings, conversations and
the life map; binds writes to trusted provenance; distinguishes user words from untrusted
speaker/tool/model text; uses `.memoryReview` authority; and `MemoryReviewScheduler` (:762) runs at
a 60 s tick with backoff `[60, 300, 900, 3600]` and aborts while dictation or a meeting is
recording. `allowedTools` is three calls, `maxCalls` is 5.

**The missing layer is memory lifecycle management, not memory capture.**

## 1.2 The finding

`grep` across `Sources/` and `windows/`: `MemoryTier` **0 hits**, `lineage` **0**,
`consolidat` **0**. The only near-duplicate machinery is `MemoryGuard.saysTheSameFact` (reached via
`NextMemory.nearDuplicate`, `NextMemory.swift:643`) and the linear `supersedes`/`superseded` chain
walked by `forget(id:refreezeSnapshot:)` (:710) and undone by `undoSupersede(id:)` (:777).

So: a memory today is a replacement chain of single-parent rows. It is not a lifecycle, and it is
not a lineage.

## 1.3 What P4-07a fixes, and what it deliberately refuses to fix

P4-07a adds `MemoryLineage { records: [MemoryProvenanceRecord], consolidatedFrom: [UUID],
consolidationRunID: UUID? }` and persists it. What it does **not** do is persist
`MemoryProvenance` itself.

The original proposal wrote `var provenance: [MemoryProvenance]`, and that is wrong.
`MemoryProvenance` (`Memory/MemoryGuard.swift:8`) holds `userText: [String]` (what the user said)
and `untrustedText: [String]` (other speakers, tool results, emails, files, pages). It is a
`@TaskLocal` **gate**, meant to be read once and discarded — persisting it would write every source
turn's raw text into `next-memory.json` and retain exactly the quoted content `UsageLog.sanitise`
exists to keep out of `usage.jsonl`.

**The rule this establishes, and it governs every phase below: record where a fact came from, not
what was said.** A merged memory keeps the ids and the channels; it does not keep the transcripts.

## 1.4 Two schema rules that will bite

- **`MemoryEntry` needs a hand-written `init(from:)` before it gets any new non-optional field.**
  A synthesized `init(from:)` does not fall back to a property default for a missing key, so every
  existing `next-memory.json` stops decoding and every memory the user has silently vanishes. The
  original audit found a silent-empty fallback; the current loader may instead quarantine
  unreadable files. Neither makes a lossy migration acceptable. Recheck the live loader and
  require lossless old-file fixtures. This is the `MeetingModels` rule.
- **At the 2026-09-25 baseline `StoredFile` was version 2** (`NextMemory.swift:1150-1165` holds the version-1 → 2
  migration, and the pattern to copy). P4-07a plans version 3, so inspect the actual post-prerequisite version before
  assigning the next version. A new phase adds an **additive** migration and
  must not synthesise provenance nobody recorded. `nil` means unknown, and unknown is not
  `userSaid`.

---

# 2. Phase A — memory tiers

A **lifecycle dimension beside** the existing kinds. Not a replacement for them.

```swift
enum MemoryTier: String, Codable, Sendable { case short, long, permanent }
```

A memory then has both a semantic kind and a lifecycle tier:

```text
semantic kind: profile
lifecycle tier: long
```

`NextMemoryKind`'s eight derived-activity cases (`person, project, vocabulary, meeting,
commitment, file, toolPreference, recurringAction`) are **not touched**. Activity items stay
derived. Tiers apply to core `MemoryEntry` rows only.

## 2.1 The three tiers

**short** — current temporary context, recent working facts, possibly outdated soon, useful for the
next few sessions. Decays fast, cheap to prune, promoted when repeatedly useful.

> User is currently evaluating two enclosure suppliers. This week's launch target is Friday.

**long** — recurring projects, stable preferences, established relationships, durable working
context. No aggressive TTL, contradiction-aware, eligible for consolidation.

> Sarah works on enclosure design. The user prefers concise status updates.

**permanent** — explicit user-approved identity and preferences; foundational facts that must not
be discarded.

> User prefers French for formal correspondence.

**Permanent must not mean "uneditable." It means never auto-prune.** The user can still update or
forget one, and `undoSupersede(id:)` (`NextMemory.swift:777`) is the mechanism its history travels
through.

## 2.2 Migration

- Existing entries default to `tier = long`, which avoids suddenly expiring memories somebody
  depends on.
- Add `tier`, `lastUsedAt`, `consolidatedAt`. `useCount` already exists on `NextMemoryItem`;
  add it to `MemoryEntry` with a default of 0 so Phase B's Proposer has a real view on day one.
- **Do not change** the 2,400 / 4,000 / 300 character budgets (AO §12), the `MemorySnapshotCache`
  selection order (whole entries, newest-first, `NextMemory.swift:1215`), or the prompt's memory
  share — P4-08 owns that.

**Exit:** an old `next-memory.json` loads losslessly and produces a byte-identical prompt snapshot
before any consolidation runs. Self-test: extend `--selftest-memory` (CORE).

---

# 3. Phase B — consolidation, dry run only

```text
NextMemory
     │
     ▼
PROPOSER            merge / supersede / prune / promote / demote
     │
     ▼
ADVERSARY           tries to prove each proposal unsafe
     │
     ▼
JUDGE               approve / reject / needsHumanReview
     │
     ▼
DETERMINISTIC VALIDATOR
     │
     ▼
CONSOLIDATION PLAN
     │
     ├── low risk ──► apply ──► snapshot / audit log
     └── no        ──► review queue
```

```swift
enum MemoryConsolidationOperation: Codable, Sendable {
    case merge, supersede, prune, promote, demote
}
```

The Proposer never writes memory. The Judge is **not** the enforcement layer; code still validates.

## 3.1 The Adversary's job

Prove each proposal unsafe. Its checklist is the acceptance criteria:

- are these actually different facts?
- would specificity be lost?
- does one memory come from stronger provenance?
- is a correction being erased?
- does a merge combine two people or two projects?
- is an older memory still useful historically?
- would pruning remove a hard-to-rediscover fact?
- is a manual or permanent memory being touched?
- is the proposal relying on untrusted tool or model text?

```swift
struct MemoryConsolidationChallenge {
    let proposalID: UUID
    let severity: Severity
    let objection: String?
}
```

## 3.2 Deterministic rules

An approved Judge decision still passes code.

**auto-merge** only when: same semantic subject · no manual or permanent row deleted · no
conflicting provenance · replacement stays declarative · all source entries retained in
`consolidatedFrom`.

**auto-supersede** only when: a clear newer correction · strong subject match · the older row kept
as history.

**auto-prune** initially restricted to: short-tier duplicates · expired low-value context · exact
or near-exact redundant rows. **`MemoryGuard.saysTheSameFact` already answers the near-duplicate
question deterministically — reuse it.** Do not ask a model to decide what code already knows.

**human review** for: permanent · manual · identity changes · relationship changes · high-severity
objection · ambiguous contradiction.

## 3.3 Schedule and persistence

Triggers: daily idle, a count threshold, or a manual "clean up memory". Conditions: no meeting
recording, no dictation, no active voice session, low compute pressure.

**Reuse `MemoryReviewScheduler`'s rules** (60 s tick, backoff `[60, 300, 900, 3600]`, aborts while
recording) and join the `WorkClass` ladder so consolidation is a P5 lane. A memory consolidation
run that degrades voice **yields**. P5 here means the lowest-priority work lane,
not AGENT-OVERHAUL Phase 5; use the actual existing WorkClass case, not a new scheduler.
If this work is made durable, extend TaskBridge/Phase 6 rather than adding a jobs ledger.

Persistence: **extend the existing durable NextMemory store, not a new file.**
The former proposal to make KnowledgeStore hold the authoritative undo snapshots is
superseded: knowledge.sqlite is explicitly derived/disposable and can be deleted
and rebuilt. A memory merge must remain undoable after an index repair or graph-off.
Store the minimum run/operation identity, input memory IDs, provenance and before/
after memory snapshots needed for history/undo in NextMemory's existing StoredFile,
with an additive migration. Never persist source utterances, tool bodies or model
reasoning; usage.jsonl holds model/runtime/timing/outcome metadata, not another
consolidation metrics ledger. Knowledge tables may contain rebuildable projections
only, never the sole durable undo record.

Before Phase C, specify and fixture-test one atomic NextMemory persistence boundary
for mutation + undo history, recovery after interruption, idempotent operation IDs,
failed writes and undo after knowledge.sqlite deletion. Do not require a five-table
SQL design for its own sake; use the existing store's atomic writer and smallest
adequate schema. Record bounded history/retention requirements before storing large
snapshots; forgetting a fact must also remove retained copies where applicable.

## 3.4 The fixture corpus, and why two of its categories matter most

Ten categories: exact duplicates · paraphrased duplicates · corrections · changed preferences ·
**person-name collisions** · **project collisions** · identity changes · stale short-term context ·
imported/manual memories · permanent rows.

The two collision categories are the ones that can corrupt silently. `PersonResolutionStore`
(`Knowledge/PersonResolutionStore.swift`, 500 lines) already merges graph-side identities on
purpose and follows a `merged_into` chain to its end — a consolidation that merges two people the
graph deliberately kept apart is the exact failure this corpus exists to catch. **Share its
`person_entity` cases with the self-test** rather than inventing a second identity corpus.

**Exit:** no writes. Precision/recall and an information-loss review, and a self-test that **fails
when the judge approves a merge the validator should have blocked.**

---

# 4. Phase C — safe auto-application

**Auto:** exact/near-duplicate short merges · explicit correction supersession · expired short
context pruning.

**Human review:** identity · permanent · manual · relationships · ambiguous contradictions · high
adversary severity.

Every mutation must be: reversible · provenance-preserving · visible in history · executed under
`.memoryReview` authority · covered by a self-test. `undoSupersede` exists today; a **merge** needs
its equivalent, backed by the before/after snapshots §3.3 stores.

---

# 5. UX

Settings → Agent → Memory — the existing `MemoriesSection` inside `AgentSettingsTab`, **not** a
thirteenth `SettingsTab`.

```text
Memory
  ├── Recent
  ├── Long-term
  └── Permanent
```

```text
Sarah leads enclosure design
Long-term

Learned from your Design Review, Sep 22
Merged from 2 related memories
```

Actions: **Keep permanently · Move to recent · Edit · Forget · View history.**

Consolidation status, as plain counts:

```text
Last cleaned: Today, 3:14 AM
3 duplicates merged
1 outdated memory replaced
0 permanent memories changed
```

**"Proposer / Adversary / Judge" must never appear in consumer UI.** `--selftest-ui-strings`
scans `UI/` for banned developer words (`cron`, `artifact`, raw tool ids, schema keys) and fails per
offender, so that is a test failure, not a style note. Views use `DS` tokens only; no literal
colours, sizes, radii or durations.

---

# 6. The Knowledge Graph stays separate

Non-negotiable, and it is a *design* rule rather than a data rule.

```text
NextMemory       → personal working memory → consolidation allowed
Knowledge Graph  → sourced facts, events, people, decisions → citations
                 → do NOT LLM-collapse source evidence
```

Consolidation must not rewrite meeting chunks, graph source nodes, cited decisions or transcript
evidence. It may use graph facts as **context** only where consent permits — and `Chunker.notes`
already skips the Related-context brief for exactly this reason, so follow that precedent instead of
inventing a gate.

`--selftest-ask` and `--selftest-index` are the regression flags; the graph's own provenance
assertions are what would catch a violation.

---

# 7. Sizing

| Item | Prod | Test | Note |
|---|---|---|---|
| Phase A — tiers | 800 | 500 | migration is the risk, not the field |
| Phase B — consolidation dry run | 2,000 | 1,500 | the fixture corpus is a large share |
| Phase C — auto-apply | 700 | 600 | merge undo is the new surface |
| **Total** | **~3,500** | **~2,600** | **~6,100 lines, 3% of the tree** |

Excludes P4-07a, which is already a Phase 4 task.

---

# 8. What will still have never run

Copy these into `AGENTS.md` as each phase lands.

- **Consolidation quality on real memory.** §3's precision/recall is against a fixture corpus. This
  machine's memory has never been consolidated, and a fixture corpus is not the user's memory.
- **A real merge, then undone.** Every case is seeded. A merge that a person watched happen and then
  reverted has not.
- **Lineage on an entry written before P4-07a.** The migration is "old files load losslessly";
  nobody has checked that a real `next-memory.json` with real history round-trips through it.
- **A person asking where a memory came from.** The record exists so the app *could* answer it; no
  surface does yet, and §5's "View history" is the obvious place when one wants it.

---

# 9. Reference architecture

`raroque/boop-agent` `server/consolidation.ts` is the Proposer → Adversary → Judge shape worth
studying. The three-model loop, the structured operation list and the determinism of the validator
transfer; the storage, the tiers and the consent model do not — this app's provenance gate
(`MemoryGuard`) and its Knowledge Graph separation are stronger than anything in that file, and
§1.3's rule about recording provenance rather than content is this app's own.

## Agent follow-up evidence — 2026-09-30

[P1-31b report](../../Tests/Reports/toolloop-live/2026-09-30-p1-31b-follow-through.md) records honest TIMEOUT classification and broad-mail grounding on existing seams. The save/draft/combined-read prompt experiment was rejected after ordinary quick 5/10→4/10; interruptions under heavy load are not model scores. Final source keeps the original planner instructions. No Agent/notes/cleanup default or model file changed. Parent Agent quality gates remain open; this is neither SB-07 completion nor module/memory-lifecycle implementation. Follow AGENT-OVERHAUL STATUS for retained-source verification and next work.


### Current bounded Agent save evidence — 2026-09-30

P1-31c committed as `4063667`: [explicit-memory report](../../Tests/Reports/toolloop-live/2026-09-30-p1-31c-explicit-memory.md). The original Cyril save now executes one guarded `memory.remember` and survives durable reopen; ordinary and Needle-first-enabled Y01 pass. Integrated production/usage/store/voice checks and 30 correction tests pass. Fixed Qwen quick 4/10→5/10 still fails the unchanged 9/10 gate; Y01 is outside that set and whole-case p95 worsens 51.417→59.094 s, so no broad quality/latency gain is claimed. General drafts/combined work and complex memory requests remain. Parent P1-31/Phase 1 stay open; this does not complete SB role-quality work or P4-07a→P4-07→P4-11 memory-lifecycle prerequisites.
