# Computer use and browser use — plan and build order, 22 September 2026

> **Historical model assumptions — revised 2026-09-30:** this completed plan/audit
> preserves its dated measurements and implementation history. For new work, follow
> the [independent-role/shared-file contract](../in-progress/SHARED-BRAIN/00-README.md): Meetings, Agent and cleanup
> may use different appropriate models; exact verified artifacts are reused, with
> workload-specific consent and request ownership. Agent-only file selection,
> universal model defaults and deletion based only on the Agent are superseded.
> MiniCPM cleanup + Apple guard/fallback is concurrent work, not evidence that this
> historical build used it. Re-measure quality/latency on the actual current engine.

**Status, same day.** P0, P1.1–P1.4, P2-A and P3 are implemented and verified to the extent
this machine allowed. P2-B remains a spike (§ below). Verification on 2026-09-22: `make
build`, `make test`, and `--selftest-cdp` / `--selftest-browser` /
`--selftest-seat-grid` / `--selftest-click-coordinate` / `--selftest-settings` /
`--selftest-ui-strings` all OK through `Scripts/run-selftest.sh`. Two honest reds:
`--selftest-computer-actions` and the live coordinate-click landing are **red on a locked
screen** (measured: frontmost = `loginwindow`, activation refused even through
`--via-open`), which is the environment answer, not a green lie — both name it and will
pass the first time a person runs them on an unlocked session. The `--selftest-cdp` first
live run also caught a real pre-existing bug: CDP commands left as binary websocket frames,
which real Chrome tears down without a CLOSE — `command()` now sends text frames, and
`--selftest-browser`'s Python fixture had tolerated binary frames, which is why that
failure was never seen before.

**Amendment, audit 2026-09-22 evening.** The two code audits run during the roadmap
sorting found P0.1's final wire missing from the tree — `VisionHandoff.describe` had no
production caller and `RealtimeToolSelection.screenshotToolIDs` was never read, exactly the
"finished feature with no call site" AGENTS.md warns about. Re-wired the same day at the
tool loop's result seam (`RealtimeAgent+ToolLoop.swift`, the `execute` closure: a
screenshot step's park summary becomes the run model's consented description), with
`--selftest-computer-vision` green afterwards. Recorded here so the done status is true
rather than merely asserted.

Proposed after reading the three reference repositories named in the request
(`e2b-dev/open-computer-use`, `iFurySt/open-codex-computer-use`, `iFurySt/open-browser-use`)
and a fresh map of what this codebase already contains. This file is the build order; the
orchestration notes at the end say which agent owns which file so waves can run in parallel
without colliding.

---

## 0. Correcting the premise first

"We don't have built-in support" is not true. The map, read from the code:

| Piece | Where | State |
|---|---|---|
| 14 native computer tools (`active_app`, `windows`, `inspect_ui`, `screenshot`, `get_selection`, `clipboard`, `open_app`, `open_url`, `focus`, `click`, `press_key`, `set_text`, `type`) | `Agent/Tools/ComputerTools.swift` + `Computer/ComputerToolExecutor.swift` + `Computer/AccessibilitySnapshot.swift` | Registered in `AgentToolRegistry`, risk-graded, approval-gated, reachable on live turns through the generic `.toolLoop` path |
| 8 browser tools (`navigate`, `snapshot`, `screenshot`, `click`, `fill`, `select`, `download`, `purchase`) | `Agent/Tools/ShellTools.swift` (`BrowserToolCatalogue`) + `Computer/BrowserToolExecutor.swift` | Same; `refLoop` verifies every click against a frozen snapshot; `purchase` carries a `.purchase` risk class, budget cap and receipt |
| CDP client | `Computer/BrowserCDPClient.swift` (702 lines) | Real: `/json/list`, page snapshot expression, `Page.captureScreenshot`. Works **only** for a browser launched with `--remote-debugging-port` |
| Codex hand-off | `Agent/Backend/CodexComputerUse.swift` | Probe → approve → `codex exec --sandbox read-only`. OpenAI's helper app is signature-gated, so the CLI front door is the honest route |
| Screenshot → vision | `Computer/ScreenCapture.swift`, `VisionScope`, `completeWithImages` on two providers | **Broken seam.** See gap 1 |
| Self-tests | `NextNotesApp.runRequestedSelfTest` | `--selftest-computer` (own harness window), `--selftest-computer-vision`, `--selftest-seat-grid`, `--selftest-browser` |

## 1. The gaps, stated plainly

