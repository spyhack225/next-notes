# P4-04a: event-ready brief sized for its actual reader

Date: 2026-10-01. Status: **bounded P4-04a complete under the owner's independent-task
rule**. Copied actual producer original/current and installed functionality pass;
the required fixed quick verdict is recorded as FAILED 3/10 below the unchanged 9/10
bar. Source remains frozen. This closes only P4-04 steps 1/1b, not the full
proactive feature, aggregate quality gate, model promotion or phase exit.

## Producer contract and change

The existing `MeetingNotesContextAssembler.brief(for:reader:)` fixed every section
and retrieval count to an 8192-style brief. The two actual consumers,
`NotesService.notesBrief` and `AgentService.knownContext`, passed only a provider
id and could not supply the real reader window. A 32768 reader therefore lost
otherwise eligible context before its existing final prompt budget was applied.
The copied actual original/current driver confirms this producer failure: the
same dense reader input loses all five sections' additional context on the
original, which also retains the old retrieval counts and passage text limit.

The complete assembler now factors its existing data flow through a title,
attendees, file query and optional exclusion identity. `brief(forEvent:...)` can
assemble a real upcoming event without inventing a recorded Meeting/UUID. The
recorded-meeting API delegates with its own id, preserving self-exclusion.
Default `contextTokens:8192` and scale `max(1,contextTokens/8192)` preserve existing
notes behavior; no cloud/local brief is reused across different readers.

The scale multiplies the five existing character caps, passage text/count/fetch
limits and file count. The internal query passes through the actual existing
`KnowledgeToolExecutor.searchQuery` validation before its trusted request limit
is sized to this bounded reader context. The public tool's 20-hit limit is
unchanged. Both actual service consumers pass the real resolved reader's window
through `AgentAnswerBudget.readerContextTokens(for:)`, using an instance-local
injected `MeetingNotesContextAssembler` with default `.live` for fixture isolation.

At 32768 this means 40 candidate passages, at most 12 kept, 1200 characters of text
per passage and 3600 section characters; files request at most 20 and retain 1200
rendered characters. The preexisting file label remains outside the rendered
file character cap. Requests honor those counts in the fixtures. Graph/file
consent, per-source switches, query matching, ordering and whole-entry rendering
remain in their original owners. No tool permission or source persistence changes.

Each actual context consumer gains one required metadata await through the
existing budget helper. For appLLM it checks the loaded runtime and reads its
actual window from the existing actor; another provider uses its declared
snapshot. This does not resolve/load weights or perform a model pass. It is still
an added await, and no full user-path latency result is claimed. There is no new
model pass, timer, cache, ledger, fixed wait or delivery queue.

## Prepared verification and exact limits

`run-reader-driver.py` copies the complete actual assembler. The original is
read from commit `ae454a4` and invokes only its existing `brief(for:reader:)` API.
The same frozen dense 32768 fixture/expectations drives current with its actual
new window argument. No missing event API is called on the original, and no
compile error can be reported as an original product failure. A compile error
prints `BRIEF_READER_DRIVER_HARNESS_ERROR` and exits 2. Compiled failed assertions
exit 1; a compiled passing fixture exits 0. Parent executed both modes below.

The corpus contains 8 memory facts, 20 decisions, 30 nodes, 50 passage candidates
with 3 self-hits first, 25 file hits and one long passage. Search/file fixtures
return only the requested prefix and record actual requests. The copied actual
validation, search, render, token, citation, graph/file consent and value-type
methods are hashed in each generated input manifest. Memory/Meeting fixture
values, no-op embedding preparation and injected corpus lookup are explicitly
isolated collaborators. Owner memory/index/graph/folder accessors trap. No model,
provider, grant, network, owner history or full app consumer is proven by this
standalone driver. Parent performed the serial compilation and execution;
this worker retained its evidence without another compiler or test run.

### Executed copied-source before/after

| Actual assembler | Compile/run exit | Default 8192 brief | Requested 32768 brief | Passage fetch/file request | Verdict |
| --- | --- | --- | --- | --- | --- |
| Original `ae454a4` | 0/1 | 2491 characters | 2491 characters | 10/5 | `BRIEF_READER_DRIVER_FAILED: 9 assertion(s)` |
| Current frozen source | 0/0 | 2491 characters | 7894 characters | 40/20 | `BRIEF_READER_DRIVER_OK` |

