# D-16 spike — Parakeet vocabulary boosting, and Terminal title context

Task: `roadmap/in-progress/DICTATION-MEETINGS-LIMITS/01-DICTATION.md` §D-16. Spike, no product
code; the ledger row is deliberately `n/a (report)`.

Date: 2026-09-25 (measurements taken 2026-09-25 → 2026-09-26, this Mac).
Machine: 8-core, 24 GB, 12 GiB free on `/` at the time (`df -h /`).
FluidAudio: **v0.15.6, revision `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`** — the exact
checkout `Package.resolved` pins, verified with `git -C …/checkouts/FluidAudio describe --tags`.
Everything below about the app was read, not assumed, and everything below about the machine was
measured. Where there was nothing to measure, it says so.

**Verdicts, up front**

| # | Question | Verdict | Deciding number |
|---|---|---|---|
| 1 | Vocabulary boosting for the batch TDT path the app uses | **feasible; recommend-DEFER (evidence-gated)** | works — 70%→100% term hits — but only with `spotterRescueEnabled: false`, and the measured demand is 7 corrections in 226 dictations (3.1%) |
| 2 | Title-derived context for Terminal | **recommend-DO the small part, recommend-DEFER the ambitious part** | tab `AXTitle` carries the absolute cwd, read in **0.6–0.9 ms**; the window `AXTitle` does **not**; AppleScript costs 90–100 ms and returns less |

The two questions have the same shape: one cheap honest answer hiding inside an expensive
impressive one, and the expensive one is what the task text asked for.

---

# Question 1 — Vocabulary boosting for Parakeet (FluidAudio)

## 1.1 What exists today

`ParakeetEngine` calls exactly one FluidAudio API for transcription
(`Sources/NextNotes/Transcription/ParakeetEngine.swift:235`, and the same call in `runPartial` at
`:318`):

```swift
let result = try await manager.transcribe(ParakeetInput.padded(samples), decoderState: &decoderState)
text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
```

`manager` is `AsrManager(config: .default)` (`ParakeetEngine.swift:426`), the **TDT batch** manager.
It takes no vocabulary, no hotwords, no context and no language hint, and the app keeps only
`result.text`. `Sources/NextNotes/Context/`'s harvested names reach exactly one engine —
`AppleSpeechEngine.swift:152,160` builds `store.biasPhrases(withHarvested:)` and waits 60 ms for
the walk — so on this Mac, with Parakeet as the engine, the whole screen-context harvest is
collected and then given to an engine that cannot use it. That is I1-26, and it is real.

**Does vocabulary boosting apply to the batch path?** Measured answer, in two parts.

**(a) The convenience API is not there.** `configureVocabularyBoosting(vocabulary:ctcModels:config:)`
exists in exactly three places in the whole checkout:

```
$ grep -rn "func configureVocabularyBoosting" ~/Library/Caches/NextNotesBuild/scratch/checkouts/FluidAudio/Sources/FluidAudio
./ASR/Parakeet/Unified/StreamingUnifiedAsrManager.swift:223
./ASR/Parakeet/Unified/UnifiedAsrManager.swift:205
./ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift:92
```

All three are streaming managers. The TDT batch target has none. (The 85 hits for
"vocabulary/boosting/biasing" in `ASR/Parakeet/SlidingWindow/TDT/*.swift` are all
`AsrModels.vocabulary` — the model's own id→string table — not a biasing hook. Verified by
reading every one.)

