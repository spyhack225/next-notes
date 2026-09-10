# The second brain

A searchable, queryable, connected memory across every transcript, every set of meeting
notes, and — optionally — every dictation this app has ever produced. Ask it a question in
English, get an answer with citations that jump back to the second of the recording the
claim came from.

This document is the plan. It is macOS-only; `windows/` is still dictation and nothing here
is in scope there.

## The precondition, before any of it

**There are two meetings on this machine.** Both have `attendees: []`, one is an untitled
detected WhatsApp call, and `runs.jsonl` holds 62 dictations. Per `README.md`, the
system-audio tap has never produced an "Others" track, no calendar account has ever been
connected, and no Workspace write has ever run.

A knowledge graph is a machine for finding non-obvious connections across a large corpus.
At two meetings it has nothing to connect, and — worse — there is no way to tell a good
retrieval design from a bad one, because every query returns everything.

So the ordering rule for this whole document: **Phase A and B are worth building now
because they make today's search better on their own. Phases C and D should not start until
the library holds 100+ real meetings with real attendees.** The prerequisite is not code,
it is corpus.

---

## Shape

Seven layers. Each one is useful without the one above it, which is the only reason this is
shippable in pieces rather than as an eighteen-month rewrite. Only the top two draw a graph
at all, and they are the last things built — search, ask and the decision thread all ship
below them.

```text
G  global graph          every node on one canvas; optional, and honestly decorative
F  local graph, timeline one node's neighbourhood; one person against time
E  ask                   retrieve -> rerank -> answer with citations
D  entity resolution     one person is one node, across 200 meetings
C  extraction            decisions, actions, questions, people as typed rows
B  embeddings            dense vectors, hybrid with FTS5
A  the index             chunks in SQLite, FTS5, crash-consistent
   ---------------------------------------------------------------
   meeting.json / transcript.json / notes.md   (what exists today)
```

The store on disk stays the source of truth. Everything from A upward is **derived and
disposable** — deletable at any time and rebuildable from the meeting folders. That is not
a nicety; it is what makes every schema change in this document survivable.

---

## A. The index

### What is wrong with what exists

`MeetingStore.matches(_:query:)` is `localizedCaseInsensitiveContains` over one concatenated
string per meeting, built by `prepareSearchIndex()` and held entirely in RAM. It is honest
and it works at fifty meetings. At five hundred it is a frozen window and several hundred
megabytes of transcript text resident for a feature nobody is using at that moment.

It also answers the wrong question. It tells you *which meeting* matched. Nobody wants a
meeting; they want the ninety seconds inside it where the thing was said.

### The unit is a chunk, not a meeting

A chunk is one retrievable passage:

- **transcript chunks** — a run of consecutive `TranscriptSegment`s from a single speaker,
  cut at the first pause after ~150 words, hard cut at ~300. Carries `meeting_id`,
  `start`/`end` in seconds, `speaker`, `source` (mic/system).
- **notes chunks** — one bullet or one paragraph under one of the five fixed headings.
  Carries the heading, which is what later makes `Decisions` a node type for free.
- **dictation chunks** — one `DictationRun`, whole. Off by default; high volume, low signal.

Chunks overlap by one segment. Overlap costs storage and buys the case where the answer
straddles a boundary, which is most of them.

### Schema

One file: `~/Library/Application Support/Next Notes/knowledge.sqlite`. Separate from the
meeting folders on purpose — a corrupt index must never be able to take a transcript with
it, and `rm knowledge.sqlite` must be a complete, safe repair.

