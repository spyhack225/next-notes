# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What we optimize for

**Efficiency, speed and full-duplex conversation come first.** The app has to feel fluent and
fully interactive — a hold answers at key-down, a voice turn listens while it speaks, a long
job shows its state instead of a still screen. A change is judged by that bar before it is
judged by elegance: does it make the app faster or slower, more alive or more still, one step
simpler or one step more complex?

**Do not architect ahead of a need.** A second store, ledger, queue, channel or abstraction is
the expensive kind of complexity because nothing fails when it is added — it just makes every
later change slower to make and slower to run. The single-ledger, single-audio-channel,
single-tool-manifest, single-usage-log paragraph below is this rule with the receipts. Prefer
the existing seam and the smaller diff; when a task really needs a new layer, say why in the
commit.

**Never make the app feel slow or clumsy.** Concretely:
- Anything the user is waiting on streams or shows what is happening; an indefinite spinner
  over a minute-long model pass is not a design.
- Do not add a sequential await, a fixed sleep, a debounce or a second confirmation to a path
  the user's turn sits on. An approval for an irreversible action is the one confirmation that
  earns its place — everything else belongs off the path.
- Full duplex means the microphone, the model and the speaker overlap. A new gate, lock or
  policy that serialises them is a regression even when it reads as safer.
- The latency numbers the AGENT-OVERHAUL latency phase measures are features, not benchmarks.

**Confidence, control and safety — without slowness, over-engineering or complexity.** The
permission model already in this file is the shape: a read runs itself because it is invisible
to everyone else, an irreversible write waits for one approval, and the card shows exactly what
will happen before it does. That is what "in control" means. A switch for every choice, or
ceremony that delays an action the user already asked for, is the failure mode this line exists
to prevent: safety lives at the irreversible boundary, never in the path of everything.

**Dumb simple, and never nerd-shaped.** The user is not an engineer and no interaction may
require one. No screen, card, error or setting tells a person to get an API key, open Terminal,
run a command, edit a config file or paste a model id when the app can do it for them; the
default path needs no account, no key and no terminal. An advanced route may exist, but it is
opt-in and never the first thing asked. Copy is what a non-technical person would say out loud —
no jargon, no raw tool ids, no schema keys, nothing that reads as insider. When a technical step
is genuinely unavoidable (a provider the person chose, a grant only they can give), it is one
plain action at a time, with the reason and the exact next click. `--selftest-ui-strings` and
`PersonaCareEval` are the floor, not the goal; if a flow needs a diagram, it is not done.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio | Parakeet via sherpa-onnx |
| Location | repo root | `windows/` |

**The macOS app works and is in daily use.**

The macOS app is no longer only dictation, and the second half of it is younger and far
less exercised than the first. It reads the calendar (EventKit and, optionally, the Google
Calendar API), arms and records a meeting on its own, captures the microphone and a Core
Audio process tap as two separate tracks, transcribes both with Parakeet, tells the
speakers on the system track apart, writes notes with a local Gemma 4 E4B (or Apple
Foundation Models), and — when it is switched on — proposes follow-up actions in Gmail,
Calendar, Drive and Docs through Google's `gws` CLI, which a person approves one at a time.
Its status shows in a card at the notch. None of that exists on Windows and none of it is
in scope there.

Where the code lives: `Calendar/`, `Meetings/`, `Agent/`, `Formatting/LLM/`, `UI/Island/`,
one section per `UI/<Section>/`, one Settings tab per file in `UI/Settings/`. The tree in
`README.md` is kept current and is the map.

Every subsystem has a `--selftest-…` flag, and adding one for new work is the convention
rather than a courtesy — most of this app needs a permission, a model or an account that a
coding agent cannot obtain, so a flag that answers one question from a terminal is usually
the only verification available. They live in `NextNotesApp.runRequestedSelfTest` and each
prints one `<NAME>_OK` / `<NAME>_FAILED` line last:

```
--selftest-s1        --selftest-parakeet   --selftest-systemaudio
--selftest-transcribe <wav>                --selftest-calendar
--selftest-notes <wav> [--diarize]         --selftest-notes-context
--selftest-llm-metal
--selftest-island    --selftest-orb        --selftest-gws
--selftest-agent <meeting-dir>             --selftest-cleanup [engine]
--selftest-dictation --selftest-calls      --selftest-axreadback
--selftest-dictation-hygiene
--selftest-learn     --selftest-context [bundle-id]
--selftest-tools     --selftest-wake       --selftest-tasks
--selftest-persona   --selftest-memory     --selftest-schedule
--selftest-routine-authority
--selftest-index     --selftest-search [query] [--gold <path>]
--selftest-ask [question]                  --selftest-extract [notes.json]
--selftest-resolve [knowledge.sqlite]
--selftest-graph-layout
--selftest-embed [text] [--model potion|embeddinggemma]
--selftest-memory-review [--model local|cloud] [--fixtures <path>]
--selftest-meeting-context                 --selftest-realtime
--selftest-computer  --selftest-mcp        --selftest-composio
--selftest-acp
--selftest-activity  --selftest-fs         --selftest-browser
--selftest-settings  --selftest-metrics    --selftest-cleanup-router
--selftest-meeting-live --selftest-meeting-live-tools --selftest-meeting-quality --selftest-tts
--selftest-notes-longform --selftest-notes-truncation
--selftest-diarize-assign --selftest-diarize-hints
--selftest-meeting-finals [<dir>]
--selftest-meeting-resume --selftest-meeting-backlog --selftest-audio-retention
--selftest-meeting-tap-retry
--selftest-meeting-scratchpad --selftest-meeting-tidier
--selftest-meeting-recall --selftest-meeting-console
--selftest-tts-stream
--selftest-tts-pocket
--selftest-tts-kokoro
--selftest-local-model-stream
--selftest-openrouter-contract --selftest-openrouter
--selftest-openrouter-speed
--selftest-toolloop  --selftest-acp-confirm --selftest-scheduler
--selftest-toolloop-production
--selftest-voice-grounding
--selftest-voice-conversation --selftest-voice-local
--selftest-voice-turns --selftest-voice-work-lifecycle --selftest-voice-delivery
--selftest-playback-ledger --selftest-voice-scheduling
--selftest-concurrent-voice --selftest-voice-frontend --selftest-voice-eou <wav>
--selftest-acoustic-replay --selftest-acoustic-speech <far-wav> <near-wav>
--selftest-acoustic-live [apple|selected]
--selftest-acoustic-aec3-speech <far-wav> <near-wav> --acoustic-aec3
--selftest-voice-pipeline <wav> --selftest-voice-barge <wav>
--selftest-voice-echo-live --selftest-pcm-reconfiguration
--selftest-voice-rapid <first-wav> <second-wav>
--selftest-voice-suspend --selftest-voice-suspend-live
--selftest-tts-pocket-session
--selftest-tool-awareness
--selftest-capture   --selftest-microphone --selftest-meeting-reconcile
--selftest-meeting-reconcile-llm
--selftest-stream    --selftest-transcript-bus
--selftest-duplex    --selftest-contention
--selftest-imessage-db
--selftest-imessage-decode
--selftest-imessage-watch  --selftest-imessage-class
--selftest-imessage-loop
--selftest-residency
--selftest-cleanup-structure               --selftest-commandkey
--selftest-tool-review                     --selftest-function-calls [engine-dir]
--selftest-skills    --selftest-file-index --selftest-onboarding
--selftest-avatar
--selftest-model-roles --selftest-model-fit --selftest-hf-search
--selftest-model-unopenable --selftest-private-network --selftest-store-isolation
--selftest-chat-template
--selftest-llm-prefix-cache
--selftest-usage-log
--selftest-memory-portability
--selftest-voice-turn-routing --selftest-wake-live
--selftest-computer-actions  --selftest-click-coordinate --selftest-cdp
--selftest-computer-vision    --selftest-seat-grid
--selftest-digest             --selftest-podcast
--selftest-guided             --selftest-ui-strings
--selftest-agent-panes
--selftest-agent-answers
--selftest-assemble           --selftest-portrait
--selftest-toolloop-live [--model apple|<id>] [--only C01,M05] [--quick] [--report <path>]
--selftest-toolloop-live-grader
--selftest-capability-manifest
--selftest-native-tools
--selftest-now-block
```

`usage.jsonl` is the one local record of which model or engine ran each pass — Agent,
Meetings and Dictation — with its provider, model, locality, timing, counts, tools and
outcome (P0-20a–e). It never leaves this Mac: nothing uploads it, no network call touches
it, and no row holds a prompt, reply, reasoning, transcript, dictated text, tool argument,
file name, address, subject or URL (`UsageLog.sanitise` strips quoted content, addresses,
URLs, paths and long digit runs from an error message before it is written). Read it with
`--usage-report [--usage-days N] [--usage-feature <prefix>]`, a read-only diagnostic rather
than a `--selftest-*` flag because the harness swaps in an empty temp store — the same trap
`--notes-context-live` documents. `--selftest-usage-log` pins the isolation: under the
harness `UsageLog.shared` writes to `NextNotesSelfTest-<pid>` in the temporary directory,
so no run can append to the owner's history, and `--selftest-store-isolation` watches the
real `usage.jsonl` beside the other stores. It rotates at 8 MB to `usage.1.jsonl` (about
two files, ~16 MB) and drops rows older than 90 days from the rotated file at launch.

`--selftest-toolloop-live` is the one number that says whether the Agent got better at using
tools: 30 canonical requests through the real `RealtimeAgent.handle(_, source: .text)` on
the model the Agent role resolves to, with every `AgentToolExecutor.run` answered by a
fixture — no mail is read, nothing is sent, no approval card appears, and the run fails if
the owner's conversation, tasks, audit log, memory or `library.json` changed. It prints one
`TOOLLOOP_LIVE_CASE` line per case, a class tally, `TOOLLOOP_LIVE_SCORE n/30`, a markdown
report plus a `.jsonl` sidecar (`--report <path>`; by default
`~/Library/Caches/NextNotesBuild/toolloop-live/`), then exactly one final marker. No model
resolves → `TOOLLOOP_LIVE_ABSENT` (never OK). `--quick` is a fixed 10-case subset (never
edited to make a gate pass, target ≤ 20 min, 3,300 s budget) and is the per-task gate for
every Phase 1 and Phase 4 task; the full run is the phase gate (two consecutive runs, 12,300 s
budget, about 3.5 h). The grader is pure and pinned without a model by
`--selftest-toolloop-live-grader`, which fails if any single verdict branch stops matching.
`--allow-cloud` is off by default: the eval is local, and a cloud run sends fixture text off
the Mac.

**A full run also executes the owner's ten, and they are not in the score.** `O01`–`O10` are
the requests that actually failed on this Mac — the two-turn "summarise my emails" → "is this
coming from my emails?" that produced three invented emails, an agenda for the wrong day, a
clock three and a half hours out. They are `scored: false`, so `TOOLLOOP_LIVE_SCORE` and the
pass bar still count the thirty and appending them moved no threshold; they are printed on
their own line, `TOOLLOOP_LIVE_OWNER n/10`, and gated by the **Phase 1 exit** in
`STATUS.md` rather than by the flag. `--only O07` is therefore a diagnostic that passes on
its own words (`TOOLLOOP_LIVE_OK: no scored case in this selection`) because a run with no
score must not print a green that means nothing. Two rules keep the set honest: it adds **no
rows** to the eval's mailbox or calendar (a corpus fitted to these turns would make the gate a
description of the fixtures), and it introduces **no new verdict class** — `O01`'s invented
list is caught by `MISSED_TOOL`, which is the honest reading of "answered as though something
was read" and is not `FABRICATED`, because `"i pulled"` is not on `ToolClaimGuard`'s list and a
list that makes no claim at all is invisible to any claim grammar.

One flag in that list's shape but not its kind: `--wake-mic-record [count]` is interactive,
so it is a modifier rather than a `--selftest-*` test — it records real-room "Hey Will"
captures into the `WakeWord/LiveFixtures` overlay that `--selftest-wake-live` grades
(`0` is a dry run that prints the directory and touches no microphone).

A second modifier, added with P1-09: `--selftest-gws --live-mail` runs one real
`search_email` against the signed-in account and prints
`GWS_LIVE_MAIL: <n> messages, <n> senders parsed, <n> subjects parsed, <s>s`. It is a read, and
it prints **counts and a duration only** — never a sender, a subject or a snippet, because
this line lands in a log file. `--selftest-gws` itself needs nothing to be useful: its
fixture half runs first, needs no binary, no keyring, no account and no model, and prints
`GWS_FIXTURES_OK` before the binary half's lines; the final `GWS_OK` is printed only when both
halves passed. Those fixtures are written in the JSON shapes `gws` actually returned on
2026-09-26, which is why the sender is read from `payload.headers[]` and from `+read`'s
`{"name","email"}` address object and not from a top-level `from` — the shape the old reader
looked for is one neither command prints, which is where "from unknown sender" on 5 of 5 audit
rows came from. `messages get --format metadata` is 601 bytes for the same message that
`format: full` answers in 71,698, and the difference is the whole body, so a search reads
metadata and there is no snippet: Gmail only sends one with the body attached.

`--selftest-avatar` is the 2026-09-23 addition, and it has a companion diagnostic rather than
a self-test: `--avatar-sheet [path]` renders all ten character states at three instants into
one PNG with `ImageRenderer`, which needs no Screen Recording grant — so the vocabulary can
be reviewed by eye on a machine where the real UI cannot be screenshotted. The self-test
pins what an eye cannot check twice: a generated face round-trips through
`agent-identity.json`, the four animation layers rasterise, no two of the ten states ever
share a pose, every activity and every tool lands on the state it should, and the island
wears the character for the agent's own states and the orb for everything else.

`--settings-sheet [dir] [--width <pt>]` is the same kind of companion for the Settings
layout, and it exists for the same reason: the embedded pane's width behaviour can only be
judged by looking at it. It does not use `ImageRenderer` — a native grouped `Form` draws
nothing into an `ImageRenderer` pass, and the first version of the flag produced a blank
page under the header band — so it hosts each pane in an offscreen panel and `cacheDisplay`s
that. Every pane is written at `settingsPaneMinWidth`, `settingsWidth` and twice
`settingsWidth` by default, and `--width` narrows it to one width while iterating.

The last three lines were added on 2026-09-22 (the earlier five on 2026-09-19). Three of them
reach the network and say so when it is missing rather than passing quietly:
`--selftest-skills` searches skills.sh and installs one real skill from GitHub into a temp
folder, `--selftest-hf-search` fetches a 3.9 MB file from the Hugging Face Hub and resumes it
from a real `206` (and, since 2026-09-23, reads `ggml-org/gemma-4-E4B-it-GGUF` and fails if the
file picker would choose its `mtp-` draft head over the weights), and `--selftest-model-roles`
starts its own loopback fixture server.
`--selftest-function-calls` takes an optional directory holding `needle3-macos-arm64` and
`needle3.cact`; without it the run prints `FUNCTION_CALLS_NEEDLE_ABSENT` and grades only the
fallback, and it still fails if no *model* — Needle or the local one — produced a single call,
or if the resident `--serve` engine answered none of the turns.