The nine original assertion failures are larger-window retention for memory,
decisions, connections, passages and files; scaled candidate fetch and file
requests; twelve retained passages; and passage text scaling. Current passes
those identical assertions plus the unchanged public 20 tool clamp, section
bounds, self-exclusion and default request checks. The default brief's measured
length remains 2491 in both modes; this measurement alone is not byte-for-byte
default equivalence. The stricter current event/default 8192 equivalence
assertions in the installed existing flag now pass; no standalone old/current
byte-for-byte golden claim is inferred from the character counts.

[original-red.log](original-red.log) and [current-green.log](current-green.log)
are exact raw parent logs. [copied-driver-evidence-manifest.json](copied-driver-evidence-manifest.json)
pins both hashes, the identical frozen fixture hash, executed script, compiled
binary hashes and compile/run exits reported by parent. Each copied-driver
directory retains the generated complete assembler, actual extracted
collaborators, driver and input manifest. The executed `/tmp` script snapshot
is retained as `executed-driver.py.txt`; the tracked rerun script differs only
in removing the now-unused unapplied-candidate selector. No compile failure or
missing original API was counted as a product-red case.

```sh
python3 Tests/Reports/agent-overhaul-closure/meeting-brief/run-reader-driver.py --original
python3 Tests/Reports/agent-overhaul-closure/meeting-brief/run-reader-driver.py
```

These commands compile; parent holds the serial compiler slot. `--prepare-only`
writes generated sources/manifests without compiling and supplies no verdict.

The existing `--selftest-notes-context` retains its old cases and adds event vs
recorded meeting equivalence, explicit 8192 and zero-window equivalence, empty
sources, dense 32768 section growth, actual 40/20 requests, 12 kept passages, the
public 20 tool clamp, long-passage text scaling, cloud consent and feature-off
checks. Both actual context methods are called with the same injected assembler
and a recording provider's 32768 window. `NotesService.generate` additionally runs
through its real existing generator and temp-store save; the fixture asserts the
provider receives the full assembled block and a fresh reader sees the saved
notes/capture metadata. That provider is scripted: no physical Apple/local model
inference is claimed. Full Agent review/model resolution orchestration is outside
that direct context-method proof. These installed functional assertions now pass.

### Installed app12 functional evidence

Parent built, installed and ran the focused flags against binary SHA-256
`a35a883bee7666030975ee28960ca62cf958c9a158be71978b8254f2490b488c`.
This worker verified the actual installed binary hash and matched all four
frozen source hashes to `build12-source-inputs.json`; no flags were rerun.

| Installed flag | Exit | Harness duration | Final marker |
| --- | --- | --- | --- |
| `--selftest-notes-context` | 0 | 2.762s | `NOTES_CONTEXT_OK: assembly, consent gates, window accounting, map purity and index safety hold` |
| `--selftest-meeting-context` | 0 | 0.641s | `MEETING_CONTEXT_OK: extraction and the authority split hold` |
| `--selftest-meeting-resume` | 0 | 14.394s | `MEETING_RESUME_OK: 4/4 resumable meetings reached .done with notes; no temp audio released early; 4 write(s) for 100 segments, flushed to 100; a trailing write inside the interval, cancelled by the exit` |
| `--selftest-store-isolation` | 0 | 40.122s | `STORE_ISOLATION_OK: 21 files and 31 defaults unchanged` |

`NOTES_CONTEXT_OK` includes the exact added actual NotesService context method,
`generate`/recording-provider prompt/fresh-reader save and capture-metadata
assertions, plus the actual Agent context method. It does not prove full Agent
review orchestration, physical model inference, a hosted proactive card or user
latency. The durations above are test harness runtimes, not meeting/Agent latency
measurements. The unrelated onboarding and layout cases also pass in the retained
six-case summary; neither is claimed as P4 feature proof and their raw logs are
not copied here. The existing NSTableView reentrancy warning is retained in the
focused logs; a functional marker is not a claim that all UI warnings are absent.

[installed-app12/evidence-manifest.json](installed-app12/evidence-manifest.json)
hashes the exact four raw `.log`/`.out` pairs, six-case parent summary, full frozen
source-input manifest and installed binary. Bounded installed functionality is
green; the required fixed quick verdict is recorded below. No privacy, permission,
eval threshold or selection changed.

### Required fixed quick verdict and retained incomplete launch

