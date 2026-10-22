# Benchmark hub verification — 22 October 2026

Historical hub verification before the owner-authorized Git consolidation. Current committed state and retirement evidence are recorded in [the consolidation report](inventory/worktree-repair-2026-10-22/README.md).

Implemented in the canonical working tree, alongside retained unrelated staged and unstaged work. No commit, push, deployment, owner-store migration, model download, native benchmark or application installation was performed by this task.

## Coverage and scope

- 29 summary records: eight ASR runtime models, five cleanup configurations, decision-model comparisons, historical TTS, sustained decode, Agent quality, voice latency, meeting/workflow evidence and explicitly pending new TTS/live-ASR runs.
- 3,212 current evidence files indexed across reports, bench, docs and completed/in-progress/todo/backlog roadmaps. This is discovery, not 3,212 independent benchmark runs or semantic reviews.
- All 26 current local/remote refs and 22 worktrees audited. 1,402 historical paths absent from the canonical checkout indexed separately, with exact Git retrieval pins and available local-worktree links. All variants/identities remain in compressed audit JSON.
- Selected accessible prior chats read; ASR and TTS agents replied through relay. No claim to have read all archived/inaccessible conversations, recovered deleted/unreachable Git objects, or inspected ignored owner files.
- Existing evidence stays in place. No broken links were introduced by moving reports; registered source paths are validated. Legacy reports are not silently rewritten or promoted from a roadmap's “done” label.

## Checks actually run

| Check | Result | Limits |
|---|---|---|
| `python3 -m unittest discover -s Scripts -p test_benchmarks.py` | 10 pass | Registration/discovery, duplicate refusal, traversal/symlink/missing-source rejection, publication review, private field projection, unknown samples, invalid measurements, stale output and active log growth. No model substitution claims. |
| `python3 Scripts/benchmarks.py render` then `check` | Pass, 29 records / 13 generated outputs | Current source membership snapshot; does not rerun or regrade benchmarks. |
| `npm run typecheck && npm run lint && npm run build` in site | Pass | Existing main-bundle >500 kB advisory remains. Benchmark page/data is a separate lazy chunk (about 39 kB, 7 kB gzip). |
| Actual Vite-loaded React component rendered through ReactDOMServer | Pass: 29 articles/details, labelled filters; no `/Users/` or `Tests/Reports/` paths in HTML | Structural rendering only; no client filter interaction or physical browser layout claim. |
| `xcrun swiftc -frontend -parse` on GeneralSettingsTab and BenchmarkResultsView | Pass | Syntax only. Native typechecking/linking, sheet interaction and installed acceptance remain unrun by this task. Native build ownership remains with the TTS chat. |
| `git diff --check` on owned source/page/catalog paths | Pass | Shared pre-existing edits are preserved. |

An initial inventory check correctly exposed a design problem: continuously appended TTS build logs changed stored sizes/hashes between render and check. The catalog now inventories membership without reading payloads, while the separately dated audit retains sizes and content identities. The actual active-log fixture now passes; this also avoids hashing reports on every website build. Unknown historical sample counts remain null rather than invented single-trial counts.

Browser verification was attempted. DevTools reported its profile already owned by another browser process; that process was left alone. The in-app browser could not reach the local preview, although local HTTP returned 200. No screenshot, visual/mobile acceptance or browser interaction success is claimed. The disposable preview server was stopped. The failed temporary in-app tab is left to the tool's automatic end-of-turn cleanup.

## Remaining integration

The built website lives in tracked `docs/`; live publication is not verified. The app source adds **Settings → General → Benchmark results**, loading the same page in an on-demand nonpersistent WebKit sheet with loading/failure states and a browser option. No repository scan or benchmark runs during startup, dictation, capture or voice. This new sheet needs the next coordinated native build and UI check.

Future producers must emit/register a unique run manifest; after that registration, index generation and site inclusion are automatic. Existing legacy source discovery does not manufacture summary metrics. Public inclusion requires explicit content review. The active TTS/live-ASR producers have the format, but their native results and registration adoption remain pending; no automatic completion is claimed for their work.

## Artifact lifecycle

No worktree, model, recording, user preference, branch, unrelated process or existing report was removed. Removed the superseded owned uncompressed audit (24,069,498 bytes), retaining its compressed replacement; removed only this task's two Python bytecode files. The useful compact catalog/audit and built site remain. No whole-disk space improvement is attributed to this cleanup while other agents are building. No native binaries or model weights were created by the hub task.