The 2026-09-22 flags: `--selftest-voice-turn-routing` replays the five-turn
email/calendar refusal loop (the pending-intent slot, the pre-frontend tool-shape gate and
the denial cap) against a fake voice frontend; `--selftest-wake-live` plays a fixture set of
24 "Hey Will" clips and 32 adversarial near-misses through the real spotter and prints
`WAKE_HIT_RATE` — **it is still red at the shipped sensitivity (17/24 = 0.71, 3/32 false
after the 2026-09-22 tuning pass)**, and that is the honest measurement: the tuning pass
ran a 270-config sweep through the real spotter and took the measured trade-surface
maximum (variant depth 2→4, threshold slope 0.36→0.30, beam plateau 24→16 — a phrase
bonus that would buy the missing hits costs 12–18 false accepts, measured and refused),
and the remaining fix is real-room recordings (`WAKE_MIC` has no captures on this
machine — `--wake-mic-record` now records them), not a lowered bar.
`--selftest-computer-vision` and `--selftest-seat-grid` pin the screenshot policy (stub-tree gating, consent failing closed,
the one-retry rule, and the D5 seat-grid chain); `--selftest-digest` and `--selftest-podcast`
pin the two scheduled content routines (reads-only, silence token, consumer words, file-sink
only, never auto-played); `--selftest-guided` is the D9 first-success script (calendar →
names → proposal → approval → executed → one follow-up); `--selftest-ui-strings` scans
`UI/` user-visible strings for banned developer words (`cron`, `artifact`, raw tool ids,
schema keys) and fails per offender.

The computer/browser-use flags (also 2026-09-22, from the COMPUTER-BROWSER-USE roadmap, now in
`roadmap/done/`):
`--selftest-computer-actions` drives its own harness window — scroll both ways with the
visible range as ground truth, a double click's selection, a `wait_for` that must find
static text and one that must time out honestly, with drag and right-click posted but
required to admit they could not be verified. It walks its own window by title rather than
`kAXFocusedWindow`, because an agent-launched instance is refused activation outright
(measured: `isActive false, keyWindow false` even after `activate()` and the
`kAXFrontmostAttribute` raise), so **it is currently red on a locked screen and will pass
the first time it runs on an unlocked one** — that is the environment answer, not a green
lie. `--selftest-click-coordinate` pins the pixel-fallback contract with no model and no
foreground: the fraction grammar refuses out-of-range and missing values, the element id
outranks coordinates, and `VisionHandoff`'s `target:` parser holds against canned
completions; the one live case degrades to `CLICK_COORDINATE_UNVERIFIED` rather than a
claim. `--selftest-cdp` needs no grant at all: it launches headless Chrome itself against a
fixture file and drives the real client end to end, prints `CDP_ABSENT` when no
Chromium-family browser is installed, and its first live run caught the real bug that CDP
commands went out as binary websocket frames — real Chrome tears the socket down on those,
which is why `--selftest-browser`'s Python fixture had never seen the failure.

The competitor-gap finalization flags (2026-09-22, from the AGENT-COMPETITOR-GAP roadmap,
now in `roadmap/done/`): `--selftest-assemble` drives the D4 trip assembly end to end over
a fixture corpus and fails unless ≥3 distinct sources are cited, the markdown page exists
on disk with its source list and 3–5 outstanding items, and the artifact ledger records the
run; its degraded path (no model) must still write the page and say it was written without
a model pass. `--selftest-portrait` pins the Portrait contract — the graph pass produces
drafts, nothing saves unreviewed, keep/discard/cross-out work per insight, and an absent
graph answers honestly. The first-ingestion consent gate has no card-bearing self-test yet
(the gate deliberately skips under the harness); its honest failure mode — no consent path,
no ingestion — is enforced in `AgentToolExecutor`'s workspace read case.

`--selftest-imessage-db` is the one self-test in the tree that reads a database format it does not
own, and it is the shape to copy for the rest of the iMessage work. It answers against
`Tests/Fixtures/chatdb/`, which is **generated at run time** by `make-chatdb-fixture.sh` — no
`.sqlite` is committed, every case is sanitised placeholder text, and the whole thing needs no
Messages grant, no real database and no model, which is why it is not a `via-open` entry. Its
load-bearing assertion is the one that is easiest to get wrong: `PRAGMA query_only` is **set** by
the code and **read back by a second connection**, so a reader that quietly forgot it fails. When
it was first written that assertion was checked by mutation — the pragma was deliberately broken and
the run reported `IMESSAGE_DB_WRONG: a second connection read 0, not 1` — which is the only way to
know a self-test can fail at all. Every case carries the same rule for the same reason: the
`--degraded` variants genuinely **remove** `attributedBody` and `payload_data` from the schema, so
the capability probe is exercised against a database that really lacks the column rather than
against one with a null value in it.

**An undecodable message must never be able to read as a blank one**, and that is a type-level
promise rather than a convention. `IMessageEnvelope.text` is a computed `String?` over a `MessageBody`
that has **no empty-string case**, so there is no expression in the type that spells `""`, and a
decoded zero-length stream is mapped to `.absent`. `--selftest-imessage-decode` prints
`IMESSAGE_DECODE_BLOCKED:` lines for assertions that cannot run yet, and **deliberately does not
count them** in its `IMESSAGE_DECODE_OK: <n> cases` marker — so the number is a claim the run can
stand behind rather than a denominator that quietly absorbed five skips. The parser is hand-written
for a reason worth keeping: `NSUnarchiver` is the only system API that can read a typedstream, and it
has no throwing entry point, so an unfamiliar format version would raise an exception Swift cannot
catch and **exit the process inside the message read path**. A parser that returns plausible garbage is
strictly better, because degrading and saying so is the designed response to a format change.
`Sources/NextNotes/IMessage/Database/TYPEDSTREAM-NOTES.md` separates what was **measured** (Apple's
encoder, on this machine) from what is still **open** (what Messages writes), and writing the decoder
found seven errors in it — which is the argument for measuring rather than describing.

A self-test must **fail** when the thing it names did not happen. `--selftest-systemaudio`
reporting `SYSTEM_AUDIO_SILENT` on a zero peak, and the Metal probe failing on zero
generated tokens, are the shape to copy: on this machine most of these run without the
grant or the model they are really about, and a probe that passes anyway is worse than none.

**The Windows app is complete but has never run on real hardware.** Every layer exists;
CI builds it, runs 63 tests, publishes a single-file executable, launches it on Windows and
confirms the platform layer loads and constructs. What has never happened is a person
holding the key and speaking into a microphone. Describe it that way — not as "working",
not as "unfinished".

## Licence

AGPL-3.0-or-later (`LICENSE`). Every file you add here inherits it — no per-file header
is required, and none should be added unless the whole tree gets them. Before pulling in
a new dependency, check it is not GPL-incompatible and not source-available-but-not-open
(BSL, SSPL, Elastic, "free for non-commercial"): every current dependency is BSD, MIT,
Apache-2.0, ISC or OFL, and `THIRD-PARTY-NOTICES.md` is the inventory to update when that
changes. Models are downloaded at runtime, not distributed, and keep their own terms.

---

## The one rule that matters

**`shared/dictionary-test-vectors.json` is the specification for correction behaviour.**