The completed app12 quick run returns `TOOLLOOP_LIVE_SCORE 3/10 (quick)` and
`TOOLLOOP_LIVE_FAILED: 3/10 (quick) on Gemma 4 E4B — below the pass bar 9`, in 129.9s.
It ran the unchanged fixed ten cases using appLLM's local Gemma 4 E4B fallback for
the saved cloud role. No role/default, model file, case selection or threshold was
changed. Its `.md.jsonl` sidecar has all 10 case rows. Case verdicts exactly match
the earlier complete app5 run: C01/C04/N04 PASS; M03/K01 REFUSAL; M04/R02/F03
MISSED_TOOL; M05/A02 UNGROUNDED. This is not a quality improvement or a passing
aggregate gate, and timing differences are not attributed to this context change.

An earlier direct launch produced only C01, C04, M03 and M04. It has no final
marker, score, elapsed line, report or sidecar. Its exact log/output remain in
`quick-app12/incomplete-direct/`; it is explicitly INCOMPLETE, never a pass or
complete score. The interruption's cause is unknown and is not claimed fixed
by switching the launch path or by the later completed run. Parent completed the
same required ten-case contract through the app launch route and retained both.

[quick-app12/evidence-manifest.json](quick-app12/evidence-manifest.json) pins the
exact completed raw log/output/report/ten-row sidecar, the two incomplete direct
artifacts and the complete app5 comparison hash/case verdicts. Aggregate quality
remains open. Owner §4.1 permits this independently proven bounded task to complete
while inherited aggregate quality remains below 9/10; no model/default or phase
promotion follows.

### Bounded steps 1/1b contract ledger

| Required bounded behavior | Actual evidence | Limit |
| --- | --- | --- |
| Event title/attendees API without fabricated recorded identity | Installed notes-context compares event/meeting assembly with known exclusion and pins nil exclusion | Full hosted event subscription is parent P4-04 |
| Default 8192, zero window and empty-source behavior retained | Installed existing full flag retains old cases and compares current default/explicit 8192/zero/event/empty results | Old/current standalone character equality alone is not byte equivalence |
| All five section caps and passage/file counts scale with reader | Compiled original red9/current green on identical dense 32768 corpus; installed cap/request/text/count assertions pass | Metadata awaits add no model pass; full user latency unmeasured |
| Public tool 20 limit and consent remain in original owners | Actual validation and consent methods in driver; installed public clamp, cloud refusal and off-switch assertions pass | No new source-read/write permissions |
| Both actual consumers propagate resolved provider window | Installed actual NotesService.notesBrief and AgentService.knownContext equal scaled assembly | Agent proof is context method, not full review orchestration |
| Real notes consumer receives/uses the brief and persists result | Installed actual NotesService.generate -> recording provider prompt -> real isolated save -> fresh reader, capture metadata unchanged; meeting-resume green | Scripted provider, no physical inference or owner-store migration |
| Original failure verified and required acceptance verdict recorded | Original actual compiled/run exits 0/1 red9; current 0/0 green; installed4 flags pass; fixed quick complete 3/10 FAILED retained | Parent P4-04 and all broader quality/phase gates stay open |

Every requirement of this explicitly bounded steps 1/1b child is covered. The full
parent P4-04 recipe, including steps 1c and hosted cards/policy, is not complete.

All existing NotesService generation, save, scratchpad merge, capture-integrity
handling and meeting pressure admission bodies remain intact. The meeting owner
explicitly handed off these context files; unrelated meeting sources stay frozen
under that owner. No new flag or app registry change was added by this worker.

## Frozen handoff and remaining scope

`source-manifest.json` binds before/after hashes for the four owned source files
and retained artifacts. Each `*.original.txt` is the actual working-file snapshot
before this patch, including the meeting owner's existing changes. The complete
original assembler also matches `ae454a4`; the standalone driver uses that commit
for reproducibility. Before snapshots are evidence, not files to restore wholesale.

Root has run the standalone original/current driver, shared installed focused
checks and the required complete fixed quick evaluation. The quick 9/10 and CORE bars stay unchanged;
the retained Gemma quick 3/10 and CORE 21/22 wake defect remain open. No model/default
promotion or phase closure follows from this source handoff.

P4-04's hosted subscriber, conferenceURL producer propagation, once-per-key/caps,
deterministic card/notification delivery, settings/consent, quiet/dictation handling
and fake-calendar full chain remain open. No pre-meeting notification/card will
be claimed until that real hosted flow is implemented and verified. P3-04's
spoken path remains a separate dependency.