1. **`completeWithImages` has no production call site.** The tool loop takes a screenshot,
   asks `VisionScope` for consent — and then has nothing to send the pixels to. AGENTS.md
   names this. Since Chromium's accessibility tree is stub-prone (measured; see AGENTS.md),
   pixels are the designed fallback, and the fallback stops mid-way.
2. **No coordinate interaction.** `click` accepts an AX element id only. When AX yields
   nothing — canvas, Electron webviews, the seat-picker — there is no "click at (x, y)"
   resolved by a vision model. This is the e2b repo's grounding-model slot, unfilled.
3. **The action surface is thinner than Codex CUA's.** open-codex-computer-use offers
   `scroll`, `drag`, `set_value`, `select_text`, `perform_secondary_action`, element-index
   state reuse and multi-call sequences. We have none of `scroll`, `drag`, `hover`,
   right/double-click, or a `wait_for` poll — and real UIs need scroll and wait more than
   they need anything else.
4. **CDP needs a special browser launch.** Nobody runs Chrome with `--remote-debugging-port`
   by accident. There is no extension/native-messaging path, which is exactly the problem
   open-browser-use solves, and no guided relaunch either.
5. **`AgentTurnIntent.computer` has no producer** and `ComputerLoopPlanner` is dead code
   (AGENTS.md, measured). Live turns work; the planner is an unwired seam that reads like
   the live path.
6. **No readiness surface.** Codex's repo greys nothing without a sentence (`ocu doctor`).
   Our readiness probe exists for Codex only; Accessibility, Screen Recording, browser
   detection and CDP reachability have no one place that answers all four.

## 2. What each reference repo contributes

- **e2b-dev/open-computer-use** — the *shape*: see → ground → act, with a dedicated
  grounding model for pixel-to-coordinate and a pause-and-prompt loop. Its cloud Linux
  sandbox is **not** adopted: this app is local-first and AGPL, and a screenshot leaving the
  machine is already gated behind per-run consent. What transfers is the three-stage split
  and the grounding slot, filled locally by the existing vision provider.
- **iFurySt/open-codex-computer-use** — same philosophy as this app (Accessibility-first,
  non-intrusive, macOS). Contributes the richer action surface, element-index compact state,
  sequence execution, `doctor`, and the readiness-with-a-sentence pattern. MIT; ideas only,
  no code vendored.
- **iFurySt/open-browser-use** — extension + native messaging + CDP for real DOM access
  without a debug port; tab claiming, action plans, wait-for-navigation, cleanup. This is
  the model for phase 3's browser work.

## 3. Phases

### P0 — make the existing path actually run

1. Wire `completeWithImages` into the realtime tool loop: after `VisionScope` consent, the
   screenshot reaches the vision-capable model, and the answer is returned to the loop as a
   tool result. Model choice goes through `AgentModelRouting` like every other role.
2. Resolve the dead seam: `ComputerLoopPlanner` is deleted (grep proves no producer for
   `AgentTurnIntent.computer`; the `.computer` case survives as pattern + progress title,
   served by the `.toolLoop` path, exactly as AGENTS.md documents). Removing dead code that
   reads like the live path beats wiring a path nothing takes.
3. Verification: `make build`, `make test`, then
   `Scripts/run-selftest.sh --via-open --selftest-computer-vision` (Screen Recording is a
   TCC grant; a shell-launched probe cannot hold it).

### P1 — complete the accessibility action surface (open-codex-computer-use parity)

1. New tools on `ComputerToolExecutor`, reusing the refLoop verify pattern:
   - `scroll` — direction/amount on the focused window or an element id.
   - `drag` — from element id (or coordinate later, after P3) to element id.
   - `double_click`, `right_click` — the secondary-action slot.
   - `wait_for` — poll expectedText/expectedURL/element presence with a timeout; the model
     otherwise retries blindly against a UI that has not caught up.
2. `--selftest-computer-actions`: drive the harness window (scroll a field, drag, verify a
   wait_for timeout fires) and fail on anything it cannot actually observe.
3. Compact `inspect_ui`: element ids + short labels only, with a `verbose` flag for the full
   tree. The full-tree string is what makes computer turns expensive per token.
4. A readiness row in Settings ("Computer & browser"): Accessibility, Screen Recording,
   frontmost browser detected, CDP reachable — each grey with a sentence naming what to do,
   following the Codex probe pattern already in `CodexComputerUse.probe()`.

### P2 — browser: real DOM access (open-browser-use lesson)

