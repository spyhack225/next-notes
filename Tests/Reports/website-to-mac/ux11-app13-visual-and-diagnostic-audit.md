# App13 visual and Settings diagnostic audit

Date: 2026-10-01. Readonly subagent review; no source, build, native test, owner data or roadmap-status changes. `app13` identifies the parent's installed capture run, not a verified source revision or binary hash. This report contains no captured credentials, owner transcripts, or reproduced Settings images.

## Evidence and limits

The parent supplied `/tmp/nextnotes-agent-closure-ui-13/summary.json`, safe fixture captures under `/tmp/sheets/setup-app13` and `/tmp/sheets/experience-app13`, and the native layout sample `/tmp/nextnotes-agent-closure-settings13.sample.txt`. The Settings diagnostic produced 36 pane files before those outputs became unavailable at their original location; its metadata explicitly records that they were live-store output, not sanitized fixture evidence. Private local originals must not be treated as shareable artifacts.

The onboarding-sheet process exited 1 and its exact final marker was `ONBOARDING_SHEET_FAILED: owner stores changed`. This is an isolation failure, not a rendering assertion. The responsible writer is not established by that marker. Concurrent owner activity and other processes must be distinguished before attributing a producer bug.

The experience-sheet process exited 0; its producer also checks the watched owner-store snapshot, so this is image-production plus that isolation check, rather than image production alone. The Settings-sheet process exited 0 after 189.398 seconds without the same guard. Neither marker establishes keyboard access, VoiceOver, live scrolling, real practice success, visible action acknowledgement latency, or acceptable live UI performance.

## Safe fixture observations

| Actual file | Observation | Acceptance scope |
| --- | --- | --- |
| `setup-app13/onboarding-welcome-allowed-reduce-transparency.png` | The no-account reassurance now precedes the identity example card and is fully visible initially. Main heading, card, Get started and navigation footer fit. | Initial 720pt onboarding fixture layout with Reduce Transparency. |
| `setup-app13/onboarding-allSet-not-allowed-reduce-transparency.png` | Greeting, result rows and clearly labeled example review are readable. Done remains visible. The login item extends below the initial content viewport. | Footer is not clipped; actual scrolling remains unverified. |
| `setup-app13/onboarding-welcome-allowed-reduce-motion.png` | Main content viewport is black. | That capture cannot certify normal content readability. |
| `experience-app13/working-560-os-light-standard.png` | Nearly all the content is black; outline and the upper color beam remain visible. | Standard capture readability unavailable. |
| `experience-app13/reviewReady-560-os-light-standard.png` | Black image rather than readable review content. | Standard capture readability unavailable. |
| `experience-app13/reviewMissing-560-os-light-standard.png` | Black image rather than readable missing-input content. | Standard capture readability unavailable. |
| `experience-app13/working-560-os-light-reduced.png` | Avatar, current step, progress count, Stop and footer fit and are readable. | Actual reduced-mode card fixture, not ongoing production work. |
| `experience-app13/reviewReady-560-os-light-reduced.png` | Recipient, subject, message and Read and edit / Dismiss / Send it controls fit. | Static approval fixture, not a real send or confirmation. |
| `experience-app13/reviewMissing-560-os-light-reduced.png` | Missing-input label, placeholder, explanation and response/dismiss controls fit. Send is disabled. | Static incomplete-review fixture, not a completed answer interaction. |

The parent independently observed standard and Reduce Motion onboarding captures black, while Reduce Transparency-only was readable. This isolates an accessibility/material axis in the offscreen diagnostic. It does **not** establish that the live app has the same black viewport or that a particular production material producer is defective. Do not compensate by changing the product palette on this evidence alone.

The readable cards have strong dark primary text against pale surfaces; muted provenance text is visually readable. This is not a numerical all-states contrast signoff. The earlier opaque-palette contrast report remains narrower source evidence; alpha, focus, native selection, and all appearance states require their actual renders.

## Settings source contract and observations

At review time, `DS.Size.settingsPaneMinWidth` was `detailMin - settingsSidebarWidth` = 560 − 240 = **320pt**. Its comments explicitly call this the supported embedded main-window pane floor. `MainWindow` embeds `SettingsWindow` in the 560pt detail minimum; the nested Settings sidebar consumes space. The standalone Settings minimum is 800pt total, leaving **560pt** for its pane. `settingsCardMinWidth = 560` controls grid column count, not the embedded pane minimum. If the product changes its supported floor, the host and tests must agree before 320pt observations are dismissed as unsupported.