```sql
CREATE TABLE chunk (
  id           INTEGER PRIMARY KEY,
  source_kind  TEXT NOT NULL,        -- 'transcript' | 'notes' | 'dictation'
  source_id    TEXT NOT NULL,        -- meeting UUID, or dictation run UUID
  generation   INTEGER NOT NULL,     -- bumped when the source is rewritten
  ordinal      INTEGER NOT NULL,     -- position within the source
  text         TEXT NOT NULL,
  start_time   REAL,                 -- seconds into the recording, transcript only
  end_time     REAL,
  speaker      TEXT,
  heading      TEXT,                 -- 'Decisions', 'Action items', ... notes only
  occurred_at  INTEGER NOT NULL,     -- meeting start + start_time, unix seconds
  UNIQUE (source_kind, source_id, generation, ordinal)
);

CREATE INDEX chunk_source ON chunk(source_kind, source_id, generation);
CREATE INDEX chunk_time   ON chunk(occurred_at);

CREATE VIRTUAL TABLE chunk_fts USING fts5(
  text,
  content='chunk',
  content_rowid='id',
  tokenize='porter unicode61'
);

CREATE TABLE embedding (
  chunk_id INTEGER PRIMARY KEY REFERENCES chunk(id) ON DELETE CASCADE,
  model    TEXT NOT NULL,           -- 'embeddinggemma-300m@256' etc
  dims     INTEGER NOT NULL,
  vector   BLOB NOT NULL            -- dims * 4 bytes, little-endian float32, L2-normalised
);

CREATE TABLE index_state (
  source_kind TEXT NOT NULL,
  source_id   TEXT NOT NULL,
  generation  INTEGER NOT NULL,
  indexed_at  INTEGER NOT NULL,
  embedded    INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (source_kind, source_id)
);
```

Two things about that schema that look like bugs and are not, both confirmed by running it
against system sqlite 3.45.3:

- **`ON DELETE CASCADE` does nothing unless `PRAGMA foreign_keys = ON` is set on every
  connection.** SQLite defaults it off, and it is per-connection, not per-database. Without
  it, deleting a chunk silently orphans its embedding row and searches start returning
  vectors for text that no longer exists.
- **An external-content FTS5 table (`content='chunk'`) is not maintained for you.** Inserts,
  updates and deletes on `chunk` must be mirrored into `chunk_fts` — by triggers, or by doing
  both writes inside the same transaction. A missed mirror is invisible: the row is
  searchable by SQL and not by search.

`generation` is the whole idempotency story. **Regenerate** rewrites `notes.md`; diarization
rewrites `transcript.json` with new speakers. Both bump the generation, both insert a fresh
set of chunks in one transaction, and the previous generation's rows are deleted in the same
transaction. There is never a moment where a search can see two generations of the same
meeting, and a crash mid-write leaves the old generation intact.

Deleting a meeting deletes its chunks. Today deletion is `rm -rf` of a directory; it has to
also delete by `source_id`, or the index confidently cites a meeting that no longer exists.

### Why SQLite and not a vector database

Verified on this machine: the system `sqlite3` is 3.45.3 with `ENABLE_FTS5` compiled in, and
`SQLITE_OMIT_LOAD_EXTENSION` is absent. `libsqlite3` is already linked — `WisprReader.swift`
opens Wispr Flow's database read-only through it. So FTS5 costs nothing: no dependency, no
binary to sign, no notarization surface, no Swift 6 concurrency wrapper.

The alternatives were considered and rejected. Reasons are at the end of this document.

### Search, before there are any vectors

FTS5 BM25 alone, ranked, with snippets. This is already a large improvement over substring
matching — it ranks, it stems, and it finds the passage rather than the meeting. Phase A
ships as a user-visible feature with no model download and no embeddings at all.

---

## B. Embeddings

### The framework is already here

`llama.xcframework` b10621 — already a `binaryTarget` in `Package.swift`, already signed
into the bundle — exposes the complete embedding API. From
`llama.framework/Versions/A/Headers/llama.h` in the installed app:

```c
LLAMA_POOLING_TYPE_MEAN = 1,  CLS = 2,  LAST = 3,  RANK = 4
llama_set_embeddings(struct llama_context * ctx, bool embeddings);
llama_encode(...);
llama_get_embeddings_seq(struct llama_context * ctx, llama_seq_id seq_id);
```

**No new dependency is needed to embed text.** `POOLING_TYPE_RANK` also means a cross-encoder
reranker is available through the same framework later, which is the single largest quality
lever in hybrid retrieval.