Both implementations run it in CI. If you change how corrections work, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
make test                                          # macOS side, the vectors and nothing else
cd windows && dotnet test NextNotes.CrossPlatform.slnf # Windows side, runs anywhere
```

(`make test`, not a bare `swift test`, for the same scratch-path reason as `make build`
below.)

The Swift copy at `Tests/NextNotesDictionaryTests/dictionary-test-vectors.json` is a copy, and
CI fails if it drifts from `shared/`. After editing the shared file:

```bash
cp shared/dictionary-test-vectors.json Tests/NextNotesDictionaryTests/
```

The same copy rule applies to spoken-form scoring. After editing
`shared/spoken-forms-test-vectors.json`:

```bash
cp shared/spoken-forms-test-vectors.json Tests/NextNotesDictionaryTests/
```

---

## Things that look like bugs and are not

**Where a dictation goes is decided at key-down, not at insertion.** `TextInjector.Origin` and
`OutputProfileStore.captureTarget()` are both taken in `beginDictation`, and the reason is the
same for both: the tail between releasing the key and having text is seconds long — drain, then
transcribe, then up to four more for cleanup — and the user may switch apps inside it. Resolve
the target at insertion time and the text lands wherever they ended up, which in practice means
it vanishes: the AX write fails against the new app, the pasteboard fallback posts ⌘V at
something that cannot take it, and the previous clipboard is restored over the top 500 ms later.
That last step is why the symptom was "it disappeared" rather than "it went to the wrong place".

**Returning to that app needs two mechanisms, not one.** `NSRunningApplication.activate()` is
refused often enough to be useless alone, because macOS's cooperative activation resists a
*background* app raising another — and Next Notes is always background during a dictation, by
design, since the HUD is a non-activating panel so focus never leaves the user's field. The
fallback is `kAXFrontmostAttribute`, which answers to the Accessibility grant the app already
needs. Both are followed by polling: activation is asynchronous, and a ⌘V that arrives mid-raise
lands somewhere else.

**The dictionary learns from history, not from the app the text went to.** The obvious design
— watch the field after inserting and diff it — is unbuildable here, and
`--selftest-axreadback` is the measurement rather than the hunch: Cursor, Chrome, Terminal,
Messages, ChatGPT, Claude and WhatsApp expose zero text elements to the accessibility tree.
Only plain AppKit (Finder, System Settings) returns a readable value and range. Writing and
reading are different attributes and Chromium builds its tree lazily, so this had to be
measured before it could be relied on either way. Run that self-test before proposing any
feature that reads text back out of another app.

**A finished feature with no call site looks exactly like a working one.** `OutputProfileStore`,
`OutputProfile`, `OutputFormatInstructions` and the Formatting settings tab were all complete,
tested by eye, and connected to nothing: `captureTarget()` had no callers, so `capturedTarget`
was permanently nil, `capturedProfile` always resolved to plain, and every row in
`formatting.txt` did exactly as much as an empty file. Nothing failed, nothing logged, and the
settings UI wrote a file the pipeline never read. If you add a seam like
`OutputFormatInstructions` — a pure function with a written integration note and no caller —
grep for its callers before assuming the feature ships.

**There is one task ledger, one channel that starts audio, one tool manifest, and one usage log.**
Four plans have each proposed adding a fifth of one of these, and a second copy of any of them
fails silently rather than loudly. The single ledger is `TaskBridge` (`Agent/`, planned in
`roadmap/in-progress/AGENT-OVERHAUL/04-PHASE-3-FULL-DUPLEX.md` §2.5); `VoiceConversationCoordinator.jobs`
is being deleted and must not come back. The only thing that starts audio is `OutputScheduler`,
enforced by an `OutputToken` whose initializer is `fileprivate` to that file — so "no backend
independently decides to speak" is a compile error, not a convention. The per-turn tool authority
is `AgentCapabilityManifest` (`Agent/AgentCapabilityManifest.swift`). The usage log is `usage.jsonl`
(`Support/Usage/`), which already has 8 MB rotation, 90-day compaction, `UsageLog.sanitise` and
harness-temp isolation — **a job's token count is a sum over `UsageRecord`s carrying a task id,
never a second ledger.** Durable background work (`agent-jobs.sqlite`, a `TaskEvent` journal,
heartbeats, retry and crash recovery) extends `TaskBridge` rather than sitting beside it; see
`07-PHASE-6-DURABLE-JOBS.md`. Before you add a task type, a delivery path, a tool registry or a
metrics file, grep for the existing one and read what the executor above you concluded about it.

**A prompt rule is only a rule for the engines that read prompts.** Every grammar, list,
quotation and per-app formatting instruction lived in `CleanupInstructions.system` — and
`S1MiniFormatter` is a 0.6B punctuation normaliser that takes no instructions at all. With
`cleanupEngine = s1Mini` the whole instruction block was addressed to something that never
saw it, so "Format spoken lists" could not have had any effect no matter what the toggle
said, and the user's own history contains the typed sentence `Open a list.` — they said it,
and the app typed it. That is why structure now lives in `SpokenStructure`, a deterministic
stage on `CleanupRouter` that runs **before and after** the model: before, so the model is
handed rendered structure instead of instructions it can delete (Apple's model ate
`quote … end quote` markers when it saw them as text); after, so a model that flattens the
formatting back into prose loses to the pre-rendered version. Before adding a rule to a
prompt, check which engines can actually receive it.

**The Agent's name is never in a prompt — the user names it.** The name in
`agent-identity.json` reaches every speaking path through `AgentGrounding` ("You are
<name>."), so the persona preset and the fixed rules describe a role and never the app:
"You are a warm, personal agent on this Mac", "You are the meeting assistant", "You are
a conversational assistant". A hardcoded "You are Next Notes" would fight the name chosen in
onboarding and, on a fresh install, would be said twice. The same goes for the voice: the
first paragraph of `Resources/agent-persona-base.md` — duplicated in
`PersonaStore.builtInBaseText`, and the two must stay byte-identical — carries "no technical
detail or jargon" and "no filler or flattery" because the Apple voice path hears only that
card. `--selftest-persona` fails if the preset or any production prompt names the Agent, and
`PersonaCareEval` pins the plain-words and no-flattery rules into every user-facing path.

**The Related-context brief is deliberately absent from three places.** `NotesService`
assembles a `MeetingNotesBrief` — memory, prior decisions and the people/projects the graph
already ties to this meeting, passages from past meetings, file names — and hands it to
`NotesGenerator`; every source keeps its own switch and cloud consent, and `AgentService`
assembles its own for the agent's reader rather than reusing the notes model's, because a
brief allowed for a local reader is not allowed for a cloud one. The same brief reaches
`MeetingAgent`'s proposal pass, and its tool block now carries the knowledge index's three
read tools beside the Workspace ones: `search_knowledge` whenever the Agent's index switch is
on, `expand_node`/`timeline` only while the graph is on and the reader may see it — a cloud
reader without graph consent is never shown them, and the reader is bound around execution so
the executor decides for the same model. The brief is still the seam that gives the meeting
side its connections without letting a memory become evidence for a write; a read's answer is
capped (`MeetingAgent.maxLookupCharacters`) because the next round's prompt was sized before
it existed. Three asymmetries are the feature, not
oversights: the brief is tokenized and
counted against the provider window before the single-pass decision, or the meetings with
the most context are the ones whose prompt overflows; the map step never receives it, since
its whole job is "write only what was said" and context facts come back as claims someone
made; and `Chunker.notes` skips the section, since indexing it would file memory facts under
a meeting's citation and `KnowledgeExtractor` would turn them into decisions nobody spoke.
With no brief, `NotesFormatter.emptySection` forces `_None._` regardless of what the model
wrote — the prompt already asked for that, and the first live run had Apple's model write
"this aligns with known concerns" about an empty block anyway.

**`_None._` and "cut short" are different claims, and only one of them is the model's.**
`LLMCompletion.finishedByLimit` is the single signal that separates them: a model that ran out
of allowance has not decided there were no decisions, so `NotesFormatter.tidy(_:cutShort:)`
writes `NotesPrompts.cutShortMarker` under every section the answer never reached rather than
`NotesPrompts.emptyMarker`. Everything that shapes that sentence is deliberate. The notes
pass retries once at double the allowance first, and only when `outputBudget` leaves the room
(`answerWithRetry`); a second refusal is minutes nobody asked to spend. The **map step is
never retried** — a fact list cut at the end is still facts — so `answerWithRetry` wraps the
single pass and the reduce and nothing else. `emptySection` still wins for Related context on
an empty brief, truncation or not, which is why it runs *after* `tidy`. The field has a
default of `false` so a provider that cannot tell leaves it false rather than guessing, and
each provider's rule is its own evidence: Apple's is the estimate within two tokens of the cap
(`FoundationModelLLMProvider` reports no stop reason), llama's is `generated >= maxTokens`,
an OpenAI-compatible server's is `finish_reason == "length"`, and **OpenRouter's belongs to
P0-17** — its decode and its `OpenRouterError.cutOff` throw stay P0-17's, and the notes pass
only hands the result on. A cut pass writes `finishReason: "length"` in its own usage row, so
`--usage-report` can say a meeting's notes were cut off without opening them, and the page
carries the rest. `--selftest-notes-truncation` is the gate; it fails if the filler comes
back, and its reduce case exists because the single pass alone would leave half of this
paragraph unpinned.

`--notes-context-live` is the read-only diagnostic that prints the brief this machine would
assemble, and it is deliberately **not** a `--selftest-*` flag. The self-test harness
replaces every store with an isolated one — `KnowledgeIndexer.shared` gets a temp index with
the feature off, `NextMemory.shared` a temp memory, and `NotesModelRuntime` refuses to adopt
the saved model — so run under the harness it prints an empty brief and Apple's model on a
machine whose index is full and whose notes run on a downloaded one. That is a green answer
to a question nobody asked; the flag has to be launched outside `SelfTest.isRunning`, and
`--selftest-out` still captures its output when LaunchServices has no stdout.

`--meeting-quality-report` is the same kind of diagnostic for meetings: one
`MeetingQualityProbe` row per finished meeting, read from the real `MeetingStore.shared`,
never a `--selftest-*` flag, never a save/repair/pipeline. Its in-memory counterpart is
`--selftest-meeting-quality` (`MEETING_QUALITY_OK` / `MEETING_QUALITY_FAILED`).

**Memories are drawn onto the graph, not written into it.** `MemoryGraphOverlay` assembles
`memory:` nodes at draw time from `NextMemory` and merges them into the map; clicking one
opens the Memories editor on that fact (`NavigationState.openMemories`). They are deliberately
not rows in `graph_node`: every edge there must cite a real chunk (`source_chunk` is
`NOT NULL REFERENCES chunk(id)`), `pruneSharedNodes` deletes any shared node left with no
edge, the ontology has to declare a new node type in two synchronized copies, and
`deleteAll()` runs whenever the graph switch is flipped — a memory fact is none of those
things and would be deleted by three of them. The overlay also means an edited or forgotten
memory redraws on the next reload (`KnowledgeGraphPane.memoryFingerprint`), which a copied row
would not. The edges are conservative on purpose: a `remembered_as` edge exists only when a
node's own label shares a word of three or more characters with the memory's words, so the map
shows the connection rather than claiming one.

**`LLMProviderID.appLLM` is a kind, not a file name, and the retired `gemma4E4B` spelling
still decodes to it.** The app's own provider used to be identified as the model that shipped
that release, so a Mac running an installed model recorded it as Gemma in `Meeting.notesModel`,
every notes log line and `--selftest-notes`. The concrete model now travels separately:
`LlamaLLMProvider.displayModelName`, captured in `LLMProviders.make` from
`InstalledModelLibrary.activeModel`, because a provider is a value handed to actors and the
library is main-actor state. `init?(rawValue:)` maps `gemma4E4B` to `.appLLM` on purpose — a
stored value that no longer decodes silently becomes a different provider. `Settings.notesProvider`
was deleted for the same reason and must not come back: nothing wrote it, a self-test and the
Regenerate menu read it, and a real machine held a retired spelling in it while production used
the meeting-notes role. One choice, one place.

**The knowledge index is on by default, and a fixture that wants it off says so.** `enabled`
is true in both `KnowledgeIndexSettings` and its `fromDefaults` fallback: search over the
user's own meetings, notes and conversations is the feature the Knowledge screen exists for.
`includeDictation`, `includeRoutines`, the graph and the embedder all stay off, so the default
indexes meetings and ended Agent conversations, BM25 only. Self-tests still get an isolated
store, but now through an explicit `KnowledgeIndexSettings(enabled: false)` rather than a
fixture default that happens to match the product — `--selftest-index` pins the on-by-default
answer so a silent flip fails a test instead of shipping.

**`URL.resourceValues` answers from a cache attached to that `URL` instance.** The model
downloader's own size check was served stale bytes from a `URL` it had held across a write,
so a resumed transfer was silently skipped. `ModelDownloader.fileSize(at:)` goes through
`FileManager` instead. The older pinned-model path is safe only by accident — `ModelSpec.fileURL`
is a computed property that returns a fresh `URL` each call — so it is the same trap one
refactor away.

**`URL.resolvingSymlinksInPath()` is not a canonical form, and it disagrees with
`FileManager.enumerator`.** It strips `/private` rather than adding it, while the enumerator
reports every child under `/private/var/…`, so a prefix test between the two matches nothing:
every `LIKE`, every `parent =` lookup and every purge in the file index silently returned
empty, which reads as "the index is broken". Both the file index and the skill scanner hit
this independently. Use `realpath(3)` — `FileIndexStore.canonical` and
`SkillScanner.canonicalPath` are the two copies.

**`FileManager.enumerator(at:)` yields nothing when the root URL is a symlink to a
directory.** On this Mac ~90% of `~/.claude/skills` entries are symlinks into
`~/.agents/skills`, so every one of those skills reported exactly one file and
`skills.read(name, file:)` refused all 1025 bundled files. Worse, de-duplication kept the
*first* candidate by name+hash and `.claude/skills` is scanned before `.agents/skills`, so the
crippled record shadowed the intact one. Resolve the root first, and prefer the candidate
with more files on a key collision.

**`AgentTurnIntent.computer` has no producer, and `ComputerLoopPlanner` is dead for live
turns.** `resolve` only ever returns `.delegate`, `.localModel` or `.toolLoop`; the
`.computer` case survives as a pattern match and a progress title. A real "click the Send
button" goes `handle → .toolLoop → runModelTurn`, which picks its model through
`AgentModelRouting`, so the "Controlling your Mac" role *does* reach the path that plans the
clicks. A reviewer read the `performComputer → runComputerLoop → ComputerLoopPlanner` chain
as the live one and filed it as a blocker; wiring a model into that closure would wire it
into a path nothing takes. Grep for a producer before believing an `enum` case is reachable.

**There is one source of truth for what a turn may do, and it is `AgentCapabilityManifest`.**
Built once per planner turn from the registry (native, MCP and Composio), the four switches,
consent, the reader and live readiness, it answers for all of them at once: the planner's
schema (`selected`), the rule lines (`ruleLines()`), the grounding sentence
(`groundingSurfaces`), the execution check (`entry(named:)`), "what can you do"
(`capabilitiesAnswer(voice:)`) and the voice gates (`allowedIDs`). Four of those used to be
separate answers that disagreed — the planner saw nine core tools plus fifteen picked by
four-letter substring overlap while the prose listed the whole allowlist and the rules named
tools that had been dropped. `RealtimeAgent.plannableTools()` survives as a wrapper over
`AgentCapabilityManifest.current()` so its other call sites keep compiling; it is a spelling
of the manifest, not a second opinion, and the only literal id lists left in the tree are
`AgentCapabilityManifestBuilder.coreIDs` and `.nativePlannerExclusions`.

**Tools are chosen by intent class, never by keyword top-k, and a class is never half
present.** A request is reduced to a set of `AgentIntentClass` by a word-bounded lexicon, and
if any tool of a class is selected every allowed tool of that class is. That is what fixes
"what's on my to-do list", "what did we decide" and "Sarah said the budget…", which reached
nothing under overlap scoring because no tool's name or description contains those words. The
catalogue is then fitted to the reader — compact rendering, and unmatched core entries dropped
before any matched class is touched. A model that calls an allowed tool outside the schema gets
it, and the next round's catalogue widens to the class it reached for. MCP and Composio tools
join by risk class at or below `.send`, and never shadow a native implementation of the same
capability. `--selftest-capability-manifest` pins the parity set, scans every assembled
planner prompt for an id its own schema lacks, and checks every switch, consent and readiness
case. A name that resolves to nothing, or to a tool outside the manifest, still ends the turn
with "The tool planner requested an unavailable tool; nothing else was run." — P1-04 owns the
tolerant half.

**The planner asks for tool calls natively where the reader supports it, and the grammar and
the schema must be the same set.** `PlannerBackends` is the only place a backend is chosen,
from the provider the turn already resolved and the manifest it was given: a GBNF grammar over
`manifest.selected` for the on-device runtime, one `Tool` per selected entry for Apple
Foundation Models, a `tools` array for OpenRouter and a model app on this Mac, and
`PromptConventionPlanner` — today's prose catalogue and Hermes tags — for everything else,
for a server that rejects the field, and as the rollback path. The grammar's `"name"`
enumeration and the prompt's catalogue and the `tools` array all come from `selected`, because
a grammar over a *different* set than the schema the model was shown is worse than no grammar:
the sampler would be steering toward calls the prompt forbids.
`--selftest-native-tools` proves the three are one set by reading the ids back out of the
*rendered* grammar, not out of the code that built it. Two rules that are not negotiable: a
`Tool.call` body only ever hands an `AgentToolCall` to `ToolStepRunner`, which is the sole
caller of `AgentToolExecutor.run` inside the planner, so a write is still a question for a
person before it is an action; and nothing throws out of `Tool.call` for a denial or an
exhausted budget, because a throw aborts the whole response with
`LanguageModelSession.ToolCallError` — it returns a `STOP:` sentence and records
`runner.terminal`. The grammar is a *sampler* parameter and not a prompt, which is why
P0-18's prefix reuse still holds; `--selftest-llm-prefix-cache` measures that rather than
assuming it. `Settings.agentNativeToolCalling` (defaults key `agentNativeToolCalling`, no UI)
is **off by default**: the task's own rule is to flip it only after three full
`--selftest-toolloop-live` runs score at least as well on both models, which is the Phase-1
exit artefact. `--planner native|prompt` forces one path for a single eval process and never
writes a preference. P1-04's tolerant parser is still what reads a round on every path —
grammar-valid text is read by the same reader, so the repair loop stays reachable for a model
that is not under a grammar.

**A refusal is judged per clause, and an offer is a refusal.** `AgentRefusalGuard` splits the
reply at sentence ends and at "but"/"however", and a clause counts only when it both names a
capability and denies it. "I don't have enough information to set that reminder" is an honest
limit and must survive — the old substring match read it as a denial and re-planned a truthful
answer — so there is an explicit list of honest limits, and "would you like me to check your
email?" counts as a denial in its own right. A denial of something that is switched on but not
connected is *honest*: the manifest puts those entries in `unavailable`, the guard returns nil,
and the setup sentence says where to go.

**A GGUF can be valid and still unopenable.** The architecture must be in
`LlamaArchitectures.supported`, the table generated from the pinned llama.cpp tag by
`Scripts/gen-llama-architectures.sh` and cross-checked against the linked binary. K2-Horizon
(`k2-horizon`) was the example: a complete 3.16 GB file the owner had downloaded that
b10621's `llama_model_load_from_file` returned nil for, which the planner reported as "The
model could not be loaded." The guard reads the GGUF header and opens only the vocabulary —
`--selftest-model-unopenable` case A fails if deciding support loaded any full weights — so
an unopenable file is refused before a download, on install and before a role is assigned,
without paying the load. `k2-horizon` is still absent from the table, and P0-16 is won't-do
unless upstream llama.cpp adds it.

**Provider resolution is read-only, and the switch is awaited.** On 2026-09-23 the typed
turn resolved its provider twice — once for the first pass and again inside the planner —
and a resolution wrote the library's selection while a fire-and-forget swap to that file was
still in flight, so a plain question could be answered by a different model than the turn
planned against. Now `ModelRoleStore` resolves read-only and deterministic, the library's
`adoptInRuntime` is fire-and-forget only for a person's own selection change, and a turn
calls the runtime's awaited `select(_:)` before it takes a provider.
`--selftest-model-unopenable` case H is the guard.

**`--selftest-llm-metal` used to prove nothing about the Agent.** With the built-in Gemma
absent it loaded S1-mini, the 0.6B cleanup normaliser, and reported `LLM_METAL_OK` on a Mac
whose Agent role pointed at a file llama.cpp could not open — a green Metal gate over an
agent that answered nothing. It now has an agent-role leg: the role's real model must decode
a token, printed as `LLM_METAL_AGENT_ROLE: <model> generated N token(s)`, and zero tokens
fails the run.

**The download verify decodes a token, and runs before anything is switched or deleted.**
`NotesModelRuntime.trial(_:)` opens the exact file in the background lane, builds a context,
decodes a fixed prompt and samples up to eight tokens; only a generated token becomes
`.answered`, a context or decode failure is `.opensButCannotAnswer`, and a file that will not
open is `.cannotOpen`. It never touches the library (the caller records `lastTrial` on the
row), frees the weights before it returns, and refuses while a voice lease is held so it
cannot race the switch. `ModelLibraryStore` runs it before `applyPostDownloadPolicy` deletes
or switches and will not switch to a file that did not answer. Opening is not answering — an
MTP draft head opens happily and then fails to build a context.

**A reasoning model spends its answer allowance thinking.** OpenRouter's ling-3.0 used 105 of
its 112 allowed completion tokens on reasoning and ended `finish_reason: length` without
writing anything visible, which the old plumbing surfaced as "The model returned an
incomplete response." (G N1). `OpenRouterReasoningPolicy` asks for cheap reasoning and pays a
bounded allowance on top of the caller's visible budget — `visible + allowance` clamped to
the room left in the reader's window — and a pass cut off before any visible text gets one
retry with the allowance doubled (bounded by a quarter of the window and 4,096).
`--selftest-openrouter-contract` replays the exact `reasoning_tokens: 105` stream event; the
live `--selftest-openrouter` prints `OPENROUTER_REASONING`.

**The llama runtime reuses the prompt prefix; anything that changes the KV contents must
reset `kvTokens`.** `PrefixReuse.keepCount` finds the longest token prefix the new prompt
shares with the cached one, capped one short so the final token is always decoded for
logits, and `NotesModelRuntime` trims with `llama_memory_seq_rm` and decodes only the tail.
A partial removal llama refuses (recurrent or hybrid memory) falls back to a full clear, and
every error, cancellation, context rebuild, model swap and shutdown resets the ledger. Add a
path that changes what the context holds and the reset comes with it, or the next turn
answers from a stale prefix. `voiceRoutingSystem`'s "identical across the turns of a session
so the llama.cpp prefix cache holds" is only worth anything because of this. Measured:
reused 646/666 tokens, prefill 2.10 s → 0.33 s; `--selftest-llm-prefix-cache` is the guard.

**"Right now" is section 7 of every prompt, after the cacheable prefix, and it is the reason a
date was ever wrong.** A voice request for today's calendar returned an agenda for 2023-10-27 and
the Agent told side talk the clock read 1:45 AM, three and a half hours out — not hallucinations
in the usual sense: the typed first pass, the voice answer lane and the voice route carried **no
date at all**, so any date in an answer came from the model. `AgentNow` (P4-01) is one renderer
over one cache that every path with a clock reads. Four rules it lives by. **It is section 7, after
`skills`**, because it is the only section whose text changes within a session; put it earlier and
the prefix cache is thrown away every turn. **It is data, not instructions** — its header says so,
and nothing in it can widen what a path may do. **It never names an id**: no task id, proposal id,
event id or file path, because a model that can read one will put it in an answer. **Unknown and
empty are different sentences**: `- Calendar: not connected` is never rendered as
`- Next: nothing in the next 24 hours`, because the second one teaches a model to invent a
confident answer. Shapes are budgets, not preferences — `.full` 600 chars, `.compact` 320,
`.unattended` 400, `.dateOnly` 90, `.none` 0 — and when a block is over its cap the lines drop from
the bottom up and `Time` is never the one that goes. A cloud reader gets the clock and nothing
else unless `agentCloudConsent` is on (P4-09 owns that setting; the key is read as absent = false
until it lands). `--selftest-now-block` is the guard. The planner's own `Today is …` line and the
routine runner's `Now:` line are **gone** — two date sources replaced by one.

**Model calls use `PrivateURLSession`, not `URLSession.shared`.** `URLSession.shared` is
backed by the process-wide `URLCache`, and it wrote a full OpenRouter SSE stream — the
model's reasoning included — into `~/Library/Caches/ai.pivotstudio.nextnotes/fsCachedData/`,
where it outlived the turn and could be replayed from disk (G N4). Every provider that
carries model or account data now goes through `PrivateURLSession.shared` (ephemeral,
`urlCache = nil`, cache-ignoring), and launch purges what the old session left behind once,
outside the harness. Model downloads and public metadata are deliberately excluded.
`--selftest-private-network` fails if a provider slips back to the shared session.

**MiniCPM5's tool delimiters are control tokens, and `special = false` erases them.**
`llama_token_to_piece(..., special: false)` renders `<function name=…>`, `<|tool_call>` and
`<|im_end|>` as empty strings, so the planner's output parsed as prose and every tool request
failed on a model that was writing correct calls (G N3). `ChatTemplate` detects the
`minicpm5` family from `tokenizer.ggml.pre` or a `<function name=` in its template and
renders those markers itself; `LlamaHelpers.piece` passes `renderSpecial` through on the
planner decode path; notes generation keeps it off and strips the markers afterwards.
`--selftest-chat-template` pins detection and rendering across the families.

**A confidence score from a function-calling model is not comparable across tool sets.** The
same sentence scored 1.00 with 2 tools, 0.93 with 14 and 0.41 with the 8 this app offers, so
a fixed 0.65 gate threw away correct proposals. The schemas bound the catalogue for two more
reasons — Needle shares its 8K context between the system prompt, the tool schemas and the
turn, and the static prefix's prefill scales with them — which is why `FunctionCallCatalogue`
is curated and capped rather than "every tool we have". The prefill is now a one-time cost
(the 126 ms at 2 tools, ~1 s at 8, ~4 s at 14 figures were measured spawning a process per
proposal; `NeedleServer` pays it once per run and every turn after is p50 ~60 ms, measured
2026-09-23). The real filter is grounding, not confidence: a model asked to "send Marcus the
pricing sheet" with no address anywhere invents a plausible-looking one at confidence 1.0.

**Needle is one resident `--serve` child, and its serve-mode parser wants compact JSON.**
`NeedleServer` starts `needle3-macos-arm64 --serve --port <kernel-picked>` on the watcher's
first transcript (warmed before the first proposal), sends `POST /reset` then
`POST /complete {"input":…}` per turn, and stops it on feature-off, app termination, ten idle
minutes, or the end of a self-test. Three traps, all measured on 2026-09-23: the engine's
request parser does not accept whitespace around the colon — `{"input": "…"}` is read as an
empty input and answered from the prefix alone, in a canned call at full speed, which is what
made a hand-rolled client look like a broken model until the bytes were compared; `/reset`
before every turn is what restores the statelessness the spawn path had for free (an identical
prompt scores 0.78 fresh, 0.93 after another turn, 0.78 again after a reset); and a crash
cannot run any stop path, so every start reaps a previous server whose owning app pid is gone
(`server-<pid>.json` under the working directory, `proc_pidpath` checked before any signal).
`--selftest-function-calls` prints `FUNCTION_CALLS_SERVER` and fails if the resident engine
answered none of the turns — a run where every proposal spawned a process still produces
correct calls, and would otherwise pass as a run of the architecture this replaced.

**A new engine in `--selftest-cleanup` scores 28/28 until you give it a `rawCleanup` case.**
The verdict compares the guarded pipeline output against an unguarded second call; with no
case in `rawCleanup` that call returns nil, every verdict defaults to "ok", and a rejected
answer is indistinguishable from a perfect one. The chain genuinely scored 28/28 that way and
23/28 once the raw path existed. Add both halves or the number means nothing.

**A self-test run from a shell can be denied a grant the app plainly has.** TCC grants the
*responsible* process, and for a binary launched straight from a terminal that is the shell,
not Next Notes. `--selftest-systemaudio` reported `SYSTEM_AUDIO_SILENT` from a shell while the
same build, same machine, same second, returned `rms 0.17489, peak 0.75562` when launched
through LaunchServices. Before touching any privacy setting, re-run it as the app:

```
Scripts/run-selftest.sh --via-open --selftest-systemaudio
# equivalent: open -n -a "Next Notes" --args --selftest-systemaudio --selftest-out /tmp/out.txt
```

`--selftest-out` exists for exactly this: a LaunchServices launch has no stdout.

**A SIGABRT in `HIServices` `_RegisterApplication` right after launch is usually an agent
false alarm, not a Dock/Finder bug.** Measured repeatedly on 2026-09-17 (21:35 and again
21:58): Next Notes died in `NSApplication init` → `_RegisterApplication` → `abort()` with
no app frames beyond `NextNotesApp.$main`, `Responsible Process: Cursor`, parent already
exited, `procRole: Unspecified`, coalition `com.todesktop.230313mzl4w4u92`. Lifetime ~0.25 s
— before any self-test or UI code runs.

Two agent mistakes produce the same report:

1. **Launch while `/Applications/Next Notes.app` is mid-reinstall** (or disk-full) so
   `Contents/MacOS/NextNotes` is missing. `open` fails with `kLSNoExecutableErr`; a direct
   binary start under Cursor aborts inside registration. Self-tests still go through full
   AppKit — there is no pre-`App.main` entry.
2. **Direct-binary launch from a Cursor agent shell that exits before AppKit finishes
   registering** (backgrounded command, tool timeout that orphans the child, or a chained
   `make install && "$BIN" --selftest-…` racing another install). The 21:58 pair matched a
   freshly signed bundle (`da6ddffa-…`, Signed Time 21:58:09) launched seconds later as
   Responsible=Cursor / Parent=Exited process — not a half-copied Mach-O.

**Dock / Finder / a healthy `open -n "/Applications/Next Notes.app"` are unaffected.** If
that path works and the crash lists Cursor (or another IDE) as responsible, ignore the
report — it is noise from agent launch hygiene, not a user-facing launch bug. Do not
"fix" it by rewriting `App.main`.

**How agents must install and self-test now:**

```bash
make install OPEN=0          # never omit OPEN=0; never launch the GUI from install
Scripts/run-selftest.sh --selftest-graph-layout
# TCC-sensitive only:
Scripts/run-selftest.sh --via-open --selftest-systemaudio
# or:
make selftest SELFTEST_ARGS='--selftest-orb'
```

`make install` and `Scripts/run-selftest.sh` share `~/Library/Caches/NextNotesBuild/install.lock`
and the install still swaps via `/Applications/Next Notes.app.new`, so a self-test cannot
start against a half-deleted bundle. The wrapper verifies the executable exists and
`codesign --verify`s the app, then runs the binary in the **foreground** (never `&`). Do
not bare-invoke `/Applications/Next Notes.app/Contents/MacOS/NextNotes` from an agent
shell, and do not `open` the GUI as a side effect of install.

**The staging bundle is per make invocation, and only the swap takes the lock.**
`app:` assembles into `~/Library/Caches/NextNotesBuild/install-<make-pid>/`, a path no other
process can name, so two concurrent `make install` runs cannot interleave their `cp`s into one
directory — which is what three install failures in an hour measured on 2026-09-25, along with
the worse variant of publishing one run's binary against another's frameworks. The suffix is
make's own pid read with `$(shell printf %s $$PPID)`, **not** `$$`: in a variable assignment
`$$` expands to a literal `$` and every run would share one directory. The swap into
/Applications keeps `install.lock` because it touches the path every launch and self-test
resolves. `install-bundle.sh` reaps the per-run directory, and `install-*` directories older
than a day left by a make that died mid-stage.

**`make app` also refreshes one report in the background, and an agent can read it instead of
re-deriving it.** `Scripts/dictation-gates.sh` computes the two evidence-gated tasks of
`roadmap/done/DICTATION-MEETINGS-LIMITS` — D-13 (presses refused while a hold is finishing) and
D-14 (a dictation hold overlapping a meeting whose transcription waited on the speech lane), whose
remaining work is `roadmap/todo/DICTATION-MEETINGS-RATES-AND-GATES/` —
and writes three files atomically into
`~/Library/Caches/NextNotesBuild/dictation-meetings/`: `gates-latest.txt` in words,
`gates-latest.json`, and one `gates-history.jsonl` line per run with the commit it ran against.
Each task reads `proceed`, `won't do (evidence)`, or `not enough data` with the shortfall
named; **an undecided gate is never a pass**. The thresholds are the task text's own (100 owner
holds over 7 days, 3 qualifying occurrences each). `make gates` runs the same script in the
foreground, and `python3 Scripts/dictation-stats.py --gates` is the reader underneath. The run
is detached, read-only on the owner's stores, and cannot fail a build: if the reader breaks it
records `GATES_RUN_FAILED` in the history and leaves the last good report in place, so a stale
report never looks like "no news". Today's real answer is `not enough data` for both, because
`dictation.hold` rows begin at D-01b (2026-09-25).

