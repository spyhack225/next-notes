# Doc freshness audit — 2026-10-04

Read-only checks on the owner's Mac (M3, 16 GB; `df` showed 3.3 GiB free during the audit).
No build, install, self-test, app launch, sign-in or store write. Counts only; no names,
subjects, transcripts or addresses were copied. Line numbers are after the edits.

Unreadable here: the user TCC.db (`unable to open database file`), so no grant (Calendar,
Screen Recording, Accessibility, Audio Capture) was read directly.

## Changed

| Claim (old) | File:line | Check performed | Result | Change |
|---|---|---|---|---|
| System-audio tap never held its grant; no meeting has an "Others" track | AGENTS.md:2744; README.md:1475, 1597 | `Meetings/*/transcript.json` segment `source` counts; `speakers.json` presence; `usage.jsonl` `meeting.diarize` rows | 8 of 10 meetings have `system`-track segments (09-10 → 10-01); 3 have `speakers.json`; diarize rows 09-29, 10-01, 10-02. AGENTS.md's own LaunchServices note records non-zero RMS | Rewritten: tap has delivered audio; grant still unreadable/not re-verified for current signature |
| Meeting notes fall back to Apple's model while Gemma is absent / "not re-verified" | AGENTS.md:2752; README.md:1494, 1057 | `usage.jsonl` `meeting.notes.single` provider/model; `defaults read` `modelRoles.meetingNotes`, `modelLibrary.activeAgentModelID`; `ModelRoleStore.displayName/builtInProvider` | 3 notes passes: llama Qwen3-4B-Instruct-2507 (09-29), MiniCPM5-2B (10-01, 10-02). Role `builtin` runs the runtime's active file (MiniCPM5-2B) | Rewritten in both files; README notes table gains a sentence that the built-in row runs the active file |
| "writes notes with a local Gemma 4 E4B (or Apple FM)" | AGENTS.md:169 | same as above | Notes ran on Qwen3-4B / MiniCPM5-2B; OpenRouter also selectable | Reworded |
| Local agent turns on MiniCPM unmeasured; nothing local depends on it | AGENTS.md:1229 | `Tests/Reports/toolloop-live/` reports; `usage.jsonl` | Quick 2/10 and 3/10 (09-30), full 17/30 (09-29); `agent.worker` and notes rows on MiniCPM5-2B | Rewritten with numbers and paths |
| Google Calendar never had an account connected | AGENTS.md:2767; README.md:1499, 1597 | `security find-generic-password -s ai.pivotstudio.nextnotes.google` (attributes only); `defaults read` key names; meeting.json `providerID` | Keychain item created 2026-09-10; client id/secret and 1 selected calendar stored; 2 meetings with `providerID: google` (09-29, 10-01) | Rewritten: connected |
| EventKit reports `.notDetermined` | AGENTS.md:2767; README.md:1499; POSITIONING 04-PERSONA-JOBS.md:176 | TCC.db read (blocked); meeting `providerID` | Not checkable; no meeting has `eventKit` provider | Marked "not re-verified 2026-10-04" |
| No Workspace write proposal ever approved | AGENTS.md:2776; README.md:1506; POSITIONING 00-README.md:206 | `action-receipts.json` toolID/status/events; `gws auth status` (fields only) | One `append_doc` 2026-09-20: judged→approved→fired→failed, no result. No completed write. gws: refresh token, 21 scopes, `token_valid: true` | Rewritten: "never completed" |
| Portrait/assembler: local model not installed; graph has two meetings | AGENTS.md:2720 | `portrait-insights.json` keys; `knowledge.sqlite` read-only counts; `Assembled/` folder; Models folder | Real Portrait pass 2026-10-01 → 0 drafts, 0 saved; graph 59 nodes / 78 edges / 8 meetings; no `Assembled/`; four local LLMs installed | Rewritten |
| Nobody has seen the redesigned UI | AGENTS.md:2801 | `usage.jsonl` owner rows; README's own 2026-09-29 live-screenshot note | Owner uses the app daily; no agent-side visual check found | Narrowed to "no agent has verified" |
| No credential storage or network path for a Claude provider | AGENTS.md:2693; README.md:1447 | grep `anthropic` in `Sources/`; `OpenRouterLLMProvider.swift` | No Anthropic provider; OpenRouter has Keychain key + network path; Claude Code via ACP | Reworded to "no direct Anthropic provider" |
| D-13/D-14 gates: `not enough data` for both | AGENTS.md:1686; DICTATION-MEETINGS-RATES-AND-GATES/STATUS.md gates table | `gates-latest.txt`, `gates-history.jsonl` | Every successful run 10-01T02:54Z → 10-05T00:21Z: D-13 not enough data (31/100 holds), D-14 won't do (evidence); 30 earlier `GATES_RUN_FAILED` | AGENTS.md rewritten; gates-read row added. F-03 left `todo` (decision not recorded) |
| F-04 waits for ≥ 7 days and ≥ 30 holds | DICTATION STATUS.md F-04 row | `usage.jsonl` `dictation.hold` count/dates | 31 holds, 09-27 → 10-02 | Precondition note added; state unchanged |
| iMessage command channel not built; pairing/sending/approval "none are written" | README.md:81, 1426, 1512 | `Sources/NextNotes/IMessage/` dirs + `git log`; iMessage STATUS rows; `action-receipts.json` | Pairing, Classify, Sending, Approval, Attachments committed (e.g. `38bfccb`, `8888474`); IM-07…IM-15 done; one `imessage.send` fired 2026-09-30; IM-16 blocked | Rewritten |
| "IM-04 → IM-10 implementation: not started — queued" | NextNotes-iMessage/STATUS.md:192 | same | Superseded by the task table | Annotated as superseded (dated 09-25 row kept) |
| Durable jobs: journal and heartbeats designed, not built | README.md:1438 | AGENTS.md P6 evidence; `agent-tasks.sqlite` exists | SQLite ledger, journal and heartbeat fields exist; retry/recovery not | Reworded |
| No routines exist | README.md:1442 | `Sources/NextNotes/Agent/Schedules/`; `agent-schedules.json` | Routines built; none scheduled on this Mac | Reworded |
| Meeting panel "never seen by an eye" | README.md:144 | README's own 2026-09-29 screenshot note | First layout was seen; revised one not | Reworded |
| ACP CLIs must be installed by the user | README.md:1528 | `which claude codex qwen opencode`; `action-receipts.json` | claude, codex, opencode installed; one real ACP receipt 09-14 `couldNotVerify` | Added owner-Mac facts |
| `make acceptance TIER=core`: 15/16 | README.md:1590 | `~/Library/Caches/NextNotesBuild/acceptance/20261002-215127-44216/*.log` final markers | 21 OK, 1 `WAKE_LIVE_FAILED` (17/24, 3/32) | Updated to 21/22 |
| "Two claims this file … no longer can" (Gemma never downloaded, Google never connected, tap never held grant) | README.md:1597 | all of the above | All three withdrawals now stale | Paragraph rewritten |
| Bundle 52 MB; first-use models 484 MB + 2.7 GB Qwen3.5-4B | roadmap/todo/PAID-RELEASE.md:217, 508 | `du -sh /Applications/Next Notes.app`; `OnboardingBrainStep` → `NotesModels.spec` | Installed build 167 MB; onboarding fetches Gemma 4 E4B 4,977,171,584 B | Updated (release DMG size not re-measured) |
| "existing nine tabs" | PAID-RELEASE.md:304 | `ls UI/Settings/*SettingsTab.swift` | 10 | Updated |