`NotesModelRuntime` is a decode loop and cannot be reused directly — embedding needs
`llama_set_embeddings(ctx, true)` and a pooling type set at context creation. `EmbeddingRuntime`
is a sibling actor with the same lifecycle shape: lazy load, idle unload, `LlamaBackend`
arbitration.

### Which model

Two tiers, the same pattern the notes provider already uses:

| | Disk | Resident | Runs on | Retrieval quality |
|---|---|---|---|---|
| `potion-retrieval-32M` (Model2Vec) | ~30 MB | ~30 MB | CPU, no forward pass | ~82% of `all-MiniLM-L6-v2` |
| **`EmbeddingGemma-300M` QAT** | ~200 MB | <200 MB | ANE (CoreML) or GPU (GGUF) | best open multilingual under 500M on MTEB |
| `Qwen3-Embedding-0.6B` | ~600 MB Q8 | ~600 MB | GPU | best of the three, most contention |

**Ship EmbeddingGemma-300M truncated to 256 dimensions.** It is Matryoshka-trained, so
768 → 256 costs little recall and cuts the index to a third. Potion is the instant-on path so
search works before any download completes — the same two-tier shape as Qwen vs Apple
Foundation Models for notes.

Do **not** build on Apple's `NaturalLanguage` embeddings. `NLEmbedding.sentenceEmbedding`
ranks lexical distractors above correct answers and scores negations above true paraphrases;
`NLContextualEmbedding` will not load outside an app bundle; and the Foundation Models
framework exposes no embedding API at all.

### The memory question is really a compute-unit question

The contended resource on an M3/16 GB is the **Metal GPU**, not RAM — which is exactly why
`LlamaBackend` exists to arbitrate it. Qwen3.5-4B Q4_K_M is 2.74 GB of weights plus a KV
cache that `ensureContext(promptTokens:maxTokens:)` sizes to the request. Adding a second
GPU tenant means queueing behind notes generation.

Three rules, use all three:

1. **Put the embedder on a different unit.** The Apple Neural Engine is separate silicon; a
   CoreML embedding model there costs no GPU memory and never queues behind Qwen. Potion runs
   on the CPU and costs nothing at all.
2. **Never hold both at once.** Embedding is a batch backfill, not an interactive path. The
   notes model already frees itself ten minutes after last use — that idle window is when the
   indexer runs. Sequential, not concurrent.
3. **Shrink the vectors, not only the model.** 37,000 chunks at 768 dims float32 is 115 MB
   resident; at 256 dims it is 38 MB.

### Budget, at 500 meetings

| | |
|---|---|
| Qwen3.5-4B Q4_K_M weights | 2.74 GB, only while generating |
| Qwen KV cache | sized per request, not per 32K |
| Parakeet CoreML + FluidAudio diarizer | already resident during meetings |
| EmbeddingGemma-300M QAT | <200 MB, only while indexing |
| Vector set, 37k chunks @ 256 dims | 38 MB |
| `knowledge.sqlite` incl. FTS5 | ~250 MB for 500 meetings of text |

Peak is never the sum: the notes model and the embedder are never loaded together.

### Brute force is the correct search

37,000 × 256 is 9.5M multiply-adds per query — one `cblas_sgemv` through Accelerate, under a
millisecond on an M3, and **exact**. ANN indexes exist because brute force gets slow, and it
does not get slow until roughly a million vectors. At one chunk per ninety seconds of speech
that is about 13,000 recorded meetings.

When that day comes, the upgrade is `sqlite-vec` — a single MIT-licensed C file compiled
into the target and registered with `sqlite3_auto_extension`. No server, no Python, same
schema, same file. Put search behind a protocol now so it drops in without a migration.

---

## Retrieval

Hybrid, always. Pure vector search underperforms badly on names, project codenames and
jargon — which is most of what meeting notes contain. Pure BM25 misses paraphrase, which is
most of how people ask questions.