**`make acceptance` runs the catalogue in tiers so the signal is not buried.**
`Scripts/acceptance.sh` drives the installed bundle through the same `run-selftest.sh`
launcher, one flag at a time, and classifies each run from its own output: a final `*_OK` is
PASS; an absent-precondition diagnostic (`*_ABSENT`, `SYSTEM_AUDIO_SILENT`, `WAKE_*_MISSING`,
`VOICE_FRONTEND_MISSING_WORKER_MODEL`) is SKIP and is never counted in the `passed/total`
fraction; anything else without a final `*_OK` — `*_FAILED`, `SELFTEST_TIMEOUT`, no verdict at
all — is FAIL. **CORE** is the release gate (dictation, meeting audio capture, streaming
transcription, wake-live, voice conversation, acoustic replay, duplex, action
runtime/activity, meeting live, tool loop, computer use, ACP, MCP); a CORE FAIL exits
non-zero and a known-red entry is left red rather than special-cased green. **INTEGRATION**
covers the knowledge index/search, graph and entity resolution, memory, routines/schedule,
browser CDP, model roles and function calls; **EXPERIMENTAL** is the rest of the catalogue,
including the live and credential-bound diagnostics and `--selftest-cleanup` (the long pole,
run without `--selftest-timeout` because it sizes its own budget). `make acceptance TIER=core`
runs one tier and `make acceptance --dry-run` prints the manifest without running anything;
logs land in `~/Library/Caches/NextNotesBuild/acceptance/`. Entries whose tier entry carries
`via-open` (dictation, microphone, system audio, the live acoustic and AX probes) are launched
through LaunchServices, because TCC keys a grant to the responsible process and a direct shell
launch is denied the grant the app itself holds — without that marker those entries report a
permission failure that says nothing about the code. The runner also fixes the launcher's
via-open wait, which used to miss a verdict line that had a sentence after the marker
(`DICTATION_OK: …`) and sit until its timeout on runs that had already finished.

**There is no way to read the system-audio grant, and `CGPreflightScreenCaptureAccess` is not
it.** It is tempting — the pane is called "Screen & System Audio Recording" and the tap's own
error points there. But that pane holds *two* lists, and an app granted "System Audio
Recording Only" captures audio perfectly while the screen-capture preflight keeps answering
false. Measured both ways in one process. `Permissions.requestSystemAudio()` opens a throwaway
tap to provoke the prompt; nothing reads the answer back, because nothing can.

**A self-test cannot fail by hanging.** It runs as a task inside a SwiftUI app; if it never
finishes it never terminates, and the process falls through into the AppKit run loop looking
exactly like a running app. `--selftest-cleanup app-llm` sat that way for three hours on 2 seconds
of CPU. There is now a watchdog — `SelfTest.timeout`, `--selftest-timeout <seconds>` to override
— which prints `SELFTEST_TIMEOUT` and exits non-zero.

The default is 300 s for every test **except** `--selftest-cleanup`, which is sized from
`CleanupEvalCases.all` instead: it runs every fixture through every requested engine, one
model-backed fixture takes about a minute, and `all` is five model passes. A flat 300 s stopped
it at the fourth fixture of twenty and reported it hung, for a run that was proceeding normally.
Add a fixture and the budget moves with it.

**A self-test flag is never a flag's argument.** `SelfTest.value(after:)` refuses a value
beginning with `--`, and `SelfTest.requested` skips both harness flags by name. Without either,
`--selftest-cleanup --selftest-timeout 2400` read `--selftest-timeout` as the engine name,
printed `unknown engine`, ran nothing, and **exited 0** — a green result for a suite that never
executed.

**`LlamaBackend`'s cleanup gate is one-directional, and closing the cycle deadlocks it.**
`NotesModelRuntime.loadIfNeeded` calls `awaitCleanupIdle()`, so notes wait for dictation
cleanup. A cleanup formatter that calls `beginCleanup()` and *then* asks that same runtime to
complete waits forever: the load waits on a count only `endCleanup()` clears, and `endCleanup()`
runs after the load returns. `AppLLMCleanupFormatter` therefore does not touch the gate — it is
the notes model, behind the same actor, which already serialises it.

