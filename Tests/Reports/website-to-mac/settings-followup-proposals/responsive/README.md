# Settings responsive candidates after app29

Status: **UNAPPLIED, source-only proposal**. Current Sources, compiler, build, installed app, native/model execution and staging stayed frozen. This package contains two current baseline copies, two proposed copies, their individual/combined patches and hashes. It reconstructs the bounded prior proposal because the temporary package is absent. No native success is claimed.

## Original reproduced output and responsible producers

The archived [app29 capture report](../../settings-app29/README.md) records the actual corrected font/tint capture producer and isolated real pane factory. The Computer320 standard image visibly splits `Unanswerable` after its final letter and truncates `Open the pane…`; the Formatting320 standard image stacks `App` vertically and truncates `Add apps Next Notes knows about`. Those exact original PNG hashes are pinned in hashes.json. Both corresponding 560 captures fit according to the archived report. Existing screenshots were inspected; no new capture was performed.

The source owners still produce a single horizontal ReadinessRow for title/status/action, and a single horizontal Formatting App/capability header, file-action pair and app-control pair. They have no native layout alternative when those actual intrinsic labels compete for the narrower width. This confirms the missing producer layout choice; whether the proposed choice resolves the original native failure remains unverified until the same fixture is captured again.

## Exact two-file scope

| Source | Proposal |
| --- | --- |
| `ComputerBrowserReadiness.swift` | ReadinessRow only: `ViewThatFits(in: .horizontal)` chooses the original wide row when its full native title/status/action fit, otherwise title above the same status/action group. Busy orb, status ink, semantic text, actual button closure and details are retained. Native action takes its intrinsic width; fallback status can wrap by the platform. Only existing DS spacing/fonts/sizes are used. |
| `FormattingSettingsTab.swift` | HEADER, FILE, CONTROL only: App/capability header, Add-defaults/Reveal file actions, Add/remove/frontmost controls get native horizontal/stacked alternatives. Existing menu items, bindings, help, disabled state, selection mutations, reveal action and link style are retained. Fallback spacer is plain `Spacer()`; all added numeric spacing uses DS tokens. |

Computer's current exact `--selftest-settings-sheet` refresh suppression is preserved byte-for-byte; the patch contains no refresh or isolation hunk. Apply this candidate to the current guarded source, not an old combined fixture-plus-layout patch.

Formatting's `profileList`, its selection and keyboard scroll handling, OutputProfileRow and every declaration after `// MARK: - Row` are byte-for-byte identical in baseline and proposal. No List row fallback, fixed height, additional scroll surface, global width floor or inherited-theme change is included. There is no new view/model/store layer; private helper properties reuse the same native controls in the two native layout alternatives.

Native links remain unchanged in this standalone responsive patch. The UI root owns the separate native-action proposal and merged review; these captures do not establish an on-screen product color defect, and no link producer change is bundled here.

## Applicability and static preservation evidence

`git apply --no-index --check ../responsive-two-file.patch` returned exit0 from this package's **baseline copy directory**, whose `Sources/...` paths contain only the two copied files. Nothing was applied to production Sources. Exact hashes live in hashes.json. Source assertions during preparation verified unchanged Computer refresh-through-runningBrowsers logic, unchanged Formatting profileList and unchanged full row/editor suffix. These are static checks, not compilation or native interaction evidence.

Combined patch SHA-256: `e9b96b91d7108367ebdea8df242af36066ff4f2a4242dbd29f7d7a9143017700`.

## Required original/current acceptance

After the runtime root releases the serial slot and approves source integration:

1. Reconfirm both source baselines before applying only these two hunks. Compile through the existing serial build owner; applicability alone is not a typecheck.
2. Reuse the actual app29 sanitized Computer and Formatting fixture inputs, corrected inherited font/tint, 320 embedded and 560 standalone widths, and all four independent RM/RT axes. Preserve original/current executable, source and PNG hashes. Do not substitute shorter copy, alter fixtures to fit, force reduced transparency, or hide native content.
3. Confirm `Unanswerable`, `Open the pane…`, `App` and the Add-defaults action fully display at 320. At 560 confirm the native single-row layout remains. Profile List rows were absent in app29, so this proposal supplies no List-rendering proof.
4. Check actual supported-height shell rather than the tall leaf bitmap: scroll reaches actions, native control hit targets/keyboard focus/help/VoiceOver order remain correct, and wide/narrow transitions preserve bindings and selection. Busy orb/status/actions must retain their existing actual state and permissions. Test real grant actions only through the authorized owner path, not the fixture renderer.
5. Frontmost-app controls need an explicitly harmless producer fixture to check a long dynamic label; do not expose the owner's actual app names or turn owner observers back on for a screenshot. No such fixture or native interaction was run here.
6. Verify native ViewThatFits admission during an actual busy row: several measurement alternatives refer to the status/orb helper. App29 fixture statuses are idle, so they cannot establish that unused alternatives stop their canvas clocks. Preserve the one-live-mark/draw-budget contract; do not infer it from one visible image.

Until these pass, clipping resolution and roadmap visual acceptance remain open. No UX task or broader Agent readiness is promoted by this proposal.