1. FTS5 BM25, top 50.
2. Cosine over the vector set, top 50.
3. Fuse with reciprocal rank fusion, `k = 60`.
4. Optional rerank of the top 20 with a cross-encoder through `POOLING_TYPE_RANK`.
5. Filters applied as SQL, not post-hoc: date range, speaker, meeting, heading.

RRF is chosen over score normalisation because BM25 and cosine scores are not commensurable
and every attempt to make them so needs tuning per corpus.

---

## C. The graph

### An ontology file, not whatever the model felt like emitting

`Resources/knowledge-ontology.yaml` declares the node types, their fields, and the legal edge
types between them. Extraction validates against it and drops what does not fit. This is the
one idea worth taking from `sensein/meetgraph`, and it is what keeps an extracted graph from
turning to mush after a hundred meetings.

### Node types, and where each actually comes from

| Node | Source | Cost |
|---|---|---|
| **Meeting** | `meeting.json` | free, already a record |
| **Person** | `Meeting.attendees`, `speakerNames` | free once calendars are connected |
| **Decision** | notes heading `Decisions` | cheap, already a heading |
| **ActionItem** | notes heading `Action items`, with assignee + due | cheap |
| **OpenQuestion** | notes heading `Open questions` | cheap |
| **Artifact** | `Meeting.agentActions` — Docs, events, messages the agent made | free, links already recorded |
| **Topic** | LLM extraction + clustering | expensive, and where hallucinated nodes come from |

Five of seven are nearly free because the pipeline already produces them. **Topic is the only
speculative one and should be last.**

### Stop scraping markdown

`NotesGenerator` writes markdown under five fixed headings and everything downstream
re-parses it with string matching. Instead, emit JSON alongside the markdown using
llama.cpp's GBNF grammar support — the framework has it, the Swift wrapper does not expose it
yet. Constrained decoding turns "usually parseable" into "parses or the generation failed",
which is the difference between a graph and a pile of near-misses.

`notes.json` lands beside `notes.md` in the meeting folder, same generation counter.

### Bi-temporal edges

Every edge carries four timestamps:

```
observed_at   when the meeting that stated this happened
valid_from    when the fact became true
valid_to      when it stopped being true (null = still true)
source_chunk  the chunk this was extracted from
```

Decisions get reversed three weeks later. A graph that cannot represent "we decided X, then
un-decided it" will state the wrong thing with total confidence, which is worse than not
having a graph. This is the one idea worth taking from Graphiti/Zep; the frameworks
themselves are Python and server-shaped and are not adoptable here.

`source_chunk` on every edge is non-negotiable — it is what makes an answer citable, and what
lets a wrong edge be traced to the sentence that caused it.

### A new pipeline stage

`MeetingStatus` gains `.extracting`, between `.summarizing` and `.done`. It is persisted like
every other state, so a crash during extraction is visible as exactly that. At the measured
~13.7 tok/s on this hardware, one extraction pass over a 45-minute meeting is a few minutes
of background work — acceptable because it is queued, idempotent, and yields to recording.

---

## D. Entity resolution

**This is the layer that decides whether this is a second brain or a pile of duplicates**, it
is more work than the extraction, and it is where projects like this die.

"Serge", "serge.kadjo@…", "S.K." and "Speaker 2" must become one node.

1. **Block** on normalised name and email domain — cheap, kills 90% of the comparison space.
2. **Score** within blocks: string distance, email match, co-attendance, embedding similarity
   of the surrounding context.
3. **Voice.** `MeetingDiarizer` already gets a 256-float speaker embedding per turn from
   FluidAudio. That means an unnamed *Speaker 2* in one meeting can be linked by voice to a
   named person in another, offline. Almost nothing on the market does this locally, and it is
   the strongest edge type available here.
4. **LLM tiebreak** only for the ambiguous middle band, never for the confident ends.

Two hard requirements:

- **Never delete on merge.** A `merged_into` column, and the loser row stays. Un-merging must
  be a one-row update.
- **A visible merge UI.** It will be wrong sometimes, and a wrong merge that the user cannot
  see or undo is how trust in the whole feature ends.