**Transcript text in the Dictation list cannot be selected with the mouse.** Deliberate. The
list is a multi-select `List`, and selectable text competes with row selection for the same
mouse-down: with `.textSelection(.enabled)` on the transcript, clicking the body of a row
places a caret instead of selecting the row, and the body is most of the row. Copy is on the
hover button and the context menu, for one row or for many. If free text selection is wanted
back it belongs in a detail view, not in the list.

**A self-test must never call `RunLog.record`.** `DictationController` takes a `record:` seam
exactly like `insert:`, and `--selftest-dictation` passes `{ _ in }`. Without it the test files
its fixtures into the user's own Dictation history — it did, silently, until 2026-09-09, and
55 rows of "Self test transcript." had to be cleaned out of a real machine's `runs.jsonl`.
If you add a self-test that drives the controller, pass both seams.

**`dotnet build NextNotes.sln` fails on macOS** with `NETSDK1073`. Expected —
`NextNotes.Platform.Windows` targets `net10.0-windows`. Use `NextNotes.CrossPlatform.slnf`, which
omits it; everything else, including the whole UI suite, builds and tests on macOS in about
half a second.

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Mutating `@State` inside a `Canvas` draw closure floods the log and corrupts state.** The
VU meter keeps its needle physics in a plain reference type the view merely holds, which is
invisible to SwiftUI's state graph. Don't "clean that up" into `@State`.

**A system-audio tap without permission returns silence, not an error.** Every call in
`SystemAudioCapture` succeeds — the tap is created, the aggregate device is created, the
IOProc runs at the right rate — and every sample is zero. The only trace is
`Client is not granted access to the tap` from `coreaudiod` in the unified log:

```bash
/usr/bin/log show --last 5m --predicate 'process == "coreaudiod"' | grep "access to the tap"
```

So nothing in the app claims to know whether system audio is allowed: the Permissions
checklist shows that row as unanswerable, and `--selftest-systemaudio` reports
`SYSTEM_AUDIO_SILENT` rather than success when the peak is zero. Like Accessibility, the
grant is keyed to the code signature, so it has to be re-granted after an ad-hoc rebuild —
`tccutil reset AudioCapture ai.pivotstudio.nextnotes` resets that one row.

**Every await in the dictation tail has a deadline, and the deadlines are the point.**
`DictationController.endDictation` drains the audio, calls `engine.finish()`, awaits the
transcript stream and then the cleanup pass. All four used to be unbounded, and the state
machine sits in `.finishing` for the whole of it — a state the HUD and the island both used
to draw as a live recording. So anything that did not come back (a model still loading, a
transcript stream nobody finished, a cleanup pass on a machine that had started swapping)
showed up to the user as "it looks stuck and it keeps recording in the background", with the
next press refused because `.finishing` still counts as active. Every leg now goes through
`withBoundedWait`, `DictationController.Limits` names each deadline, and every failure path
stops capture and returns to `.idle`. `--selftest-dictation` is the guard: remove a bound
and it reports `DICTATION_STUCK: still finishing`. `withBoundedWait` is a hand-rolled latch
rather than a task group on purpose — a group awaits every child before it returns, which
would re-introduce exactly the wait it exists to remove.

**`DictationController.session` is not a counter, it is what keeps two holds apart.**
`engine`, `consumeTask`, `feedTask` and `audioContinuation` are one slot each, and starting
a recording is slow — Parakeet is eleven seconds cold. Release the key during that and hold
again, and two start-up tasks are in flight against one set of slots. Unguarded, the late
one writes its engine over the live one's, and `endDictation` then finishes engine B while
awaiting engine A's stream — a stream nobody will ever close. Every continuation that writes
back into those slots re-checks `session` first, and a superseded start-up finishes its own
engine and touches nothing else. Capture starts at key-down, into an in-memory pre-roll owned by that session, and is replayed into the engine once it has started; a superseded start-up never touches the hub — only the session that owns the slots unsubscribes. Measured reason: on 2026-09-23 a cold start after a 52 s model load put 4.40 s between key-down and capture, and the hold was lost. A fifth slot followed the same rule on 2026-09-26 (`incrementalCleanup`, the sentences tidied while the key is still down): created at `.listening`, fed by the `consumeTask` under the existing `session` guard, taken by the tail only *after* that guard, and dropped by every exit that ends a hold. Nothing injects before key-up, so a pre-clean can only ever be wasted work, never wrong text.

**The dictation tail logs its own split.** `runs.jsonl` records one `processSeconds` for
everything between key-up and injected text, and one number cannot say which of draining,
transcribing and cleaning up was slow. Every run also writes
`dictation tail · drain …s · transcribe …s · cleanup …s` at info level, which is the first
thing to read when someone says dictation got slow:

```bash
/usr/bin/log show --predicate 'subsystem == "ai.pivotstudio.nextnotes"' --last 30m --info \
  | grep "dictation tail"
```

Info-level entries age out of the unified log within minutes, so this is only useful
promptly — a slow run reported an hour later has already lost its evidence.

**A meeting reaches "Done" minutes after you press Stop.** Everything after the transcript is
handed to `MeetingPipeline` — identify speakers, then write notes — rather than awaited inside
`MeetingSession.stop()`. Clustering a long recording and summarising it are each minutes of
model time, and a `stop()` that waited would keep the session — and therefore the Record
button — alive for all of them. The session hands the meeting over at `.diarizing` or
`.summarizing` and lets go; `DiarizationService` and `NotesService` own the rest of the walk
to `.done`. So the Record button comes back long before the Notes tab fills in, and that is
the intended order.

**An interrupted meeting is resumed, not written off.** `make install` stops a running app
with `pkill -x NextNotes`, a SIGTERM that skips `applicationWillTerminate`, and it is run many
times a day on a development Mac. A meeting recording at that moment used to come back
`.failed` at the next launch although `transcript.json` was on disk and intact; one
interrupted while diarizing or summarising came back `.done` without speakers or
notes, with its temporary audio already deleted — so it could never be re-diarized. Launch
repair is now "plan, then resume": `MeetingStore.resumeAction` is the pure table,
`MeetingStore.repairInterruptedMeetings()` repairs the statuses and returns the plan, and
`MeetingResumer` runs it one meeting at a time behind the same busy gate the extraction
resume waits on. `MeetingStore` takes a root, and `MeetingStore.isolated()` is the test seam —
no seeded meeting ever touches the user's `Meetings/`.

| Status on disk | transcript | audio | resumes as |
|---|---|---|---|
| `.recording` / `.transcribing` | any | yes, final pass on | the final pass (M-01), then the pipeline |
| `.recording` / `.transcribing` | non-empty | no (or pass off) | the pipeline from the transcript |
| `.recording` / `.transcribing` | empty | no | `.failed("Next Notes quit before anything was transcribed.")` |
| `.diarizing` | — | yes | diarization, then notes |
| `.diarizing` | — | no | notes |
| `.summarizing` | — | — | notes |
| `.extracting` | — | — | `.done`, re-extraction queued |

Nothing releases audio during repair: the stage that finishes reaches
`releaseAudioWhenDue`, which for a temporary recording schedules the release 72 hours
out (M-10) and for a kept one calls `releaseAudio` with the rule unchanged.
`MeetingSession.endAbruptly()` leaves a meeting `.transcribing`
rather than `.done` for the same reason, and a normal Quit is caught before that —
`applicationShouldTerminate` offers "Stop and Quit" (a ten-second bounded stop) or
"Keep Recording", and SIGTERM gets no alert because it cannot be caught. Both model stages
also carry a stall watchdog (`StageWatchdog`): diarization with no progress for 5 minutes,
notes with no new step for 10 minutes, minus any time `.realtimeASR` or `.realtimeAgent` held
the machine. A stalled pass is cancelled into the plain problem "This took much longer than it
should, so it was stopped. Try again." and **keeps its recording**, so the retry the problem
offers has something to read. `--selftest-meeting-resume` is the gate (CORE); it seeds its
meetings through `MeetingStore.isolated()` and injects its stage runners.

**`transcript.json` is written on a 5 s throttle and flushed on every way out (M-16c).** The
old comment's crash-safety argument — write it as it grows, because a two-hour meeting that
loses everything at minute 118 is the failure this feature can least afford — was right and
was also 2,700 whole-file rewrites, ≈1 GB, for a file that ends at half a megabyte.
`TranscriptSaveThrottle` is the rule, pure so the session and its self-test decide the same
way: the first segment writes at once, then at most one write per `interval`, and a trailing
write puts the newest segment on disk inside the interval even when the meeting goes quiet.
`stop()`, `endAbruptly()` and `abort` all flush unconditionally, and each write cancels the
trailing one — a trailing write that outlived the meeting would put the live tier back over
the long-window finals the M-01 final pass has already written. What protects the transcript
is the *interval*, not the write count: a crash costs at most five seconds of speech, which
is all the old comment ever needed. `--selftest-meeting-resume` (CORE) pins both halves — 100
segments over 20 s of meeting clock make 4 writes and all 100 are on disk after
`endAbruptly()` — and every write records a `meeting.transcript_write` row, so a real
meeting's write count is a number rather than an estimate.

**The notes model unloads itself.** `NotesModelRuntime` frees its weights ten minutes after
the last generation, so the first meeting summarised after a quiet afternoon pays a cold
start again. That is deliberate on a 16 GB machine: 2.7 GB resident for a meeting that
ended an hour ago is 2.7 GB the rest of the Mac wanted. It also refuses to *load* while a
dictation cleanup is in flight (`LlamaBackend.awaitCleanupIdle`) — both models running is
fine, both loading at once is where the machine starts swapping.

**A meeting records audio even when "Keep the recorded audio" is off.** Diarization reads
the system channel of `audio.caf`, and the post-Stop final pass re-transcribes both
channels out of it, so turning "Tell the other speakers apart" or "Re-check the
transcript after the meeting" on makes every meeting write the file whether or not the
user asked to keep one — and
`MeetingStore.releaseAudio` deletes it again once the pipeline is done with it. Which of
the two it was is answered when the recording *starts* and stored on the meeting as
`audioIsTemporary`, not read back out of the settings when it ends: switching keep-audio off
next month must not reach back and delete a recording the user asked for. The rule lives in
that one method, and it is: a recording made only for a pipeline stage (diarization,
the final pass) goes; a recording the user
kept goes only when "delete after notes" is on *and* notes were actually written; and
nothing goes while a failed diarization pass is still offering "Identify again", which has
nothing to read without it — or while the stall watchdog has stopped a notes pass, whose
"Try again" is in the same position. Nothing else deletes a recording, so if a file is being
kept that shouldn't be, that is the method to read.