Before the unsafe inputs were identified, the 320pt captures showed fully drawn 36pt heading bands, sometimes wrapping across several lines. They are 1120pt-tall diagnostic panes, not a whole minimum-height Settings window. The Computer grant row had a broken status wrap and a truncated action label; Formatting app header and add buttons were cramped/truncated. Those need fixture-only rechecks at the actual host floors. No current 560pt image review is claimed here because the outputs were unavailable when the follow-up began.

The Agent capture's Manage in Models link remained native blue. Source producer: `AgentSettingsTab` applies `.buttonStyle(.link)` to this Button while the surrounding host sets the shared tint. This is actual rendered evidence for that control; a palette-consistent fix belongs at the reusable native link styling seam, followed by a native render, rather than adding unrelated per-pane colors.

Workspace capability copy is rendered from live tool metadata and can display raw tool identifiers. A static UI-string scan passing does not certify those dynamically generated words. Inspect the capability-display producer against the existing consumer-friendly naming contract before signoff.

The 189.398s Settings run and the parent's observed high CPU are diagnostic performance concerns, not a measured live UI latency failure. The sample stacks show `SettingsSheet.write` / `render` → `NSWindow.setContentView` → native hosting/layout work. They do not establish which view caused the cost or whether the owner experiences it. A bounded isolated pane capture with recorded duration is the next useful measurement; do not add sleeps or timeouts to the user path.

## Why Settings capture reads private inputs

1. `NextNotesApp` dispatches `--settings-sheet` before the requested self-test branch. The flag does not match `SelfTest.requested`; `SelfTest.isRunning` is false. `SettingsSheet` explicitly documents that it reads live stores.
2. `Settings.shared` chooses `UserDefaults.standard` outside SelfTest. `CalendarSettingsTab` binds the client fields directly to those settings. The visible client fields are preferences; they are not read from Keychain by those bindings.
3. `CalendarSettingsTab.adoptableClient` evaluates `GoogleClientConfig.installed`. That producer reads `GoogleWorkspaceCLI.clientConfigURL` directly. The existing `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` environment override can redirect this file boundary to an empty temporary fixture directory.
4. The Calendar `.task` calls `refreshGoogleCalendars()`. That method guards the Google-enabled preference, but does not explicitly guard SelfTest or fake-provider mode. With live configuration it reaches the real Google provider. No claim is made that a network call occurred in this capture.
5. `GoogleCalendarProvider.authorizationState()` and access-token refresh reach `GoogleTokenStore.refreshToken`, which calls `SecItemCopyMatching` against the login Keychain without a SelfTest guard. The service/account code is the seam; no Keychain value was inspected for this audit. Token revocation handling can call `signOut`/clear during a real failed request, so inert rendering alone is insufficient isolation proof.
6. `ComparisonView` uses `RunStore.shared`. Its initializer and `onAppear` reload via `RunLog.load()`. `RunLog.directory` uses its existing TaskLocal override, otherwise the owner's application-support directory; it is not automatically isolated merely because SelfTest is true. The comparison cards render stored transcript content.
7. `SelfTestStoreGuard` detects changes to its listed files/preferences; it does not prevent reads, and `--settings-sheet` does not call it. Its watched preference prefixes do not include the current Google credential/calendar keys. A clean guard verdict alone would therefore not prove credential preference isolation or absence of Keychain access.

No settings button was clicked by this review. No owner-file write, Keychain write or actual network call is asserted from source reachability alone.

## All twelve pane input/effect seams (source only)

The table follows `SettingsWindow.pane(for:controller:)`; it does not infer a credential read merely from a pane's name. Existing SelfTest guards below apply only if the diagnostic actually starts in that mode.