---

## E. Ask

Reuse the agent machinery rather than building a second one. `AgentService` already plans with
graded tools and `WorkspaceToolRunner` already executes them; three new **read-class** tools
join the catalogue:

| Tool | Arguments |
|---|---|
| `search_knowledge` | query, date range, speaker, meeting, heading, limit |
| `expand_node` | node id, edge types, depth |
| `timeline` | entity id, date range |

Read-class means they run while the agent plans, behind *Let it look things up* — the same
gate that already governs `search_email` and `read_doc`. Nothing in this feature writes
anything, so nothing here needs an approval button.

The answer path: retrieve → rerank → stuff top-k with citations → generate. Every claim
carries a chunk id, and the UI resolves that to a meeting and a timestamp. `TranscriptView`
already positions by seconds, so "jump to where this was said" is a scroll, not a search.

**The binding constraint is latency, not retrieval.** Qwen3.5-4B's context caps a single pass
at roughly 20 chunks. Multi-hop questions — "what did we decide about the pricing model over
the last quarter" — need 2–4 iterative retrieval round-trips, which at 13.7 tok/s is 30–60
seconds. Design the UI for a job that streams and can be cancelled, not for a search field.

---

## F. The views

The graph is not one screen. It is four, they belong to different phases, and two of them do
not draw a graph at all. This was settled by building all four as working prototypes and
running each at 12, 45 and 180 meetings rather than by arguing about it:
`https://claude.ai/code/artifact/0ad9de12-74b7-4be8-8850-594ae6d8ad15`.

### Search first, graph as the filter rail — ships in Phase A

Results are the interface; node types are demoted to facets down a left rail, with counts.
This needs no graph, no embeddings and no extraction — FTS5 and the chunk table give you the
whole screen, and the facets light up later as extraction fills the node types in. **It is
the only one of the four that is useful with two meetings in the library**, which is the
situation this repo is actually in.

### Local graph, one hop at a time — Phase F

One focus node and its immediate neighbours; click any node to re-centre on it. The node
count on screen is bounded by one node's degree, not by the size of the library, so it reads
identically at 12 meetings and at 180.

Three interaction primitives, all conventional and all worth copying: hovering isolates a
neighbourhood while everything else alpha-blends into the background; clicking a node expands
its neighbours and clicking again collapses them; and a selection made in one view updates
the others instead of opening a new context.

### Person timeline — Phase F, the same deliverable

The same edges drawn against time instead of against each other: every meeting a person
attended, newest first, each with the decisions and action items it produced and the ones
that person owns marked.

A person's edges are almost always chronological. You want to know what someone has been
involved in *lately*, not their betweenness centrality — and a timeline answers that at a
glance where a force graph never does. It shares a data model and a selection with the local
graph, which is why the two are one piece of work rather than two.

### Decision thread — Phase C, once extraction exists

One decision followed across meetings, including the day it was reversed: superseded claims
struck through, each row carrying its meeting, its timestamp and who said it. This is the
bi-temporal model made visible, and it is the most distinctive screen in the plan precisely
because it needs `valid_from`/`valid_to` on an edge rather than a plain link.

### Global force graph — last, and optional

Every node on one canvas. Build it when everything above works and you want a launch
screenshot.

The prototype settles what the first draft of this document only asserted. At 12 meetings it
is legible and rather pleasant. At 180 it is a uniform hairball, because a force layout
optimises for edge length and not for whatever you were looking for. The published criticism
is exactly this — it is a topological map of your connections rather than an operational view
of your work, showing connections but not priority, status or recency — and its defenders do
not really disagree with that; they redirect to the local graph, which they describe as
almost magical. Both camps land in the same place: the global view is the one that fails.

Ship it only if it is how you move through the library. If it is a picture beside a search
field, leave it out.

### Layout, when one is needed