M-10 changed only *when* that rule runs, never its shape. The pipeline end no longer
deletes a temporary recording at once: `MeetingStore.releaseAudioWhenDue` stamps
`Meeting.audioReleaseAfter` 72 hours ahead, and `MeetingScheduler`'s tick sweeps
recordings past their window every 30 minutes (and once at launch) through the same
`releaseAudio` — so a meeting the diarizer over-split (3 of the 6 on this Mac, M-03) can
still be re-identified the next morning, which deleting at notes-time made impossible.
Three things end the window early, and all of them still go through `releaseAudio`: the
speakers are confirmed (the speaker sheet's Save), a diarization problem is dismissed, or
free disk is under 5 GB — under the guard "as today" wins, and the sweep releases the
oldest temporary recordings first until the space is back. Under 1 GB free at start
nothing is written at all (`MeetingSession.shouldWriteAudio`), the live pane shows
"Not enough disk space to keep a recording; the transcript is still being written.", and
the final pass records `live-only:no-audio`; the writer stops at its first write error
and reports it once rather than logging a failed chunk per frame. The sweep never touches
a kept recording, a meeting that is still active, or one whose diarization problem is
still offering "Identify again". `--selftest-audio-retention` is the gate (INTEGRATION);
it seeds its meetings through `MeetingStore.isolated()` and injects the clock and the
free space, so it never depends on this Mac's disk.

it seeds its meetings through `MeetingStore.isolated()` and injects the clock and the
free space, so it never depends on this Mac's disk.

**Speaker identification is on by default once its models are on disk, and a stored answer
beats the default in either direction.** `Settings.meetingsDiarize` was off for years,
which meant a fresh install labelled every remote voice "Others" and the notes' action
items came out Unassigned until the owner found the switch by hand — and the reason it was
off (a second model, and a temporary recording) is a cost that only exists on a Mac that
has not paid it yet. So `meetingsDiarize` is a derived effective value, not a stored
preference: `Settings.diarizationDefault(stored:modelsPresent:)` is `stored ?? modelsPresent`,
`MeetingDiarizer.isDownloaded` is "models exist", and `meetingsDiarizeChoice` is the
person's own answer. Two rules make that safe and neither is optional. **A person's tap
goes through `chooseDiarization(_:)`, which is the only writer of the stored key** — so
"off because they said no" and "off because the models are not here yet" can never be the
same value, and the Meetings toggle binds to it rather than to `$settings.meetingsDiarize`
(which is `private(set)` for the same reason). And **nothing is downloaded without a
press**: the default only turns on what is already on disk, and the first finished meeting
where somebody else spoke is *offered* it once — `DiarizationOffer.shouldOffer` is the pure
rule (finished, not already on, not answered, another voice on the system track) and
`MeetingDetailView` renders it, with "Turn On" recording the answer before it starts the
fetch. `LocalModelStore` calls `applyDiarizationDefaultIfUnchosen()` when the models land
and on `refresh()`, so a Mac that downloaded them from the Models tab is believed without
a relaunch. The cost that default implies is the paragraph above: every such meeting
records a temporary `audio.caf`, bounded by M-10's 72 h and the disk guard.
`--selftest-onboarding` is the gate (its marker is unchanged), and it pins both halves
plus the copy — no developer nouns in a string a person reads.

**A transcript segment is a sentence, not a window, and punctuation is what makes it one.**
The live tier cuts 2–5 second windows for provisional text (not 30–60: that number is
stale since the windows moved for realtime latency), and after Stop each track is
re-transcribed in long windows cut at pauses — then each window is split again before
emitting it: `buildWordTimings` groups the token
times into words, and a segment ends at a pause of 600 ms **or** at a sentence-ending mark
once the segment is at least two seconds long. The segmentation rule is unchanged and
runs in both tiers.

The second half of that rule looks redundant and is not. Parakeet reports token times on an
80 ms grid, and measured on continuous speech the largest gap between two words is about
half a second and lands wherever the speaker drew breath — "settled around | 84%", not at
the turn. Drop the punctuation rule and a two-minute, two-speaker recording collapses back
to three segments and comes back labelled "Speaker 1" throughout, with the log showing the
model found two. Splitting on sentences takes the same recording to twenty segments and two
speakers. Lowering the pause threshold instead is the wrong repair: at 0.4 s it cuts
mid-clause, because that is where the gaps actually are.

**The meeting console is four windows onto four things that already exist, and three of them
had no new data layer on purpose.** `MeetingConsoleSheet` is a sheet on `MeetingLiveView`
(⌘⇧M, the "Meeting panel" button) with a rail of four sections over one column of content.
**Notes** is the only one with anything new behind it, **Actions** draws the reconciler
`MeetingActionsView` already draws, **History** asks a query that did not exist, and **Ask**
has no service at all. That last one is the load-bearing decision: the agent already owns
`meeting.current`, `meeting.transcript`, `meeting.recent_context`, `meeting.decisions`,
`meeting.action_items` and `meeting.search`, and `AgentUtteranceSource.meeting` is already a
case — so the question goes out as the person typed it and the model reads the meeting through
the manifest. **A transcript dump prefixed onto the utterance would be the second path around
`AgentCapabilityManifest` that this file forbids**, and `RealtimeAgent` records the utterance
verbatim, so the dump would land in the permanent conversation and in every later turn's
context. If you want more in the turn, add a tool.

**A hand-written note is the person's, and `notes.md` is the model's.** They are different
files because the model's pass overwrites `notes.md` and must never overwrite a line someone
typed at minute twelve. `scratchpad.json` sits beside it in the meeting's own folder and is
written through `MeetingStore` like every other meeting artefact — there is no second store
and no second root — and it reaches `notes.md` once, at the end, through
`ScratchNotesMerger.merged(manual:generated:)`, which is pure and idempotent so a second pass
cannot produce two "Your notes" sections. `MeetingScratchNote.singleLine` exists because a
recall row needs one line and a note may hold a paragraph.

**A filter that cannot answer says so; it does not answer a different question.** `MeetingRecall`
has four filters and three sources, and the split is the feature: `.recent` and `.samePeople`
are a pass over the user's own meeting folders and answer on a Mac with every switch off, while
`.sameTopic` needs the search index and `.related` needs the map. `Availability` is a separate
answer from `hits` precisely so the panel can render *"off"* instead of an empty list, and
`reasonUnavailable` is the one sentence for that. **`samePeople` standing in for `related` would
put a confidently-labelled row in front of somebody who asked about a project.** Every hit
carries a non-empty `why`, because a row of meetings with nothing to explain them reads exactly
like a confident answer. There is deliberately no similarity percentage and no matched snippet:
neither is something the query can back up.

**`MeetingScratchpadTidier` is not a second notes pipeline, and it does not write `notes.md`.**
`NotesService` reads the transcript and runs after the meeting; the tidier turns the fragments
*this person typed while the meeting was still running* into a document they can read and keep,
and it writes nothing until they press "Keep this". A pass cut off by its allowance returns
`.cutShort` rather than a shorter document presented as complete, and no provider resolving is
`.noModel` with a plain sentence — never a structure invented from nothing. Its own
`promptBlock` and `parse` are pure so `--selftest-meeting-tidier` can pin them without a model,
which is the only verification available on a machine with none installed.

**The panel must not present under a self-test**, and that is `MeetingConsolePolicy`'s whole
job, for the reason `OnboardingPolicy.shouldPresent` carries: a sheet keeps `NSApp.terminate`
from ever completing, so the run would print its result and hang, and the watchdog would report
a timeout for a run that had already finished. **One animating orb per screen is a property of
`MeetingConsoleSheet`, not a thing four sections each remember**: a section returns a
`MeetingConsoleActivity` and the sheet draws the orb, `.idle` draws none, and the Notes pill's
badge-size orb is `isAnimated: false` precisely so the two shapes cannot both be live for one
job. `--selftest-meeting-console` pins that table, the rail order, the gate, and scans all five
files for a literal value that is not a token.

**The panel has never been seen by an eye, and there is no grant-free way to see it.** That is
the honest state of the whole feature and it is recorded in
`roadmap/done/MEETING-CONSOLE-2026-09-26/` — `00-README.md` for what it is and the five rules it
lives by, `01-PANEL.md` for the five pieces and what must not be undone, `02-VERIFICATION.md` for
every gate and the two defects that running them found. `--settings-sheet` renders panes with
`cacheDisplay`, which needs a hosted window, so there is no equivalent trick for a sheet. Open a
meeting and press ⌘⇧M; that check has not happened yet.

**`gws` prints to stderr when it succeeds, so stderr is not an error channel.** Every run
begins `Using keyring backend: keyring` before it does anything. `GoogleWorkspaceCLI` used to
report the first stderr line as the reason a command failed, which made every Workspace
failure read "Google refused the request: Using keyring backend: keyring" — a sentence that
is not an error and names none, and which sends you to the Keychain instead of to the request
that was actually refused. Failure is judged by exit code; the reason skips the known
informational prefixes.

**`gws ... --dry-run` validates locally and will not catch a bad timestamp.** It happily
echoes `"2026-09-09 14:10"` back as a request body; Google then rejects it, after the user has
already approved the action. Anything time-shaped going to the Calendar API goes through
`WorkspaceToolRunner.rfc3339` first, and the tool schema states the format with an example —
a tool description reading "When it starts." is a specification a small model cannot meet.

**There is no `Permissions.hasSystemAudio`, and adding one makes things worse.** Every other
grant can be asked about, so its absence looks like an oversight. The obvious probe — create a
process tap and destroy it — *succeeds without the grant*: the tap is created, it simply
delivers digital silence. A checklist row driven by that would report "granted" on a machine
that records nothing, which is the one answer worse than "unknown". The row is deliberately
unanswerable until the feature runs, and `--selftest-systemaudio` is the honest test: it fails
with `SYSTEM_AUDIO_SILENT` and says why.

**⌘⇧R is a main-menu command, so it only fires while Next Notes is frontmost — on purpose.**
The obvious complaint is that the one moment you want it is while Zoom has the foreground.
Making it global needs a second `CGEventTap` on a real key combination rather than a bare
modifier, and ⌘⇧R is hard-reload in every browser: swallow it and you break that everywhere,
pass it through and starting a recording also reloads whatever page is open. The menu bar item
("Record meeting now" / "Stop meeting · 12:34") is the global path and needs no tap at all.

**The island panel is always the size of its expanded card.** `IslandPanel`'s frame never
changes; collapsing and expanding happen entirely inside the SwiftUI view. A window
animating its own frame while its content animates its own layout gives two curves fighting
over the same pixels and the seam shows. The cost is that most of that window is transparent
most of the time, which is why `IslandContainerView.hitTest` returns nil outside the island's
own rectangle — without it a notice sitting under the notch would swallow clicks meant for
whatever is behind it for eight seconds.

**The island finds the pointer with event monitors, not an `NSTrackingArea`.** A collapsed
island sets `ignoresMouseEvents`, so the menu bar either side of the notch keeps working —
and a window that ignores mouse events gets no tracking-area callbacks either. Global and
local `NSEvent` monitors see the pointer without taking it. They need no Accessibility grant
(that is only keyboard events), and they are also what tells the island which display the
user is on.

**`IslandGeometry.hasNotch` asks every screen, not `NSScreen.main`.** `main` is the screen
holding the key window, and this app's panels never become key — so with an external monitor
plugged in it answers "no notch" for a MacBook that plainly has one, and the default HUD
placement comes out wrong. The same trap is why `HUDPanel.reposition` falls back to
`screens.first`.

**`gws auth status` exits 0 when nobody is signed in.** The Workspace CLI's exit codes
describe the *command*, not the account — 0 here means "I successfully told you there are no
credentials". So `GoogleWorkspaceCLI.authState` is read out of the JSON fields
(`client_config_exists`, the three credential flags) and never off the status code. The exit
codes still matter everywhere else, and they are the CLI's documented contract: 1 API error,
2 not authenticated, 3 bad arguments. `WorkspaceCLIError` keeps them apart because the app
answers each differently — a 2 sends the user to the Workspace tab, and a 3 is a bug in the
tool catalogue rather than anything they did.

**The agent searches your mail without asking, and can't send anything without asking.**
Both halves are deliberate and they are the whole permission model. `AgentRisk` grades every
tool by what can't be taken back: a read is invisible to everyone else, so with
`agentAutoRunReadTools` on the agent runs one by itself and feeds the answer into its next
round; anything that creates or sends waits for a person, and anything that speaks in the
user's name shows the full message on the card first. An unknown tool name — a proposal
written by a newer build — resolves to `.send`, the most cautious class, so a decoding
surprise can never auto-run. The model proposes and `WorkspaceToolRunner` performs; nothing
else runs a `gws` write.

**Terminal is reached by writing a `.command` file and opening it.** Installing `gws`,
authorising a Cloud project and signing in all happen in front of the user, and `open` on a
`.command` needs no Automation grant — an `NSAppleScript` telling Terminal to run something
would prompt for one, and would leave nothing the user could read afterwards. The scripts
land in `Application Support/Next Notes/Scripts/`.

**A proposal outlives the process.** Unanswered proposals are `proposals.json` in the
meeting's own folder, because the notes land minutes after a meeting ends and get read the
next morning. That is also why `AgentService.decide` falls back to scanning meetings for a
proposal id: a button pressed on a notification left over from a previous launch names a
proposal this process has never seen.

**`CalendarService.refresh()` queues behind the pass in flight instead of returning
early.** The obvious `guard !isRefreshing` was written first and was wrong twice over: a
caller that had just ticked a calendar got a pass that had already read the old settings,
and a self-test awaiting `refresh()` was handed an empty list because the scene graph had
started one concurrently. Chaining keeps the reads serialised *and* guarantees every caller
sees a pass that began after it asked. Do not "simplify" it back to a flag.

**Adding a property to `Meeting` without `decodeIfPresent` orphans every meeting on
disk.** Swift's synthesized `init(from:)` does not use a property's default value as a
fallback for a missing key, so a new field makes every existing `meeting.json` fail to
decode and the meeting simply vanishes from the list. `MeetingModels.swift` therefore has a
hand-written `init(from:)`; new fields go in it as `decodeIfPresent`. `id`, `title` and
`start` stay required on purpose — minting a fresh id would orphan the folder instead.

**An armed meeting's `end` is the time the calendar said, not a time anything measured.**
That is what the overrun rule reads, and it survives a relaunch where an in-memory map would
not; `MeetingSession` overwrites it at stop. The visible cost is that an armed row shows the
scheduled duration. Auto-stop — the overrun and the ten-minutes-of-silence rule — applies only
to calendar-backed sessions: a recording someone started by hand is never cut off for being
quiet.

**The overrun rule listens for speech, and a call is the meeting.** "Stop five minutes after
the scheduled end" is now `CallPolicy.overrunDecision`, and the five minutes is a *grace*
rather than a deadline: it stops there only once nobody has spoken for two minutes, or the
call that covered the meeting has hung up, and never later than end + 60 minutes. A rule that
cut meetings off mid-sentence by design was the cost of a number nobody measured. The
detected-call exemption is unchanged and is now the *data* rather than a branch: `arm` gives a
detected call no `end` at all until the recording stops, and a nil `end` is what the pure
function declines. `Meeting.coveringCallID` (a `decodeIfPresent` field, `CallDetector.identity`
of the call) is the other half: a call that settles inside `CallPolicy.correlationWindow` of a
nearby event starts **that event's own meeting** — its title, its attendees, which the notes
prompt resolves names from — rather than raising a second ad-hoc question beside it, and the
recording ends 60 seconds after that call hangs up, unless the same call comes back. Ten
minutes early used to produce two recordings, the second of which was written off as "Another
meeting was being recorded when this one started" — a failure row for a meeting that was being
recorded; `MeetingScheduler.missedReason` now refuses to write that row when the session in the
way is the meeting's own. The same grace reasoning as `CallPolicy.offThreshold`, read the other
way round: a call that reconnects must not cut a meeting in half, and a recording that outlives
its call by a minute is much the cheaper mistake. One consequence to read before changing the
tick: `mayStartUnattended` is what keeps a meeting armed as a *question* from starting itself,
which is what makes asking the whole of the answer.

**`--fake-calendar` replaces the real providers, it does not join them.** A flag that added
an invented meeting beside the real ones could start recording something that is actually
happening. It is a modifier, not a self-test, and it is the only way to watch
armed → notified → recording → done without waiting for a real meeting.

**The microphone flag flickers, and the debounce is not paranoia.** Sampling
`kAudioProcessPropertyIsRunningInput` at 1 Hz during *continuous* microphone use showed it
read on, then report nobody for three consecutive samples, then read on again. That is
measured on this machine, not feared. So `CallPolicy` announces a call only after it has
held both flags for `onThreshold`, and ends one only after it has been gone for
`offThreshold` — which is five times longer, because a card that lingers a few seconds is a
much cheaper mistake than a card that blinks off and on in the middle of a call. Lowering
`offThreshold` to make the island disappear promptly is the repair that re-introduces the
bug. The state machine is a pure function of (state, observation, elapsed), so
`--selftest-calls` drives minutes of it instantly; the Core Audio subscription underneath is
the part no self-test can reach.

**`corespeechd` holds the microphone with nobody on a call, and Next Notes holds it whenever
you dictate.** Both showed up in the probe, and either one taken at face value arms a
meeting for a call that is not happening — the second one every time the user talks to this
app. Hence the three filters in front of the both-flags rule: our own pid, our own bundle
identifier (a helper or a second copy shares the id but not the pid), and
`CallPolicy.deniedBundleIDs` for the speech and accessibility daemons that hold the
microphone on somebody else's behalf, plus `com.apple.replayd`, which armed a call
question during screen recording (measured 2026-09-23). It is a **denylist, not an allowlist**, on purpose: a
conferencing app nobody here has heard of has to work on the day it is installed. Fathom is
deliberately *not* denied even though it records meetings — it only holds the microphone
during a call, so denying it would suppress a real detection, and the per-app answer in
Settings is where a user who dislikes that says so.

**Chrome is offered only "Ask first" and "Never", and that missing third option is the
feature.** Chrome holding the microphone and the speakers might be a Meet call in a tab and
might be a video conference in a web app nobody has heard of, or a page that opened the
microphone and never used it. Nothing cheap tells them apart — reading the window title over
Accessibility was considered and rejected as fragile. So `CallPolicy.askOnlyBundleIDs`
refuses to record a browser without asking, `availableAnswers(forApp:)` does not offer
"Always record" for one, and `effectiveAnswer(…)` downgrades a stored `always` rather than
displaying a promise the policy will not keep. Google Meet installed as a Chrome web app
carries its **own** bundle id
(`com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan`), is not in that set, and keeps all
three answers — the precise case stays precise. Core Audio names the helper rather than
the browser (`com.google.Chrome.helper`), so every audio process is resolved to its
outermost `.app` before any rule runs — a Chrome tab call arrives as "Google Chrome",
offered only Ask/Never and never recorded unasked. Helper-keyed answers stored before
that fix were migrated to their owners once (`callAnswersOwnerMigrationV1`), keeping the
more cautious answer on a collision and clamping a browser owner's `always` to `ask`.
Related: the app list in Meetings settings is
**empty until an app has actually held the microphone**, because it is a record of what
happened on this Mac rather than a table of bundle identifiers somebody typed. Empty is what
a fresh machine correctly looks like.

**Meetings record two tracks on purpose.** Microphone and system audio are captured,
transcribed and stored separately (left and right channels of `audio.caf` when keep-audio
is on). That is what gives "You / Others" attribution for free and what lets diarization
run on the system track alone. The known cost: with laptop speakers and the built-in
microphone, remote voices bleed onto the mic track.

**Settings states no minimum width of its own, and its two hosts are narrower than each
other.** The same `SettingsWindow` is the standalone ⌘, window — pinned by
`SettingsWindowFrame.pin` to 800pt, which is the system sidebar plus the form — and the
main window's Settings section, where the detail column is as narrow as `detailMin` (560)
and the system sidebar takes 240 of that. A `frame(minWidth:)` on the view cannot tell the
two apart, and in the embedded case it is a demand the host cannot meet: SwiftUI does not
shrink it, it lays the form out at the demanded width and clips it at the window's right
edge — measured on a 1080pt window, every picker's value was cut off mid-word and the
settings sidebar was squeezed to make room. So the minimum is passed in by the one host
that has one (`hostMinimumWidth`, which the ⌘, scene sets from `settingsWindowMinWidth`
and the main window leaves nil), the pane's floor (`settingsPaneMinWidth`, derived as
`detailMin` less the system sidebar) belongs to `SettingsPane`, and nothing else states a
width. `--selftest-settings` hosts every pane at the floor, the embedded window at
`detailMin` and the standalone copy at a narrower proposal than its own minimum, failing if
any of them asks for the wrong width; `--settings-sheet` renders all twelve panes at the
widths they meet so the layout can be *looked at*, which no grant-free self-test can do. Two things that look like they need a fix and do not: the
adaptive card grid needs no narrow-width clamp — a pane narrower than
`settingsCardMinWidth` renders one column at the pane's own width, pixel-for-pixel the same
with the column minimum pinned at 560 — and `--settings-sheet` cannot use `ImageRenderer`
the way `--avatar-sheet` does, because a native grouped `Form` draws nothing into an
`ImageRenderer` pass; it hosts the pane in an offscreen panel and `cacheDisplay`s that.