## Checked and still true (no change)

- `WAKE_MIC` has no captures: no `WakeWord/LiveFixtures/` directory. Wake 17/24 @ 3/32 in the 10-02 CORE run.
- Podcast/Library audio: no `agent-schedules.json`, so no scheduled run. Voices on disk (already fixed today).
- Gemma 4 E4B on disk, 4,977,171,584 B, SHA pinned in `NotesModels.swift` (already fixed today).
- Model sizes in README: MiniCPM 1.56 GB, S1-mini 462 MiB (484,219,808 B), Parakeet v3 ~461 MB on disk, POSITIONING candidate byte counts — all match.
- Composio: no Keychain item for `ai.pivotstudio.nextnotes.composio`.
- Windows: `windows/src` last changed 2026-09-09, no uncommitted edits; 63 tests (24 + 26 + 13) match the test sources; no installer, model download is manual.
- Notarization not attempted (`release.yml`); `macos.yml` still on `macos-15` running only the dictionary/spoken-form suites.
- `agentNativeToolCalling` defaults off; llama.cpp pinned b10621; no floor report under `Tests/Reports/floor/`.
- MODULES-ACTIVATION MOD-03…10 `todo`: no Modules settings tab, `ModulePolicy` used only by Sidebar/NavigationState/Settings.
- AGENT-OVERHAUL `todo` rows: no commits name them (P0-10 is `blocked` with its commit, as recorded). A `FrontendResponder` type exists in an uncommitted file, but P5-01's settings/consent/key store are not present, so P5-01 stays `todo`.

## Still needs a run or a grant

- EventKit authorization state (TCC; or a run of `--selftest-calendar` / the Permissions pane).
- Whether the Audio Capture grant holds for the current build signature (`Scripts/run-selftest.sh --via-open --selftest-systemaudio`).
- Screen Recording: avatar on the notch, island expansion, vision path with real pixels, revised meeting console and redesigned UI by eye.
- The first-ingestion consent gate against the connected account.
- Why the one approved `append_doc` failed (no saved result), and a first completed Workspace write.
- A completed real ACP hand-off; a full phone → remote-approval iMessage round trip.
- `--selftest-computer-actions` on an unlocked screen; Windsurf / VS Code harvest walks.
- Release DMG size.