A SwiftUI `Canvas`. Use Fruchterman–Reingold rather than a hand-tuned spring model: the ideal
separation `k = sqrt(area / n)` normalises to the frame, so one implementation fills a 700pt
canvas at 40 nodes and at 700 with no per-view tuning. The prototype's first pass used a
charge-and-centering model instead and collapsed every graph into a small blob in the middle
of an empty canvas — that failure is the entire reason this paragraph exists.

Two details that make the large case tractable: skip repulsion beyond `6k` distance, where
the force is under 1/36 of nominal, and scale the iteration count down as nodes go up —
roughly 240 under 150 nodes, 80 over 400.

Note also: rAF-style animation pauses in a hidden pane. Verify layout by measuring rects, not
by screenshotting.

---

## Phases

| | Goal | Exit criteria | Estimate |
|---|---|---|---|
| **A** | Chunked SQLite index, FTS5, resumable backfill, search screen with facet rail | Search returns passages with timestamps; `rm knowledge.sqlite` rebuilds cleanly; deleting a meeting removes its chunks | 2–3 weeks |
| **B** | `EmbeddingRuntime`, potion + EmbeddingGemma, hybrid RRF | Gold set recall@10 beats Phase A by a measured margin; peak RSS unchanged during meetings | 1–2 weeks |
| **C** | GBNF-constrained `notes.json`, ontology, `.extracting` stage, Person/Meeting/Decision/Action nodes, decision thread screen | 100 meetings extract with zero schema violations; re-extraction is idempotent | 2–3 weeks |
| **D** | Entity resolution, voice-print linking, merge UI | Precision on a hand-labelled person set above 0.95; every merge reversible | 3–4 weeks |
| **E** | `search_knowledge` / `expand_node` / `timeline`, cited answers | Every claim resolves to a chunk and a timestamp | 2–3 weeks |
| **F** | Local graph and person timeline, as one deliverable | Both read the same at 12 meetings and at 180 | 1–2 weeks |
| **G** | Global force graph — optional | It is how you move through the library, or it does not ship | 1 week |

**A + B + E is 5–8 weeks and delivers most of the felt value** — ask your notes anything, get
a cited answer. C + D is the expensive half and the half that can be confidently wrong.

Do A now. It improves today's search on its own and is pure infrastructure. Get meeting
capture actually working so a corpus accumulates. Revisit C and D at 100 meetings.

---

## Where the code goes

```text
Sources/NextNotes/Knowledge/
  KnowledgeStore.swift      the sqlite handle, schema, migrations, transactions
  Chunker.swift             transcript/notes/dictation -> [Chunk]
  KnowledgeIndexer.swift    the background queue; yields to recording
  EmbeddingRuntime.swift    actor, llama_set_embeddings + pooling, idle unload
  StaticEmbedder.swift      potion-retrieval-32M lookup + pooling, CPU
  HybridSearch.swift        BM25 + cosine + RRF + filters
  Extractor.swift           GBNF-constrained notes.json -> typed rows
  Ontology.swift            loads and validates against knowledge-ontology.yaml
  GraphStore.swift          nodes, bi-temporal edges, traversal
  EntityResolver.swift      blocking, scoring, voice-print, merge/unmerge
  KnowledgeTools.swift      the three read-class agent tools

Sources/NextNotes/UI/Knowledge/
  AskView.swift             the question field, streaming answer, citation chips
  KnowledgeSearchView.swift facet rail + ranked passages, jump-to-timestamp
  LocalGraphView.swift      one focus node and its neighbours, click to re-centre
  PersonTimelineView.swift  one person's meetings against time
  DecisionThreadView.swift  one decision across meetings, superseded rows struck
  GlobalGraphView.swift     every node on one canvas; optional, built last
  ForceLayout.swift         Fruchterman-Reingold, shared by both graph views
  MergePeopleSheet.swift    resolution review and undo

Resources/knowledge-ontology.yaml
```

## Self-tests

Every subsystem gets a `--selftest-…` flag; it is the convention, and for this feature it is
usually the only verification available. They live in `NextNotesApp.runRequestedSelfTest`.

