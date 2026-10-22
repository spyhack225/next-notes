# Settings app29 — packaged inheritance check, 2026-10-02

Installed executable SHA256 `c7e6468913226d281684ed2fa1fdbfe03a1b218882b4e1d0aa868266602b0eee` was checked before and after every capture. The runtime root released this bounded grant-free native slot and reclaimed it immediately after completion for builds30/31. No Source, build, install, model or CUA action was performed during the capture slot.

## Responsible producer and verification

The original SettingsSheet capture roots omitted the enclosing SettingsWindow's font/tint modifiers. The four-line correction supplies the existing `.tint(DS.Color.accent)` and `.font(DS.Font.body)` to both existing capture roots; no SettingsWindow lifecycle or new abstraction is added. The archived root Source manifest includes SettingsSheet SHA `5f0088724bde7c88789eb3632ac32fc305273e2e851fe1ec735ed7b6eb1c3b40`.

Actual packaged captures now exercise that corrected root through the real pane factory. Computer, Formatting and Agent each render at320/560 across standard, Reduce Motion, Reduce Transparency and combined variants: six successful invocations,24 PNGs. Each invocation returns exit0, actual injected-constructor and persistent-write negative guard markers, awaited-consumer evidence, final `SETTINGS_SHEET_FIXTURE_OK`, and an unchanged executable. The final marker enforces the existing durable owner preferences and watched-store guard. Original volatile registration differences remain visible in the logs. `summary.json` and `artifact-manifest.json` preserve the exact result and artifact hashes.

This verifies the packaged capture producer supplies the missing modifiers and can render with isolation intact. It does not prove every native control honors those modifiers or establish live accessibility, effects or timing. The app25 originals remain under [settings-app25](../settings-app25/README.md); their omitted font/tint is not silently erased. This is not a strictly isolated whole-binary comparison: unrelated runtime work also landed between25 and29.

## Actual visual findings

| Area | Observed in app29 | Remaining work |
| --- | --- | --- |
| Computer320 | Screen/System Audio title competes with status/action; Unanswerable splits midword and Open the pane action truncates | Reviewed responsive row candidate remains unapplied |
| Computer560 | Full status and readiness labels fit | Actual supported-height shell, native controls and focus still unverified |
| Formatting320 | App header splits into vertical letters; Add apps action truncates | Reviewed header/control candidate remains unapplied |
| Formatting560 | App header and file actions fit | Profile rows are absent in both widths; native List/capture behavior remains open, no row fallback admitted |
| Native link style | Reveal formatting.txt and Manage in Models remain blue despite the supplied black theme tint | Missing inherited tint alone does not explain the color; investigate the native link consumer, retaining real control/focus behavior |
| Agent visible controls | Top controls readable at both widths | Tall leaf capture does not prove full-height shell, scrolling, keyboard or VoiceOver behavior |

Inspected standard images for all six pane/width cases and Agent560 combined-reduced output. Image generation for the other variants is a checked artifact result, not a motion/contrast sign-off. No on-screen product color defect is claimed solely from these offscreen captures.

## Open release gates

Responsive fixes, native link investigation, profile List rendering, actual shell composition and supported-height actions remain open. Native `.task`/`.onAppear` delivery, keyboard, VoiceOver, focus/scroll continuity, physical dictation/meeting/cross-app flows, background clock budget and first-visible/voice latency are not verified by this diagnostic. CUA app approval remains separate from the owner's unlocked Mac. No UX task is promoted to verified/done.