**(b) The capability is reachable anyway, and this is the part that changes the answer.**
`VocabularyBoostingSession` is deliberately engine-agnostic
(`CustomVocabulary/VocabularyBoostingSession.swift:5-9`: "so the session is independent of which
primary model produced the transcript — any engine that can supply its transcript, token timings,
and the audio behind them can use it"). Its whole public surface is:

```swift
public init(vocabulary: CustomVocabularyContext, ctcModels: CtcModels, config: VocabularyRescorer.Config? = nil) async throws
public func rescore(text: String, tokenTimings: [TokenTiming], audioSamples: [Float]) async -> VocabularyRescorer.RescoreOutput?
```

The batch path supplies all three: `ASRResult.tokenTimings` exists
(`ASR/Parakeet/AsrTypes.swift:81`, and `ASRResult` even carries unused
`ctcDetectedTerms` / `ctcAppliedTerms` fields), and the app is already holding the samples. So
**no engine change is required**: `ParakeetEngine.finish()` would keep `result.tokenTimings`
instead of `.text`, call `session.rescore(...)`, and use the returned text. Measured token
timings were present in **5/5** runs (35, 36, 37, 39, 53 timings), never nil.

That is the whole integration: ~15 lines plus a second model cache. This is not a research
problem, it is a wiring problem.

## 1.2 What the extra model is, how big, under what licence

Vocabulary boosting needs a **separate CTC model** to spot keywords in the raw audio. Two exist
(`ModelNames.swift:8-9`):

| Variant | HF repo | Repo total | What the app would load | Licence |
|---|---|---|---|---|
| `.ctc110m` | `FluidInference/parakeet-ctc-110m-coreml` | 106.0 MB | **102 MB measured on disk** after `loadWithCtcTokens` | `cc-by-4.0` (HF `cardData.license`), ungated |
| `.ctc06b` | `FluidInference/parakeet-ctc-0.6b-coreml` | 2 974.2 MB (int8 encoder alone 597 MB) | — | **no licence field on the card** |

(Sizes from the HF blobs API, `?blobs=true`, summed per file.)

`.ctc110m` is the only viable one, and upstream says so: the variant's own doc comment reads
"Use TDT for transcription + CTC for vocabulary scoring via constrained CTC rescoring" and warns
that both greedy decoders are broken (`ctc110m` blank-dominant ~113% WER; `ctc06b` ~158% WER).
`.ctc06b` is also 2.97 GB against the free disk the task warns about, and shipping a model with
no stated licence is not a decision this repo can make — `AGENTS.md`'s licence rule requires every
model's terms to be known, and it is only a constraint because a previous one was not.

`cc-by-4.0` is compatible with this repo's rule (not GPL-incompatible, not source-available-only)
and models are downloaded at runtime, not distributed, so `THIRD-PARTY-NOTICES.md` gains nothing
here. **Licence is not a blocker; disk and latency are.**

## 1.3 The measurement

Five fixtures generated per the task's recipe — `say -v Samantha -r 170 -o f*.aiff` then
`afconvert -f WAVE -d LEI16@16000 -c 1` — 5.79–7.67 s each, 31.73 s total, in
`~/Library/Caches/NextNotesBuild/dictation-meetings/fixtures/` (never in the repo). Each fixture
says two of ten **terms** taken from `~/Library/Application Support/Next Notes/dictionary.txt` (the
left-hand sides with no arrow), in a normal sentence with filler so each clip is about six seconds
of speech rather than three words:

| Fixture | Terms it says |
|---|---|
| f1 | `clark`, `ProductFlo.io` |
| f2 | `Kajo`, `OLAMA` |
| f3 | `Egging`, `Quentin 2.5` |
| f4 | `chatgpd`, `NetNet` |
| f5 | `mini cpm`, `Gma` |

The harness is a throwaway SPM package at
`~/Library/Caches/NextNotesBuild/dictation-meetings/spike/` (path-dependency on the pinned
checkout) that loads TDT v3 with the app's own arguments
(`encoderPrecision: .int8`, `encoderComputeUnits: .cpuAndNeuralEngine`), calls
`CustomVocabularyContext.loadWithCtcTokens` on a ten-line text file, builds one
`VocabularyBoostingSession`, and for each fixture runs the batch pass and then `rescore` over the
same buffer. **A hit is the term's normalised form (lowercase, non-alphanumerics stripped)
appearing anywhere in the output**; both sides are judged the same way, and the raw transcripts
are printed so a reader can check by eye.

Note the limitation up front: these are TTS voices, not a person. They establish whether the
mechanism works, at what latency, and — as it turned out — how badly it can misfire. They are not
a claim about the owner's real recall.

### The four configurations, all on the same five clips

| Configuration | Vocabulary | Term hits | Ordinary prose replaced by a term | Rescore cost |
|---|---|---|---|---|
| no boosting (today's app) | — | **7/10 = 70%** | 0 | — |
| `VocabularyBoostingSession` **as upstream ships it** | 10 terms | 8/10 = 80% | **11 spans** | 0.703 s per 10 s audio |
| same, session rebuilt per fixture | 2 terms | 10/10 = 100% | **6 spans** | 1.515 s per 10 s audio |
| **+ `VocabularyRescorer.Config(spotterRescueEnabled: false)`** | 10 terms | **10/10 = 100%** | **0** | **0.669 s per 10 s audio** |

The default configuration is the finding. Every fixture lost text to it:

```
f1  baseline: … The numbers for this week are in the shared folder and the summary is already written.
    boosted : … The numbers for this Egging NetNet the summary is already written.
    replaced 'week are in'      → 'Egging'  — 'Egging'=-1.63   > 'week are in'=-7.65
    replaced 'the shared folder and' → 'NetNet' — 'NetNet'=-1.80 > 'the shared folder and'=-7.09
f5  baseline: … save the output next to the other results from this month.
    boosted : … save the clark to the Egging OLAMA
```

This is upstream's documented failure mode, reproduced: `ContextBiasingConstants.swift` on
`defaultSpotterRescueEnabled` says the spotter-anchored acoustic rescue "is also the dominant
source of short-keyword over-firing (#702) — on a 90-clip short-distractor set, disabling it drops
false-positive insertions from ~94 to ~19", and that its own benchmarks found the gate "strict
enough to suppress short-vocab false positives also costs KWS recall". A ten-term **user
dictionary** is the worst case for it: nine of those ten terms are distractors in any given
utterance, because the user did not say them.

Turning it off is not a fork and not an env var: `VocabularyRescorer.Config.spotterRescueEnabled`
is a public init parameter (`VocabularyRescorer.swift:66,78`) and
`VocabularyBoostingSession.init(…, config:)` passes it through. With it off, all five fixtures came
back with the prose untouched and the right word in place:

```
f1  'product flow I.O.' → 'ProductFlo.io'    (-5.70 > -13.50)
f2  'Alama'             → 'OLAMA'            (-5.73 > -11.10)
f4  'chatbot'           → 'chatgpd'          (-5.87 > -11.93)
f5  'the mini CPM'      → 'mini cpm'         (-3.71 > -10.23)
f3  'Quentin 2.5 twice,'→ 'Quentin 2.5'      (-10.45 > -15.48)   ← punctuation only, term already right
```

So the honest headline is: **the technique works, and it is one boolean away from working
well.** Nothing about the batch path is a dead end.

### Cost

- **Per-utterance latency: 0.067 s per second of audio** (0.669 s per 10 s), measured across
  31.73 s of audio. The TDT pass on the same clips took 0.769 s total (0.024 s per second of
  audio, 41× realtime), so the boost adds **+252%** to the ASR leg. On a 6-second hold that is
  about +0.4 s.
- **Against the app's own numbers** (`~/Library/Application Support/Next Notes/metrics.jsonl`,
  n=14 real holds): `dictation.transcribe` median **0.380 s**, mean 0.632 s, max 2.155 s. Boosting
  would roughly double that leg — the release-to-final-text number, on the user's critical path,
  for a fix worth 3.1% of dictations (below).
- **One-time: 102 MB download and 25.5 s to load + tokenize** (measured on a second run with the
  models already on disk, so that is *load* time, not download). It would have to be resident to
  be free per-turn, which is another ~100 MB of RSS alongside Parakeet's 461 MB — on a machine
  where the notes model already unloads itself ten minutes after use for exactly this reason.
- **Partial coverage, by construction.** `rescore` is a post-pass, so it would apply only to the
  final batch. The live partials the HUD shows, and the `reuseBelowSamples` promotion path
  (`ParakeetEngine.swift:210-222`), would keep unboosted text — meaning a dictation short enough
  to be promoted from a partial would never be boosted at all, and the user would see the wrong
  text in the HUD while the correct text is injected.

### What it would be worth, measured from this owner's own history

`runs.jsonl`, 226 dictations, 2026-09-10 → 2026-09-24:

- **7 runs (3.1%) have a dictionary correction recorded at all**, and 6 of those 7 are the same
  pair: `product flow` → `ProductFlo`. The seventh is `Groc` → `Grok`.
- Whole-term matches (the engine already got the term right, so boosting had nothing to do):
  7/226 = 3.1%, one run per term.
- 3/226 (1.3%) mention a file name with an extension, and all three are `.md` roadmaps.

That is the demand curve for the whole feature on this machine, read off the store that records it.
A 102 MB second model, ~100 MB resident, ~25 s of load and +0.4 s on a 0.38 s median leg buys
correctness on 3.1% of dictations — and the 2.6 points of that are a single recurring mis-hearing
that the existing `X → Y` correction path already fixes for free.

### Verdict: recommend-DEFER, evidence-gated

Not won't-do: the mechanism is measured working (70% → 100% with zero collateral damage at one
flag), the integration is ~15 lines, the licence is fine, and the disk fits. Defer because the
price is a second resident model and a doubled ASR leg, and the measured demand is 7 dictations
out of 226. If it is ever built, the task must carry three non-negotiables, all of them learned
here:

1. `VocabularyRescorer.Config(spotterRescueEnabled: false)`, or the feature types product names
   into ordinary prose. Eleven corrupt spans in five clips is not a tuning nit.
2. Cap the vocabulary at ten terms (`ContextBiasingConstants.largeVocabThreshold` is the same
   number upstream picked, and my per-fixture 2-term run shows size is *not* what saves you — the
   flag is — so the cap is about prompt/rescorer cost, not safety).
3. Boost the final pass only, and say so in the HUD path — or the user watches text that is about
   to be replaced.

**Revisit trigger, which this repo can measure on its own:** `runs.jsonl` `corrections` is a live
counter. If corrections on *product-name* pairs (as opposed to ordinary words) pass 5% of
dictations over 100 holds, the numbers above stop being an argument. Nothing about this needs a
roadmap entry to be honest; it needs the counter.

## 1.4 The `language:` hint, measured (it is not a language fix)

`00-README.md` §1.6 is right that the hint cannot tell French from English, and this run shows
*why* — and adds the part §1.6 does not say. Same fixture f1, same buffer, three runs:

```
language=nil  0.170s  Open the Clark report and then the product flow I.O. dashboard. The numbers for this week are in the shared folder and the summary is already written.
language=fr   0.209s  Open a Clark report end then, product flow.io dashboard.Tnumbers for Deke Are in a shared folder, a summary is already written.
language=en   0.188s  Open the Clark report and then the product flow I.O. dashboard. The numbers for this week are in the shared folder and the summary is already written.
```

`nil` and `en` are byte-identical; `fr` is materially worse on English speech. Two mechanisms
explain it, both in the code:

- `TokenLanguageFilter` partitions by **Unicode script only** (`Shared/TokenLanguageFilter.swift:39-53`:
  French, English, Spanish, German … all `.latin`; only Russian/Ukrainian/… are `.cyrillic` and
  Greek is `.greek`). The filter fires only when top-1 is outside that script
  (`TdtDecoderV3.swift:673-698`), so it cannot distinguish two Latin languages — and the
  `Script` doc says so outright: "a per-language token allowlist (Polish vs Czech etc.) could
  plug in here later".
- The one non-script behaviour is `TdtDecoderV3.englishBlocklistApplies(to:)` at
  `TdtDecoderV3.swift:623`: `language == .french`. Passing `.french` switches on an **English-token
  blocklist** (upstream #840, "non-English Latin language corrupts clean speech").

So the hint is a *French mode* switch, not a language detector, and on English speech it is
harmful. **Confirmed: do not wire it as the language fix.** Recorded here so the next reader does
not re-derive it, and because the measured `fr` output is the kind of thing that looks like a
model bug rather than a mode.

---

# Question 2 — Title-derived context for Terminal

## 2.1 What exists today

`AXAppAdapters.all` (`Sources/NextNotes/Context/AXAppAdapters.swift:44-75`) has three rows:
Cursor, Windsurf, VS Code. There is no Terminal row, so:

- `AXHarvester.harvest` returns `.noAdapter` before touching the tree
  (`AXHarvester.swift:89-91`);
- `ScreenContextStore.beginCapture` returns `false` without starting a walk
  (`ScreenContextStore.swift:84`);
- and `dictation.names` is a no-op. Measured on this Mac: **12 rows in `metrics.jsonl`, eleven at
  ≤ 1.7 ms, one at 13.2 ms** — and that span is the *narrowing* step
  (`DictationController.swift:1743`, `narrowedAt - transcribedAt`), so it is fast because there is
  nothing to narrow, not because the harvest is cheap. Consistent with D-16's premise.

Also worth stating plainly, because it changes the framing: `runs.jsonl` **cannot** answer "how
many dictations went into Terminal". `DictationRun` (`Sources/NextNotes/Support/RunLog.swift:6-98`)
has `date`, `engine`, `audioSeconds`, `processSeconds`, `text`, `group`, `corrections`,
`editedText`, `cleanup` — no target application, ever. The "Terminal 19×, Claude 19×" distribution
in the task text came from somewhere this store does not keep. What the store does answer is in
§2.3.

## 2.2 What Terminal's accessibility tree actually contains (measured)

Throwaway probes at `~/Library/Caches/NextNotesBuild/dictation-meetings/spike/axtitle.swift` and
`axprobe2.swift` / `axprobe3.swift`, compiled with `swiftc -O`, walking Terminal's focused window
with the harvester's own budget (per-element 25 ms timeout, depth 40, 1 500 nodes, 250 ms clock).

**A bounded walk is cheap and nearly empty.** 28 nodes, max depth 4, **22 ms** complete: 12
`AXButton`, 4 `AXRadioButton`, 3 `AXStaticText`, one `AXScrollArea` → `AXTextArea`, one
`AXTabGroup`, one `AXGroup`. Five `AXIdentifier` values, all AppKit's own (`_NS:136`,
`_closeButton`). For comparison, the Cursor walk in `AXHarvester.Budget`'s comment is ~700 nodes
and 133–177 ms. There is nothing to walk, and nothing to walk *fast* matters: 22 ms of a 250 ms
budget for 28 nodes is all the tree there is.

**The roadmap's question 3 — does the window `AXTitle` carry the working directory? No.**

```
focused window title: speechify — OC | NextNotes roadmaps implementation plan — opencode --auto — 279×69
```

Terminal composes the *window* title from the **basename** of the working directory, the process's
own OSC title, and the window size. The path is gone, and when a full-screen TUI owns the terminal
even the basename is replaced — which is what happens on this Mac, where all four tabs are
`opencode`. Anyone reading the window title is reading a string the running program controls.

**The tab titles do carry the full path.** `AXTabGroup` → `AXRadioButton` children:

```
tab[0] title=/Users/sergekadjo/Documents/Claude/Projects/speechify — OC | Implement AGENT-OVERHAUL roadmap items — opencode --auto
tab[1] title=/Users/sergekadjo/Documents/Claude/Projects/speechify — OC | Dictation meetings limits roadmap imp… — opencode --auto ▸ python3
tab[2] title=/Users/sergekadjo/Documents/Claude/Projects/speechify — OC | NextNotes roadmaps implementation plan — opencode --auto
tab[3] title=/Users/sergekadjo/Documents/Claude/Projects/speechify — OpenCode — opencode --auto
```

4/4 real tabs, the absolute cwd as the first ` — `-delimited field. And reading *only* that is
nearly free — `axprobe3`, five consecutive runs:

```
run 1: 22.1ms  4 cwd(s)     ← cold
run 2: 0.7ms   4 cwd(s)
run 3: 0.6ms   4 cwd(s)
run 4: 0.9ms   4 cwd(s)
run 5: 4.3ms   4 cwd(s)
```

**0.6–0.9 ms warm.** No tree walk, no new permission: it is the same Accessibility grant the
harvester already needs and already has (`AXIsProcessTrusted() == true` in the probe).

**The text area is readable — and useless, and a privacy problem.** `AXTextArea`'s `kAXValue`
returned **19 466 characters**, which is the entire terminal scrollback: the shell prompt
`(base) sergekadjo@SergeMcAir-2 speechify % opencode --auto`, every command, every stack trace,
and (in this session) a whole TUI screen. It contains file names — which is tempting and is why it
must not be used: it is program output, not a list of names the user chose, it changes on every
keystroke, and it is exactly the region `AXAppAdapters.editorWorkbenchIgnored` refuses to walk in
VS Code (`AXAppAdapters.swift:101-113`: "they are enormous, they change every keystroke, and their
contents are program output rather than names the user can refer to"). `ContextPrivacyFilter` would
also have to be trusted to strip it, and a Terminal's scrollback is the single most sensitive
surface on the machine.

## 2.3 The AppleScript candidate, and its price

Both candidate routes work from a shell that already holds the relevant grants, and both are
**worse on every axis than the AX tab read**:

| Route | 5 runs (`/usr/bin/time -p`) | Returns | New grant needed by the app |
|---|---|---|---|
| `tell application "Terminal" to get name of front window` | 0.09, 0.09, 0.09, 0.09, 0.10 s | the **window** title — no cwd | **Automation** (Apple Events) for `ai.pivotstudio.nextnotes` |
| `tell application "System Events" to tell process "Terminal" to get value of attribute "AXTitle" of window 1` | 0.09, 0.10, 0.09, 0.09, 0.10 s | identical string | **Automation for System Events** *and* Accessibility |
| AX read of the tab group's titles (recommended) | 0.0006–0.004 s | the **absolute cwd**, per tab | nothing (Accessibility, already held) |

So: 90–100 ms against 0.6–0.9 ms (**100–150×**), a string with less in it, and a new Automation
prompt — for a permission this repo has a written position on. `WorkspaceInstaller.swift:13` and
`AGENTS.md` both state the rule: Terminal is reached by writing a `.command` file and opening it
precisely because "an `NSAppleScript` telling Terminal to run something would prompt for one, and
would leave nothing the user could read afterwards". The same reasoning applies to *reading*:
Next Notes is a background app, its Automation grant would be a one-time dialog on a path the user
is waiting on, and the value returned is worse. **The AppleScript candidate is rejected on
measurement, not on principle.**

## 2.4 What a Terminal adapter could honestly produce

Being precise about this is the point of the section. A cwd's own path components are all it has:

- **A project root** — `/Users/sergekadjo/Documents/Claude/Projects/speechify` →
  `ScreenContext.projectRoot`, a field the harvester already carries and `ComputerContext` already
  reads. This is real, and it is the strongest thing here.
- **Folder names** — `Documents`, `Claude`, `Projects`, `speechify`. Real, but generic; `biasPhrases`
  would mostly re-offer words already in the dictionary's share of the budget.
- **File names — none.** Nothing in Terminal's AX tree contains one. A cwd is a directory, and the
  adapter's whole purpose is to hand the cleanup model a list of *files the user is looking at*
  (43 of them in Cursor, 133–142 ms, 2026-09-16). A Terminal row cannot deliver that, and
  pretending otherwise is the "a finished feature with no call site" failure in a new costume.

If Terminal *file* names are wanted, the cheapest honest source is not Terminal at all: the file
index this app already keeps. `indexed-folders.json` on this machine is
`{"paths": ["…/Desktop", "…/Documents", "…/Downloads"]}` — `~/Documents` contains the project, so
the names are already indexed, already consented, and already searchable, with no new permission
and no tree walk.

## 2.5 Verdict: recommend-DO the small part, recommend-DEFER the ambitious part

**Do: one `AXAppAdapter` row for Terminal that reads tab titles instead of walking a tree.** The
measured cost is 0.6–0.9 ms warm at key-down (against a 250 ms budget and a 60 ms ASR wait that
today returns nothing), it needs no grant the app does not already hold, and it fills
`projectRoot` — the field the agent's "Active project" reference already reads — with something
true. Roughly 20 lines: an adapter whose `interestingIdentifiers` is the tab group, no recursion,
one string split on the first ` — `. It is the cheapest positive result in this whole roadmap
section.

**Defer: "Terminal context" as a source of file names.** Not because it is expensive (it would be
cheap) but because the measurement says the value is not there. Across 226 dictations, **3 (1.3%)
mention a file name at all**, and none of them can be attributed to an app, so the honest expected
yield of a perfect Terminal file-name source is on the order of one dictation in a month. The
project-root row is the part worth having; the file-name ambition should not be written down as a
task, because nothing in Terminal's tree would ever satisfy it.

**Two follow-ups this spike found and did not do** (both one-liners, both evidence, neither a
product change today):

1. `DictationRun` has no target application, which is why "Terminal 19×" is not answerable from
   disk. Recording the bundle id at key-down (it is already resolved there for
   `OutputProfileStore.captureTarget()`) would make every future "which app are dictations going
   into" question a `jq` away instead of an archaeology project. **This is the highest-value
   finding in question 2** and it is one field.
2. `AGENTS.md` and `CorrectionLearner.swift:19-22` both say Terminal exposes no text elements to
   the accessibility tree. Today, on this Mac, `--selftest-axreadback` disagrees:

   ```
   Terminal   fields=1  value=1  range=1   READABLE — value and range
   ```
   while the other eight apps probed (ChatGPT, Claude, Cursor, Docker Desktop, Finder, Notes,
   Spotify, WhatsApp) all report `fields=0`. So the documented claim is right about Chromium and
   Electron and wrong about Terminal, and Finder — which the same paragraph names as the AppKit
   counter-example — also reports zero today. I have **not** edited either file (both are in
   someone else's working set); this is for the owner to decide, and it does not change anything
   above: Terminal's readable text is its scrollback, which §2.4 rules out for other reasons.

---

# What was not done, and what is still open

- **No product code was written.** No file under `Sources/` or `Package.swift` was touched, no
  dependency added, and no `dictation.names` / `runs.jsonl` field changed. The only writes were
  this report and the cache directory below.
- The harness, probes and fixtures live in
  `~/Library/Caches/NextNotesBuild/dictation-meetings/{fixtures,spike}/` and are **not** committed
  (raw outputs: `run1.txt`, `run2-norescue.txt`, `run3-perfixture-rescue-on.txt`,
  `axtitle-run1.txt`, `axprobe2-run.txt`, `axprobe3-run.txt`, `make-fixtures.sh`,
  `axtitle.swift`, `axprobe2.swift`, `axprobe3.swift`, `Package.swift`, `Sources/d16-spike/main.swift`).
- Still open, and not answerable by a spike: whether boosting behaves the same on the owner's
  actual voice (all fixtures here are `say` voices), what a 40-term vocabulary does to the
  false-positive rate, and whether `spotterRescueEnabled: false` costs recall on a
  brand-name-heavy vocabulary — upstream's own numbers (#702) say it does on *short* keywords, and
  this spike did not measure the long ones. If D-16a happens, the red-first test should be
  "ordinary prose is never replaced", not a hit-rate threshold.
- The Terminal row's `AXTitle` was measured against four `opencode` tabs. A plain `zsh` tab's title
  would be `… — zsh — 80×24` with the same leading cwd, since the cwd field is set by Terminal and
  the tail by the process — but that specific shape was **not** observed here, and the adapter
  should be written against "first field is the cwd" rather than against a regex that expects a
  known tail.

# Reproduce

```bash
# Question 1 — vocabulary boosting on the batch path
cd ~/Library/Caches/NextNotesBuild/dictation-meetings/spike
./make-fixtures.sh
F=~/Library/Caches/NextNotesBuild/dictation-meetings/fixtures
swift build --scratch-path .build
./.build/debug/d16-spike $F/f1.wav $F/f2.wav $F/f3.wav $F/f4.wav $F/f5.wav   # as shipped upstream → run1.txt
FLUID_SPOTTER_RESCUE=false ./.build/debug/d16-spike …    # rescue off           → run2-norescue.txt
D16_PER_FIXTURE=1 ./.build/debug/d16-spike …             # 2-term vocab         → run3-…txt

# Question 2 — Terminal
swiftc -O -o axtitle  axtitle.swift   && ./axtitle        # full bounded walk, roles, value
swiftc -O -o axprobe2 axprobe2.swift  && ./axprobe2       # tab titles + the axreadback read
swiftc -O -o axprobe3 axprobe3.swift  && ./axprobe3       # the recommended read, 5 timings
Scripts/run-selftest.sh --selftest-axreadback             # the authoritative Terminal row

# Demand, from the owner's own stores
python3 -c "import json;rows=[json.loads(l) for l in open('$HOME/Library/Application Support/Next Notes/runs.jsonl')];
print(len(rows), sum(1 for r in rows if r.get('corrections')))"
```

(The one line above is illustrative; §1.3 has the exact per-term command output.)