| Pane | Input/read producer and automatic lifecycle seam | Fixture implication |
| --- | --- | --- |
| General | `Settings.shared`; hotkey/setup effects are button/binding setters, not initial reads. | Existing isolated preference suite; do not invoke setters. No initial provider credential field found. |
| Dictation | `Settings.shared`, `LocalModelStore.shared`, `RunStore.shared`; latest cleanup details and history counts derive from runs. | RunLog isolation is necessary here as well as Comparison. Placeholder auto-send app preferences. |
| Comparison | `RunStore.shared` initializer and actual view `onAppear` reload `RunLog.load`. | Actual reload must stay within existing temporary directory override; cards can otherwise render owner transcripts. |
| Formatting | `OutputProfileStore.shared` reads `formatting.txt`, seeds/saves defaults if absent, installs a file watcher and frontmost-app observer. `ScreenContextStore.shared` starts empty but supplies remediation state. | No SelfTest branch at OutputProfileStore file boundary was found. Must isolate that existing file producer; not just blank preference bindings. No initial credential field found. |
| Meetings | Settings, local/installed model stores and model roles; selected call-app preferences can populate rows. | Fresh isolated preferences and supported existing model fixture mode. No direct provider credential field found in this pane. |
| Calendar | Preference-bound client fields, installed Workspace client file, automatic calendar refresh and Google token lookup, detailed above. | Empty existing config-directory override plus diagnostic-scoped live-provider/Keychain refusal. |
| Workspace | `Settings.shared`, `AgentService.shared`; `.task` invokes `refreshStatus()`, whose CLI probes inspect installed/auth status. | Point CLI config at empty temp and use existing AgentService/CLI fixture seam; avoid launching real auth probes. `GoogleClientConfig` path can appear in explanatory copy. |
| Agent | Persona section is only an editor link; memory, schedules, grants and knowledge sections consume shared stores. NextMemory, ScheduleStore and KnowledgeIndexer already select temporary SelfTest roots. Messages-access `.task` calls `Permissions.messagesAccessState()` → `MessagesDatabaseHealth.probe()` with its default owner database; iMessage section `.task` explicitly constructs `RemoteIdentityStore` with owner support directory. Indexed folder appearance may refresh stats/access and start scanning when enabled. `onDisappear` can mark new memories viewed. | Retain existing isolated stores, but explicitly fixture Messages health's existing `databaseAt` seam, pairing configuration and indexed-folder settings/readers. Fresh defaults alone does not reroute explicit support-directory constructors. |
| Computer | `onAppear` reads accessibility state/running browsers and runs `BrowserCDPClient.probe()`; this inspects local debugging targets. Setup/Grant buttons are not clicked. | Fixture the existing readiness/probe seam for reproducible labels; no initial provider credential field found. |
| Integrations | `ComposioProvider.isSignedIn` → `consumerKey` → automatic legacy migration and `ComposioCredentialStore.apiKey` (unconditional Keychain lookup). A nonempty legacy preference with missing Keychain credential can save/migrate during that getter. `MCPClientStore.shared` initializer reads owner `mcp-servers.json` without SelfTest directory routing. SecureField's new advanced-key state starts empty; it does not read the saved credential into the field. | Diagnostic-scoped Keychain/migration refusal and actual MCP file fixture are needed. Do not call the computed account-status getter read-only on source evidence. |
| Models | OpenRouter input starts empty. `onAppear` skips `OpenRouterKeyStore.hasKeyAsync()` in SelfTest; `ModelLibraryStore.refreshAccessKey()` skips Hugging Face credential checks and its token getter returns nil there. However `loadRecommended()` can still make an anonymous Hub search; selected speech engine preparation can also run. ModelLibraryStore post-download policy reads `UserDefaults.standard` directly. Usage section loads `UsageLog.shared` (already temporary under SelfTest). | Preserve existing provider-key guards. Fixture/suppress optional catalogue and voice preparation for this capture only; do not weaken live model tests. Check direct policy preferences and actual model-library fixture routing. |
| Permissions | Actual `PermissionsChecklist` refresh checks grants and calls Messages health's default database reader; notification authorization is also fetched. | Existing checklist fixture support, or existing Messages `databaseAt` fixture seam, is needed for deterministic capture without owner database reads. No initial provider key field found. |

`ComposioCredentialStore` and `GoogleTokenStore` have no general SelfTest reader guards today. A new refusal must be **specific to the fixture diagnostic**, so it does not silently break other installed live/self-test contracts. OpenRouter and Hugging Face view lifecycle guards are already specific existing protection to preserve.

The three subagent-created private Settings mosaics were removed by exact filename after the parent's explicit instruction; only file hashes/dimensions remain in `/tmp/sheets/app13-review/private-settings-mosaic-metadata.json`. No owner file was removed, and no private image/content is included in this report.

## Smallest remaining checks

- Run a fixture-only Settings capture through the existing SelfTest selection/defaults mechanism. Before first view/store initialization, isolate the existing RunLog seam, redirect the Workspace client-config directory, and prevent the Calendar pane from reaching live providers/Keychain. Preserve the intentional private diagnostic separately if still needed.
- Use placeholder fixtures through the actual Settings factory, not screenshots scrubbed after rendering. Mutation-sensitive checks must prove the real Calendar and Comparison consumers receive fixture data and cannot read the owner boundaries.
- Re-render only the problematic safe panes at 320pt embedded and 560pt standalone widths after confirming the host contract. Use the minimum-height actual shell for footer/scroll acceptance; the 1120pt pane diagnostic is only width evidence.
- Recheck the shared native link styling with a native render. Check selected/unselected actual native rows with the separately documented production-row fixture; opaque palette ratios do not answer native selection.
- Finish live keyboard, VoiceOver, practice, actual approval/edit/cancel and timed acknowledgement checks on a pinned binary. Keep the voice latency acceptance contracts unchanged.