| Flag | Answers |
|---|---|
| `--selftest-embed <text>` | does the runtime load, embed, and return a unit vector of the right dimension |
| `--selftest-index` | build the index from the meeting folders; report chunks, bytes, wall time |
| `--selftest-search <query>` | BM25, cosine and fused rankings side by side |
| `--selftest-extract <meeting-uuid>` | notes.json against the ontology; report violations |
| `--selftest-resolve` | resolution decisions on the current library with scores |
| `--selftest-ask <question>` | the full loop, printing every retrieved chunk and its citation |

Build with `make build`, never a bare `swift build`; `make test` for the vectors.

## Settings and model store

New keys in `Settings.Keys`, defaulting off:

```
knowledgeIndexEnabled       Bool    false
knowledgeEmbedder           String  "none" | "potion" | "embeddinggemma"
knowledgeIncludeDictation   Bool    false
knowledgeGraphEnabled       Bool    false
knowledgeAgentToolsEnabled  Bool    false
```

`LocalModelStore` gains `prepareEmbeddingModel()` alongside `prepareParakeet()`,
`prepareS1Mini()`, `prepareNotesModel()` and `prepareDiarizer()` — pinned URL, pinned
SHA-256, user-initiated, cancellable, with the licence shown. Weights never enter the repo.

---

## Risks

**Extraction produces confident nonsense.** A 4B model will invent an action item nobody
assigned. Mitigations: constrained decoding, ontology validation, `source_chunk` on every
row so any node can be traced to the sentence that caused it, and a UI that shows extracted
items as *proposals* in the same visual language the agent already uses for its own.

**The index and the meeting folders drift.** Answered by generation counters and by the rule
that the index is disposable. A "rebuild index" button is a feature, not an admission.

**Resolution merges two different people.** Answered by `merged_into` rather than deletion, a
conservative threshold, and a review sheet.

**Indexing competes with a live recording.** The indexer must check `MeetingStore` for an
active meeting and suspend. Transcription latency during a meeting is the one thing that must
never regress for a background feature.

**Privacy.** The graph is the single most sensitive artifact this app will ever produce — it
is the distilled version of every conversation. It stays local. The "Claude cleanup/command
provider" already listed in *Not built yet* is exactly the seam through which this could leak,
and the graph must never be in scope for it without an explicit, separate, per-feature
consent.

**Disk.** ~10 GB free on this machine, of which Qwen already holds 2.74 GB. EmbeddingGemma at
200 MB is affordable; Qwen3-Embedding-0.6B at 600 MB is the reason it was not chosen.

## Evaluation

Without a gold set you cannot tell whether a retrieval change helped, and every change will
feel like it helped.

Build ~50 questions with known answers against the real library, in the shape of
`CleanupEvalCases.swift`: question, the chunk ids that contain the answer, and the expected
claim. Report recall@10 and MRR for retrieval, and answer-contains-claim for the full loop.
Run it from `--selftest-ask`. Fifty cases is enough to catch a regression and small enough to
actually write.

---

## Alternatives, and why not

**FAISS.** C++ with no maintained Swift binding — another binary to vendor, sign and keep
hardened-runtime-clean. Stores only vectors: `write_index` to a flat file, no metadata, no
filtering, no transactions. SQLite would still be needed beside it, and two files can then
disagree after a crash mid-write. Its whole value is approximate search, which does not turn
on until ~1M vectors.

**ChromaDB.** A Python library. Shipping it means bundling a Python runtime and its wheels
(including `onnxruntime`) inside the `.app`, signing every dylib and notarizing the lot — or
running a localhost server.

**Qdrant.** A Rust server with no in-process embedded mode. Docker or a supervised sidecar, a
listening port, a second process lifecycle. For a single-user menu-bar app this is the largest
possible version of the smallest possible problem.

Two of those three break a sentence the README currently gets to say: *the app does not depend
on Homebrew, Ollama, a local server, or any network request at inference.* There is also a
signing tax — per the migration notes, the code-signing identity had to be hand-built with
`openssl`, and TCC grants break when the designated requirement changes. Every embedded binary
is more surface that can invalidate a grant that was painful to obtain.