---

## Design system

`Sources/NextNotes/UI/DesignSystem.swift` defines every colour, size, radius, duration
and material token. **Views must not contain literal values.** If a component needs a number
that isn't a token, add the token rather than inlining it. That rule is the only thing that
survived the redesign.

The direction is **a native macOS app**: `NavigationSplitView` with a sidebar, system
materials, the system font at system text styles, standard controls, `Form { }` with
`.formStyle(.grouped)` in Settings, and `.glassEffect` on the HUD. It should look like it
shipped with the OS, and it should inherit the user's appearance, accent colour and
accessibility settings without a line of code here knowing about them — which is why nearly
every token resolves to a semantic system value (`.controlBackgroundColor`, `.accentColor`,
`.body`) rather than a literal.

The person looking at it is **not technical**, and that is a design rule rather than an audience
note: labels, errors and settings say what a person would say out loud, nothing in the default
path asks for an API key, a terminal command or a file edit, and an advanced flow is opt-in and
explained one plain action at a time. `--selftest-ui-strings` bans the worst words (`cron`,
`artifact`, raw tool ids, schema keys) and `PersonaCareEval` checks the spoken copy; both are the
floor, not the goal.

Inside that native shell the app has **one visual voice of its own**, and it is the same one
as the landing page in `site/`: the dotted orb, the dotted field it is made of, and the
glass pane. Nothing else. The page is the reference implementation — read `site/src/`
before adding to this, particularly `sections/Hero.tsx` (an orb as a large low-opacity
backdrop behind type), `components/HeroStage.tsx` (a small orb labelling each card, a
different state per idea) and `sections/HowItWorks.tsx` (four steps, four different orbs).
The point of all three is that the page never repeats an animation: **each orb state carries
a distinct meaning**, which is only true as long as this file's table below stays true.

This is not a theme. It is the same app, with a vocabulary it previously used in three
places now available everywhere — and it stays native everywhere the system has an answer:
standard controls, standard toolbars, standard `Form` in Settings.

Two colour rules are not negotiable, and they are the same two as before:

- **Red means recording.** `DS.Color.record` appears in `RecordingIndicator` and on the
  Record button while it is active. Nothing else in the app is red.
- **Green, yellow and red on a meter are instrumentation only** — `LevelMeter` and
  `LevelBar`, never UI chrome. Status *text* uses `DS.Color.success` / `.warning`.

Gone with the 1980s field-recorder direction, and not to be revived: `BrushedPanel`, `Well`,
`DeckWindow`, `Silkscreen`, `Screw`, `Vents`, `Lamp`, `TransportKey`, `Readout`, `VUMeter`,
the `Brand` gradient, the HUD `Waveform`, and every chassis/ink/deck/seam token along with
the procedural brushed grain. There are **no gradients on chrome**. Depth comes from the
system's own materials and separators.

Shared components live in `Sources/NextNotes/UI/Components/` — `LevelMeter` (+ `LevelBar`),
`RecordingIndicator`, `ModelStatusRow`, `CopyButton`, `StatusChip` (+ `SpeakerLabel`),
`MarkdownView`, `ProblemBanner`, `FlowLayout`, `ThinkingOrb` in `Components/ThinkingOrbs/`,
and the five pieces the page's vocabulary is built from: `OrbBackdrop`, `DottedField`,
`GlassSurface`, `LabeledOrb`, `SectionHeading` and `OrbUnavailableView`. Sections live in
`UI/<Section>/`, one Settings tab per file in `UI/Settings/`. Reach for an existing component
before writing a new one; three hand-rolled model-status rows is what `ModelStatusRow` exists
to prevent.

| Piece | What it is | The page it comes from |
|---|---|---|
| `.orbBackdrop(_:)` / `OrbBackdrop` | one large, faint, slow orb behind a screen's content | `Hero.tsx`'s 520pt `breathing` ring |
| `.dottedField()` / `DottedField` | the dot lattice as a background, drawn once, never animated | the texture every orb on the page is made of |
| `.glassSurface(…)` / `GlassCard` / `GlassGroup` | the glass pane | `.liquid-glass` in `index.css` |
| `LabeledOrb` | a small orb and the status line it belongs to | the card labels in `HeroStage.tsx` |
| `SectionHeading` | eyebrow, heading, qualifying sentence, optional still orb | every section header on the page |
| `OrbUnavailableView` | an empty state whose illustration is the orb | — |

`ContentUnavailableView` is still right for an absence the system has a symbol for — a
failed search, a missing file. `OrbUnavailableView` is for a **stage**: nothing recorded
*yet*, no account connected *yet*, a model not downloaded *yet*. A grey SF Symbol says the
screen is broken; the right orb says which move comes next.

The glass pane deliberately does **not** port `.liquid-glass`'s rim light. That gradient is
a workaround for CSS having no glass; macOS 26 has one, it draws its own specular edge
against whatever is really behind the pane, and it draws it correctly in both appearances —
where a hard-coded white lip is only ever right on a black page. `.glassSurface` also falls
back to a material under **Reduce Transparency**, which is not a nicety: that setting exists
because refraction behind text is unreadable for some people.

The notch island in `UI/Island/` is the one place that breaks the semantic-colour rule, and
only there: while it hugs the notch its substrate is continuous with the machine's black
bezel, so `DS.Color.island` and `DS.Color.islandInk` are literal black and white. `.primary`
on a permanently black card resolves to black in light mode. Floating below the menu bar on a
display without a notch it uses glass and ordinary semantic ink instead.

### The orb vocabulary

`ThinkingOrb` stands in for a spinner where the wait is minutes rather than frames, and it is
the app's mark besides. All nine upstream states are ported, and **each one means exactly one
thing, everywhere in the app.** They say *which* long thing is happening, which a
`ProgressView` cannot, so picking one because it looks nice here is a lie about what the
machine is doing rather than a style choice. This table is the whole list; if a new situation
does not fit a row, it belongs under the nearest row rather than under a tenth state:

| State | Means | Where it appears |
|---|---|---|
| `listening` | one voice, live, being heard | dictation HUD, island while dictating, the Dictation screen while recording, and its "say something" empty state |
| `weaving` | two audio tracks braided into one meeting | island and Meetings while a meeting records; the Meetings "no meetings yet" empty state |
| `working` | audio being turned into text | transcribing, anywhere — after a dictation release, and a meeting's tracks afterwards |
| `solving` | speakers being told apart | diarization, and only diarization |
| `composing` | the model is writing prose | notes being generated, **and dictation cleanup** — a cleaned-up sentence and a set of notes are the same act at different lengths |
| `searching` | reading things it did not write, to find something | the agent over mail and calendar; also the **no-search-results** empty state, where the word is already the user's |
| `breathing` | present and idle — waiting on purpose, nothing processing | an armed meeting awaiting an answer, every screen **backdrop**, and any "nothing here yet" empty state |
| `connecting` | two parties being wired together | Google / Workspace sign-in and account checks; the "not connected yet" empty state |
| `shaping` | something being fetched and assembled out of nothing | a model downloading, verifying and loading; the "not downloaded" empty state |

Read the other way round, so the mapping is unambiguous for the states a screen has to show:
idle → `breathing`; dictating → `listening`; transcribing → `working`; cleaning up →
`composing`; generating notes → `composing`; diarizing → `solving`; the agent thinking →
`searching`; connecting to Google → `connecting`; downloading a model → `shaping`. An empty
state takes the orb for **its cause**, not its mood: no results → `searching`, nothing yet →
`breathing`, not connected → `connecting`, not downloaded → `shaping`.

### Where orbs may go, and how many

Every orb is a `Canvas` inside a `TimelineView`, re-deriving up to five hundred dots per
frame. This is a laptop.

- **One animating orb per screen.** The screen's ambient backdrop, or the one job that is
  actually running — not both, and never a scattering of small ones. The landing page can
  afford four at once; a window that is also transcribing audio cannot.
- **Decorative means large-and-slow, not many-and-small.** `OrbBackdrop` runs at
  `DS.Motion.orbBackdropScale` and redraws at `DS.Motion.orbBackdropFrameInterval`, which is
  a quarter speed and a third of the frames. Both are what make one 320pt canvas affordable.
- **Never animate an orb that is off-screen, in a collapsed row, or naming work that is not
  running.** `isAnimated:` exists for this, and it is not optional politeness: an orb runs on
  a clock rather than on the work, so one still turning over a finished job is a claim the
  app cannot back up. `SectionHeading`'s orb is still by default for exactly that reason.
- **Reduce Motion freezes them**, and the library already does it — a frozen orb draws no
  `TimelineView` at all, just one canvas at t=1.7.
- **Never `scaleEffect` an orb.** The geometry is a pure function of size; pass a
  `DS.Size.orb…` token as `size:` instead. Scaling magnifies the dot radii along with the
  sphere and turns the lattice into a smear. Above `DS.Size.orbInlineCeiling` the large
  tuning is drawn and below it the inline one, which `ThinkingOrb` decides for itself.

An orb never replaces the red dot: red still means recording and only recording, and the orb
sits beside it saying what kind of work is running. In the HUD it also does not replace the
level bar — an orb animates on a clock, so it would keep dancing over a muted microphone and
answer "is it hearing me?" with a confident yes. Note `connecting` at the inline 20pt preset
draws almost no wires, because upstream's proximity threshold is not a count-scaled key; that
is its tuning, not a porting slip. The geometry in `OrbGeometry` is a port of
[thinking-orbs](https://github.com/Jakubantalik/thinking-orbs) (MIT, licence vendored beside
it); its tuning tables are data rather than view constants and are deliberately not `DS`
tokens.

The **app icon is the orb too**, not a picture of one. `Tools/makeicon.swift` is compiled
*with* `OrbGeometry.swift` by the `icon` target rather than run as a script, so the mark is
the `listening` state at t=1.7 — the same instant `ThinkingOrb` freezes on for Reduce Motion,
picked there because it reads as a diagram rather than as motion caught mid-frame. Change the
animation and the icon follows. It draws the *inline* preset below 96px: the large design's
134 dots are correct at 64pt and turn to grey mud at 32px, which is the whole reason the
library ships two designs instead of one and a scale factor. Monochrome, because an icon with
a gradient would advertise a design this app does not have.

Red is still only ever recording — a recording island shows the same
`RecordingIndicator` dot as everywhere else, with the `weaving` orb beside it saying what
kind of recording it is, exactly as the HUD sets an orb beside the dot and the level bar.

### The agent's character

The app has a second animation vocabulary, and it belongs to the agent rather than to the
work: `Agent/Identity/AgentAvatarState.swift` is ten states that mean exactly one thing each,
the same rule the orbs live under. The character is the Notion-style face the user generates
in onboarding — `AgentAvatarState` says what it is doing, `AgentAvatarChoreography` is the
whole animation specification as a pure function of `(state, time)`, and `AgentAvatarView`
is pixels.

| State | Means | Where it appears |
|---|---|---|
| `idle` | nothing is running; breathing, blinking, glancing | the About hero, the onboarding preview, any portrait between runs |
| `listening` | the microphone is open *for the agent* | the island's agent-listening card (beside the red dot, never instead of it) |
| `thinking` | the model is deciding; no tool has run yet | the pane's thinking row, the island before a step is known |
| `browsing` | reading something it did not write — mail, calendar, a page, a file | the island and working card while a read runs |
| `writing` | producing text: a file, a draft, a command | …while a write or a shell command runs |
| `tool` | running something with an effect — a click, an install | …while an action runs |
| `sending` | saying something in the user's name | …while a send-risk tool runs |
| `waiting` | held up on a person — an approval, an answer, a time | the island's proposal card |
| `sleeping` | ten quiet minutes and it stopped attending | the About hero after `DS.Motion.avatarSleepAfter` |
| `done` | the run just finished; one nod, not a loop | the island's reply card |

The mapping is two-layered and neither layer reads English. A **tool** decides its own state
in `AgentAvatarState.forTool(namespace:risk:)` — risk first, because it says what the call
will *do* rather than where it happens — and it is recorded per step by
`AgentToolExecutor`; everything that is not a tool call reduces from the `AgentActivityKind`
the projector already produced. Never infer a state from a progress title: the titles are
rewritten for the user and the mapping would break the day one is reworded. The island wears
the character only for its four agent states and keeps the orb for dictation, meetings and
notes — the character is the agent's, the orb is the app's.

How it is drawn, and the rules that are not negotiable:

- **Four cached layer bitmaps in one `Canvas`** — under the eyes, the eyes, the brows, over
  them — composed by `NotionAvatarRenderer.layers(for:side:)` from the same vendored parts
  the flattened avatar uses. The blink compresses the eye layer about the canvas centre,
  which is measured, not assumed: every vendored eye part centres its ink on y = 540.
