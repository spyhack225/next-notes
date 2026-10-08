# Catchup-audio result

Completed the assigned backend brief in this worktree on `claude2/catchup-audio`, based on `e18b09a9acc215fd8b18f187a7296ea81d7605a2`. No install, push, merge, GUI, canonical edit or owner-store seeding. Native work used `RELAY_ID=claude2-catchup-audio ../heavy.sh` and the normal FIFO/resource gates, with two serial original/fixed batches and `swift build -j 2`.

Commits:

- `9f1261ff` — producer repairs, new native regression, registration and DESIGN.md.
- `20e66ae2` — exact original/fixed evidence, retained failed first fixture, cleanup evidence and PERFORMANCE-STANDARDS.md link.
- This report is a separate report-only commit.

## Confirmed causes and repairs

The scheduled delivery did not record the catch-up in the conversation; `acceptOffer` passed only the generic yes words. The actual Library/Live producer now receives the entry, records its text with `backgroundTaskContextKind`, then submits the ordinary turn. Optional identity on the existing AgentSession row deduplicates each entry in the retained current session, including after a fresh JSON reader. Identical text from a different entry is retained. An idle/new session gets its own antecedent before the user row. No second context store, prompt change or action authority was added. Existing bounded storage, prompt clipping and compaction remain.

The existing private file player started unconditionally and checked only activation on the later tick. **Conservative option chosen:** one synchronous activity predicate before Play/Resume and on the existing 250 ms tick refuses/pauses for dictation, meeting recording, output speech, calls and non-idle activation. It keeps paused position/identity and requires a new tap; it never auto-plays or auto-resumes. The production text audio owner has no small saved-file API: safe file streaming/seek/completion ownership and PCM echo reference require broader work. [DESIGN.md](DESIGN.md) records the inspected owners and decision.

Diff size from the base: production files +121/-21; tests +234/-0. Saved-audio region alone +72/-16, including the injected transport/activity test seams (line comparison scope/method in `diff-size.json`). The code commit including DESIGN.md is six files, +364/-21. No new await, timer, queue, store, model pass or microphone gate was added to the product path.

## Exact native verdicts

The corrected fixture SHA-256 is `f919a8858de89bccd24e63d1c2dbb6954506e1a71fe7cfa6679ea3acd03d3a9a`, unchanged between original and fixed builds.

| Check | Original final marker / observation | Fixed final marker | Exit |
| --- | --- | --- | --- |
| Handoff, 12 assertions | `CATCH_UP_HANDOFF_FAILED`, 8 failures; `roles=user background_rows=0 turns=1` | `CATCH_UP_HANDOFF_OK`; `roles=assistant,user background_rows=1 turns=1` | Original aggregate 1; fixed 0 |
| Normal send approval | `CATCH_UP_APPROVAL_OK`, denied 0 / approved 1 effects | `CATCH_UP_APPROVAL_OK`, same counts | Included in Catch-up |
| Playback, 45 assertions | `CATCH_UP_PLAYBACK_FAILED`, 17 failures | `CATCH_UP_PLAYBACK_OK`, 0 failures; zero file opens/starts in all five busy states | Included in Catch-up |
| `--selftest-catch-up` | `CATCH_UP_FAILED` | `CATCH_UP_OK` | 0 |
| `--selftest-agent-panes` | — | `AGENT_PANES_OK: 3 panes, unique titles, Reminders and Goals say what they are, layout on the shared scaffold` | 0 |
| `--selftest-ui-strings` | — | `UI_STRINGS_OK` | 0 |
| `--selftest-voice-conversation` | — | `VOICE_CONVERSATION_OK` | 0 |
| `--selftest-duplex` | — | `DUPLEX_OK` | 0 |
| `--selftest-store-isolation` | — | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` | 0 |

Handoff proof uses the actual completed scheduled Library entry, Live producer, isolated AgentSession, both native prompt consumers with history scrubbing, JSON save/fresh reader and idle-session boundary. The ordinary model turn is scripted. Approval uses the actual executor/orchestrator/broker/card; an unconfirmed recipient cannot be approved, row confirmation sends nothing, denial sends nothing, and only normal approval reaches one scripted final effect. No email is sent. Playback uses the actual player methods with a substituted transport/activity snapshot; no physical device starts.

Store isolation retains the brief's known inherited nested browser test-wiring defect: `TOOLLOOP_PRODUCTION_FAILED`, 18 `TOOLLOOP_PRODUCTION_WRONG` lines. This is not a production-tool-loop pass. The root isolation marker is retained in stdout and the final `--selftest-out` mirror. Zero defaults is the actual reported count, not broader preference coverage. Duplex retains two `VOICE_SESSION_DIVERGENCE` diagnostics for `turnPending` (timer/inputWithdrawn), also present in the first batch.

The first fixture is retained in `initial-fixture/`, with exact earlier source/hash/logs. It omitted the required schedule ID, so the Library never admitted its entry; its approved send also correctly stayed blocked at the unconfirmed recipient. Original and fixed `CATCH_UP_FAILED` outcomes are preserved and are not used as full handoff proof. Its playback alone failed 17/45 then passed 45/45. The corrected fixture adds real schedule identity, asserts admission and uses the normal recipient row confirmation; both original and fixed were rebuilt and rerun. No gate or expected result was weakened.

[Evidence and reproduction scope](Tests/Reports/catchup-audio/README.md) include exact source/binary hashes, environments, build logs, raw flag/mirror logs and the one-time RED-to-fixed script. Original/fixed final builds completed in 363.94 s / 109.13 s on macOS 27.2 arm64 Mac15,12 with 16 GiB. These are build durations, not product performance claims.

## Files, integration and open contracts

Source: `Agent/RealtimeAgent.swift`, `Agent/Schedules/CatchUpSelfTest.swift`, `UI/CatchUp/CatchUpLibrary.swift`, new `CatchUpConversationContext.swift` and new `CatchUpHandoffSelfTest.swift`. Documents: DESIGN.md, PERFORMANCE-STANDARDS.md, this RESULT.md and `Tests/Reports/catchup-audio/`. CatchUpModel.swift, views, settings, existing presentation self-test, island and reminders hooks are untouched.

**RealtimeAgent.swift will conflict with uncommitted work** in the canonical checkout. Integrate its optional row field, recordAssistant parameter and Message initializer by hand after that work is committed; preserve the other agents' changes. The UI peer's `4cc30010` commit was inspected read-only: its island/pane Pause/Resume/problem consumers use the unchanged player interface and own five UI files. No combined integration or native UI interaction was run, because this brief forbids merging and GUI access. The integrator must combine and verify those controls.

Idle wake-listening PCM echo reference, physical overlap/interruption timing, real model action selection, long-body context completeness, notification/voice rendering and combined UI interaction remain unverified. The conservative fallback does not close the one-audio-owner architecture contract; a future saved-file owner entry needs those explicit acceptance cases. No aggregate quality gate, model/default, phase or broader Agent readiness is promoted.

Own scratch was removed only after no owned compiler/selftest used it: 2,149,044,224 allocated file bytes retired, immediate available-space gain 1,540,345,856 bytes. Exact temporary output files were removed after retaining their logs; fixtures defer their own temporary-directory cleanup. No foreign process, cache or store was removed. Shared scope, actual RED/GREEN outcomes, remaining contracts and cleanup were broadcast through agent-relay; sending does not prove receipt.