**LanceDB.** Genuinely good embedded columnar vector store with disk-based IVF-PQ, and the
right answer past 10M vectors. Rust, with no Swift story.

**Apple `NaturalLanguage` embeddings.** Covered above: quality and bundle-loading problems.

**Graphiti / Zep / Cognee / mem0 / LightRAG.** All Python, all server-shaped. Take
bi-temporal edges from Graphiti and leave the rest. Treat published comparisons carefully —
Cognee's benchmark ran tuned configurations against everyone else's defaults.

**Existing open-source meeting-graph projects.** `sensein/meetgraph` (3 stars, Python/PyQt6,
RDF via Oxigraph) is the literal match and is worth reading for its ontology idea only.
`fastofiCorp/ofi-meeting` is a 1-star Meetily fork on ChromaDB. `Zackriya-Solutions/meetily`
is the closest architectural competitor and is Rust + Python FastAPI + an Ollama sidecar.
`Hyprnote` is the serious one — and is **GPL-3.0**, so it can be read for ideas and its code
cannot be copied into this app. None of them has shipped the graph half well.

---

## Verified, and assumed

**Verified on this machine, 2026-09-10:**

- System `sqlite3` is 3.45.3 with `ENABLE_FTS5`; `SQLITE_OMIT_LOAD_EXTENSION` absent.
- `llama.framework` b10621 in the installed app exposes `LLAMA_POOLING_TYPE_MEAN`/`CLS`/`LAST`/
  `RANK`, `llama_set_embeddings`, `llama_encode` and `llama_get_embeddings_seq`.
- The library holds 2 meetings and 62 dictation runs; both meetings have no attendees.
- The schema above executes against that sqlite: BM25 ranking through the join works, the
  cascade delete works, `PRAGMA integrity_check` passes.
- A global force graph is legible at 12 meetings and a hairball at 180, and a one-hop local
  graph is unchanged between the two. Measured in the prototype, on synthetic data.

**Assumed, and to be measured before it is believed:**

- EmbeddingGemma-300M's quality on meeting transcripts specifically. Published MTEB numbers
  are not this corpus.
- ~1ms brute-force search at 37k × 256. Arithmetic, not a measurement.
- The chunk-count projection (one chunk per ~90 seconds of speech) — derived from two
  meetings, which is not a sample.
- That the ANE path is meaningfully cheaper than the GPU path here. Worth a `--selftest-embed`
  comparison before committing to CoreML conversion.
- Extraction cost per meeting at 13.7 tok/s. Measured for notes generation, extrapolated for
  extraction.
- That the prototype's degradation curve matches a real library's. The synthetic corpus
  assumes an attendee-overlap rate nobody has measured, and overlap is what decides whether
  a real graph is a hairball or several loosely joined islands. Unknowable until calendars
  are connected.

## References

- sqlite-vec — https://github.com/asg017/sqlite-vec
- Model2Vec — https://github.com/MinishLab/model2vec
- potion-retrieval-32M — https://huggingface.co/minishlab/potion-retrieval-32M
- EmbeddingGemma — https://huggingface.co/google/embeddinggemma-300m
- swift-embeddings (fallback runtime) — https://github.com/jkrukowski/swift-embeddings
- meetgraph (ontology idea) — https://github.com/sensein/meetgraph
- Meetily — https://github.com/Zackriya-Solutions/meetily
- Hyprnote (GPL-3.0) — https://github.com/bahodirr/hyprnote
- Obsidian graph view — https://help.obsidian.md/plugins/graph
- The case against it — https://codeculture.store/blogs/developer-culture/obsidian-graph-view-useful
- The case for local graphs — https://pjordan.substack.com/p/a-pkm-revelation-obsidian-local-graphs
- Graph visualization UX — https://cambridge-intelligence.com/blog/designing-intuitive-data-experiences-with-graph-visualizations/
- The four views, as working prototypes —
  https://claude.ai/code/artifact/0ad9de12-74b7-4be8-8850-594ae6d8ad15