- **Reduce Motion freezes it** at `AgentAvatarChoreography.stillFrame` with no `TimelineView`
  at all, and ambient states (idle, waiting, sleeping) run at
  `DS.Motion.avatarAmbientFrameInterval` rather than the display's cadence.
- **Never `scaleEffect` the portrait** — same rule and same reason as the orbs. A gadget
  badge is the one place a transform is honest.
- **The gadget is hidden below `DS.Size.avatarPropMinimum`** (36pt): at 24–28pt the body
  language is the whole animation, which is why the island badge and the chat rows pass no
  gadget and still animate.
- **A compact row does not animate**: a `List` row draws the still `NotionAvatarView`, and
  the animated one has no `isAnimated` escape hatch on purpose — two live avatars on one
  screen is one too many, and a `List` of them is a battery bug.
- **One place owns the sleep decision** — the view's clock, from `restingSince`, because a
  pane that only re-renders when something happens would show an awake avatar hours later.

The avatar is not the orb and does not replace it: where both could speak, the character is
for the agent's own states and the orb keeps the app's. Red is still only ever recording.

### The dotted field

`DottedField` is the orb's own lattice flattened out and laid behind content: the page has no
separate dot pattern, because its texture *is* the orbs. **It never animates.** A
window-sized field is a few thousand marks, and driving that from a `TimelineView` would cost
more per frame than every working orb in the app put together, for a texture nobody looks
directly at — `Canvas` redraws it only when the size changes, so a field on a screen nobody
resizes is drawn once and then free. It is bucketed into `DS.Field.inkLevels` paths for the
same reason `ThinkingOrb` buckets its dots: a 900×600 field at the default spacing is 3290
lattice points and seven fills. Rows are staggered by half a step and packed at 0.866 of the
column spacing, so it reads as a lattice rather than as a grid lining up with the window's
own edges, and the radial fade dies before the corners so it has no boundary to see.

### Tokens the new vocabulary added

`DS.Size.orbBadge / orbInline / orbSmall / orbMedium / orbLarge / orbFeature / orbBackdrop /
orbBackdropWide` are canvas sides, not scale factors, and `orbInlineCeiling` is where the
tuning changes. `DS.Field` holds the dotted field's dot sizes, spacings, quantization and
falloff. `DS.Opacity.orbBackdrop / orbBackdropStrong / orbWatermark / fieldFaint / field /
fieldStrong` are all an order of magnitude fainter than the landing page's equivalents, and
that is not timidity: the page draws white ink on pure black with nothing else on the canvas,
while a window already carries text, a sidebar and controls in whichever appearance the user
chose. The test a backdrop has to pass is that you notice it only once you go looking.
`DS.Motion.orbBackdropScale / orbAmbientScale / orbBackdropFrameInterval /
orbAmbientFrameInterval / reveal / ambient` are the motion curves for ambient work.
`DS.Radius.glass / glassSmall / field`, `DS.Space.page / section / card / cardTight /
orbGap / xxxl` and `DS.Font.eyebrow / eyebrowTracking / emptyStateTitle / emptyStateMessage`
are the layout and type this vocabulary needs. As always: if a view needs a number that is
not here, add it here rather than inlining it.

## macOS specifics

**Ad-hoc signing is not "unsigned", it is a new identity every build.** An ad-hoc signature
is a hash of the binary, so the designated requirement reads `cdhash H"…"` and changes with
every compile. TCC stores that requirement beside each grant, so Accessibility, Audio
Recording and Notifications are all invalidated together by every `make install` — and the
symptom lies twice over: the toggle still reads as on, and *toggling it off and on does not
repair it*, because what is stale is the stored requirement, not the switch. The only fix for
a wedged row is `tccutil reset <service> ai.pivotstudio.nextnotes` (never without the bundle
ID), then re-grant.

`make signing-cert` ends this. With a stable certificate the requirement becomes
`identifier "ai.pivotstudio.nextnotes" and certificate leaf = H"…"`, which is **identical
across rebuilds** — verify with `codesign -d -r-` before and after a build. Creating the
certificate through Certificate Assistant is easy to get wrong and fails silently; the
reliable route is openssl, and two traps are worth knowing: OpenSSL 3 writes PKCS#12 that
macOS rejects with a misleading "wrong password" unless `-certbe/-keypbe PBE-SHA1-3DES
-macalg sha1` are given, and an imported self-signed certificate reports **zero** identities
until `security add-trusted-cert -p codeSign` is run on it.

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.nextnotes
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Windows specifics

The specifics below were expensive to establish and several were found the hard way. Treat
them as load-bearing. Full detail in `windows/README.md` and `docs/PARAKEET-WINDOWS.md`.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**`NextNotes.App` loads the platform layer by reflection, not by reference.** A direct
reference would force the UI onto `net10.0-windows` and you would lose the ability to run it
on your own machine. Two consequences that have already bitten once: the assembly is
invisible to `PublishSingleFile`, so it is published as a loose file beside the exe *and*
resolved by an explicit `AssemblyLoadContext` handler; and the published self-test checks
this, because when it breaks the app starts perfectly and then does nothing at all when the
key is pressed.

**Keep `NextNotes.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

---

## Regex, if you touch the dictionary

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **Notarization** (macOS) and **code signing** (Windows). `make dmg` and the
   tag-triggered GitHub Release exist, but the image is ad-hoc or locally signed until
   a Developer ID is in CI, so Gatekeeper still refuses a downloaded copy. Windows
   users will meet SmartScreen.
2. **An installer** for Windows, and model download from inside the app rather than by
   following `docs/PARAKEET-WINDOWS.md` by hand.
3. **A Claude-backed cleanup or notes provider.** `TextFormatter`, `TextCommandProcessor`
   and `LLMProvider` are all seams for one; there is no credential storage or network path.

## What has never run, on macOS

Distinct from the list above: these are written, compile, and have a self-test wherever one
is possible, but the permission, model or account they need has never been available on the
development machine. Treat anything here as unproven, and do not describe it as working.

- **The character on the notch, by eye.** Every avatar state has been rendered offscreen by
  `--avatar-sheet` and reviewed that way (2026-09-23), and `--selftest-avatar` pins the
  vocabulary — but nobody has seen the animated portrait on the collapsed island strip it
  was designed for, because seeing it there means a Screen Recording grant and a live
  notch. Treat the island placement as reasoned, not observed.
- **The screenshot and vision path with real pixels.** `ScreenCapture` has never captured a
  real window (ScreenCaptureKit needs Screen Recording and a live window) and no consent
  sheet has been shown. The seam that had gone missing — **`completeWithImages` with no
  production call site** — was found unwired during the 2026-09-22 roadmap audits and
  re-wired the same day at the tool loop's result seam, pinned by
  `--selftest-computer-vision`; but no screenshot has ever been described by a vision
  model on this Mac, because that needs Screen Recording, a live window and a model.
  Screenshots work locally for the working card's live view (memory only); nothing has
  been uploaded.
- **The Portrait pass, Corners and the D4 assembler with real material.** All three are
  code-complete and pinned by `--selftest-portrait` / `--selftest-assemble`, but on this
  machine they have only ever run against fixtures and an injected model: no real graph
  has been mined into insight drafts, no real corpus assembled into a page, and the
  quality of the prose is unmeasured (the local model they route to is not installed;
  the graph here has two meetings). The first-ingestion consent gate has never met a real
  connected account either — its honest no-consent-path refusal is what is enforced.
- **The wake word in a real room.** The 2026-09-22 tuning pass took the measured
  trade-surface maximum on the synthetic corpus (17/24 hits @ 3/32 false at the shipped
  default, `--selftest-wake-live` still red at its 0.8 bar); the missing clips are
  synthetic-voice rows, and `WAKE_MIC` has no captures here. The remaining fix is
  real-room recordings, not a lowered bar — `--wake-mic-record` is the recorder that
  produces them, and it has never been run with a live microphone either.
- **The podcast routine with real voices.** `LongFormRenderer`'s production synthesis
  (`LongFormSynthesisFactory.live()`, Pocket/Kokoro frame paths) has never rendered a real
  file — neither voice model is downloaded here — and no scheduled run has produced a
  Library audio item. The scripted self-test runs entirely through an injected fake.
- **The system-audio tap with its TCC grant.** Every call succeeds without it and every
  sample is zero, so no meeting has yet contained an "Others" track.
- **Gemma 4 E4B.** Never downloaded (~9 GB of free disk is needed: 4.98 GB plus the
  downloader's 4 GB reserve), so `NotesModels.spec.expectedSHA256` is still `nil` — the
  downloader logs the computed digest and the next agent to get it pins it. An earlier
  version of this entry said every notes and agent run had gone through Apple Foundation
  Models; `metrics.jsonl` shows that was false for the agent side — installed GGUFs loaded
  for agent turns on 09-22 and 09-23 (MiniCPM5-2B, the active model until P0-01 replaced it
  with Qwen3-4B-Instruct-2507). Meeting notes still fall back to Apple's model while the
  built-in Gemma is absent.
- **Both real calendars.** EventKit reports `.notDetermined` here; Google has never had an
  account connected, and needs the user's own Desktop-type OAuth client (id *and* secret —
  Google's installed-app client type requires the secret at the token endpoint even with
  PKCE).
- **Every Workspace write.** `gws` is signed in on this Mac — a refresh token and 21 scopes
  including Gmail, Calendar, Drive and Docs — so the agent's own reads reach the account. No
  write proposal has ever been approved, so `WorkspaceToolRunner` has never performed a
  write; each tool's flags were checked against `gws <service> <helper> --help`, not against
  a live call.
- **The screen-name harvest, beyond one Cursor window.** `Sources/NextNotes/Context/` reads the
  file, folder and tab names out of Cursor, Windsurf or VS Code at key-down so a spoken "the
  login handler file" resolves to the real name. **It has now run against a real Cursor window
  and works:** on 2026-09-16, with the Accessibility grant and `editor.accessibilitySupport` on,
  `--selftest-context` returned 43 names — explorer files and folders with project-relative
  paths, the open tabs, the project root — in 133–142 ms (optimized) and 141–143 ms (debug),
  six runs each, with nothing truncated. The run on 2026-09-10 that came back with zero names
  and `stub tree` was **not** the setting being off, as this entry used to say. It was the walk:
  a depth limit of 12 in a tree whose names sit at depth 25–31, identifier matching on
  `AXIdentifier` when Chromium only exposes `AXDOMIdentifier`, and a stub check that fired on
  any walk its own limits had cut short. The comments at `AXHarvester.Budget` and
  `domIdentifierAttribute` carry the measurements. What is still unproven: Windsurf and VS Code
  have never been walked, so their adapter rows remain copies of Cursor's; nobody has checked
  whether these editors really expose nothing with the setting off; and no spoken file name has
  yet gone through a real dictation into the cleanup pass and out as a tag. One consequence of
  the measured time is known rather than suspected: the speech engine waits only 60 ms for the
  harvest (`AppleSpeechEngine.context()`), so in Cursor the harvested bias slice never arrives
  and the engine is biased by the dictionary alone. The cleanup pass still gets every name.
- **The redesigned UI, by eye.** Screenshots need Screen Recording and driving the UI needs
  Accessibility; neither can be granted non-interactively. Nobody has seen the sidebar, the
  onboarding sheet, or the island expand out of the notch.

## What no amount of CI can verify

On Windows, nobody has yet held the key and spoken. Specifically unverified:

- Text injection landing in a foreground app — runners have an interactive desktop but
  cannot take the foreground.
- A real microphone: format negotiation, the OS privacy block, unplugging mid-capture.
- The keyboard hook firing on a physical keypress.
- Parakeet transcribing real speech, and whether ~2 GB resident is tolerable.

Everything those feed into is behind an interface and tested with fakes. The bindings
themselves are not. **First real-hardware run should start with `--selftest`, then a single
short dictation into Notepad.**

**Voice work and output have separate lifetimes.** Provisional novel microphone recognition pauses the current reply reversibly;
only a committed user turn calls `userSpeechStarted`, which stops output while retaining
the work objective and completed results. Explicit cancellation invalidates work. Do not turn every acknowledgment into a
cancellation. Model/read budgets exclude waiting for the user's floor or an approval.
`VoicePlaybackDelivery` records output acknowledgements separately from generated results;
a completed clause is not proof of physical audibility. The on-device model's single native
context must be reserved before acquiring its compute scheduler ticket, or actor reentry can corrupt
its inference state and reverse lock order can deadlock. The voice lifecycle, delivery,
and scheduling self-tests exercise these boundaries without a microphone.

**Live conversation has a different model owner from tool work.**
`VoiceConversationCoordinator` routes local Foundation Models responses and keeps separate
on-device workers alive. A microphone commit clears `RealtimeAgent.voiceInputActive` but must
not clear the coordinator's effect barrier until the latest input has been classified.
Otherwise a correction can allow an old effect, or an uncleared floor can deadlock the
response. `--selftest-concurrent-voice` and `--selftest-voice-conversation` cover both.
On-device prefill must checkpoint between batches, and its background warmup must not acquire
the same priority as the conversational frontend. `NotesModelRuntime.prewarmWorkClass(voice:)`
is the one place that decides the lane and both routes warm at `.background`: equal priority
does not preempt, so the old `.realtimeAgent` warmup queued the next spoken turn behind a
cold load's 11–25 s of weights and prefill. `--selftest-voice-scheduling` fails if the
prewarm lane blocks a realtime acquire.

**Echo suppression and EOU require the real producer.** Mixer PCM feeds SpeexDSP before
Agent ASR/VAD. `SPEEX_PREPROCESS_SET_ECHO_STATE` takes the state pointer itself; disabling
Speex denoise also bypasses residual echo suppression. Digital speech replay includes
the documented DSP delay and must preserve a distinct overlapping voice. The physical
`--selftest-acoustic-live` additionally requires audible speaker bleed and real mixer
frames. Neither a fake playback callback nor a silent microphone passes. FluidAudio EOU
operations must remain serialized across awaits; its actor can reenter during inference.

**On the conversational path, a deterministic gate may only add, never subtract.** The
`VoiceConversationCoordinator` runs repair and routing rules before the on-device frontend
model: hesitation, pending-intent acknowledgments, the tool-shape route, and the known-noise
list. Repair (dictionary) and routing (tool-shaped requests) are safe by direction — they
give the model more, not less. A rule that *suppresses* the model must earn it twice: it may
only match **exact signatures** (the `VoiceTurnPolicy.knownNoiseFragments` list — never
length, token count, or any other shape heuristic), and it may fire **once per distinct
utterance per session**, with the repeat escalating to the model. The shape version of this
gate shipped on 2026-09-22 and clarified "Can you hear me?" five turns in a row:
`normalize()` strips leading fillers ("can", "you"), so a four-word question became a
two-token fragment and the app stopped answering its user entirely. The fixture set that
would have caught it — a positive corpus of ordinary questions — lives in
`--selftest-voice-turn-routing` beside the junk corpus; the junk list without the positive
corpus is how a green suite coexisted with an unusable app. `--selftest-voice-turns` grades
the list itself.