**Decision, later the same day.** The debug-port row was unusable for a non-technical
person — it asked them to launch Chrome with a flag and check a port. Two changes close
that gap, in ease order:

1. **The AX path is now the default, with zero setup.** Chromium builds its UI tree
   lazily, and `BrowserToolExecutor.snapshot` now nudges it in-process — setting
   `AXManualAccessibility` on the application's AX element, the same attribute
   VoiceOver's clients set — then re-walks. That works on the user's real browser, their
   real profile, with no relaunch: snapshot → click → fill needs no port at all. CDP
   remains for what the tree cannot say (full-page text, `read_page`, CDP screenshots).
2. **One-click agent browser.** The launch-and-port setup moved into
   `DebugBrowser.launchWithDebugPort()` — one shared entry — behind two doors: the
   Settings readiness row's "Set up…" button (no approval card by design: the person
   pressed it themselves in the screen that explains it, and the browser is a scratch
   profile, never their own) and the agent's approval-gated `browser.relaunch_debug`
   (a card, because there the agent decided). The readiness copy no longer mentions
   flags, ports or addresses; "CDP debugging port" became "Agent browser".

- **P2-B (deferred, spike first):** native-messaging host + bundled extension for real DOM
  ids without any special launch. Weeks of work and unverifiable without Chrome plus a
  manual extension load, so it ships as a design spike document, not code, until the
  AX-first + one-click route is measured insufficient in practice.

### P3 — grounding for pixel-only UIs (e2b lesson, local-first)

1. Extend `click` with optional `x`,`y` in screenshot space: the vision model reads the
   consented screenshot, names the coordinate, the executor verifies the element under the
   point via `AccessibilitySnapshot` before posting the event.
2. The coordinate click runs only when `inspect_ui` returned a stub tree — AX-first stays
   the rule, pixels the fallback, consent the gate.

### P4 — policy guardrails (mostly keep what exists)

- Computer and browser tools stay **out of the overheard-speech catalogue**
  (`FunctionCallCatalogue.allowedNamespaces`) — deliberate since the 2026-09-20 audit
  incident; only the direct-to-agent path may drive them.
- Every write stays behind the approval card; screenshots stay memory-only; the purchase
  cap and receipt are unchanged. `--selftest-computer-vision` and `--selftest-seat-grid`
  keep pinning the consent rules.

## 4. Build order and verification

| Wave | Work | Owner files |
|---|---|---|
| 1 | P0.1–P0.2 (vision call site, planner removal) | `RealtimeAgent+ToolLoop.swift`, `Agent/Backend/CodexComputerUse.swift` (read), `Formatting/LLM/*Provider` (read) |
| 1 | P1.1–P1.2 (scroll/drag/clicks/wait_for + self-test) | `Computer/ComputerToolExecutor.swift`, `Agent/Tools/ComputerTools.swift`, `Computer/ComputerSelfTestHarness.swift` |
| 1 | P2-A (CDP detect/relaunch, `read_page`, `wait`, self-test) | `Computer/BrowserCDPClient.swift`, `Computer/BrowserToolExecutor.swift`, `Agent/Tools/ShellTools.swift` |
| 2 | P3 (coordinate grounding) | `RealtimeAgent+ToolLoop.swift` (grounding result), `ComputerToolExecutor.swift` (coordinate click) |
| 2 | P1.3–P1.4 (compact snapshot, readiness row) | `Computer/AccessibilitySnapshot.swift`, `UI/Settings/` |
| 2 | P2-B spike document | `roadmap/` only |
| 3 | Harness + docs | `NextNotesApp.swift` (self-test dispatch), `AGENTS.md` flag list, `README.md` tree |

Compile-check rule for every wave-1 agent: build with a private scratch path
(`swift build --scratch-path /tmp/nn-<agent>`), never `make` (shared scratch), never a bare
`swift build` without a scratch path (iCloud sync corrupts `.build/`). The orchestrator runs
`make` once per wave on the shared scratch, then `make test`, then the self-tests through
`Scripts/run-selftest.sh` (`--via-open` for every TCC-sensitive flag).

## 5. What is deliberately not in this plan

- Any cloud sandbox or remote vision service. The app is local-first; e2b's sandbox shape
  was considered and rejected on privacy and licence grounds.
- Vendoring code from the reference repos. All three are MIT or Apache-2.0 and would be
  licence-compatible, but the value is in the patterns, not the code — this is a Swift app
  and their runtimes are Python, Node and Go.
- Teaching the function-call watcher to propose computer actions on overheard speech. That
  stays refused on purpose.
