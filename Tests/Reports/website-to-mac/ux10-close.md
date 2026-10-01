# UX-00 / UX-01 / UX-10 review — 2026-10-01

This is the source and fixture handoff for the website-to-Mac roadmap. It does **not** declare the roadmap complete. The isolated visual diagnostic is implemented; its compiled run, generated-image review, real-journey capture, manual accessibility review and latency gates are pending root integration.

## Confirmed cause and responsible changes

`RecordingIndicator` created its repeat-forever pulse unconditionally in `onAppear` and always animated changing elapsed digits. `DictationStatusBand` always attached a reveal animation to controller state. The same unconditional presentation animation was present at the meeting list, detail tabs/progress and focused transcript jump. These are presentation producers: the animation is introduced at those view sites, independently of the underlying producer state. Reading `accessibilityReduceMotion` in the orb/avatar did not stop the separate indicator or container animation.

The responsible view sites now read the existing SwiftUI accessibility setting and use nil animation when it is enabled. The recording indicator keeps the red recording proof and elapsed label, with a static dot and identity number transition. Meeting list/deletion, detail tab/progress, and focused transcript scroll update immediately under Reduce Motion. No capture, model, speaker, task admission, permission, queue, data store or timing path was changed.

The original source reproduced the missing branches directly (unconditional `withAnimation(DS.Motion.recordPulse)`, `.contentTransition(.numericText())`, and `.animation(DS.Motion..., value: ...)`). Source after the edits contains the explicit reduced-motion branch at every assigned site. This is **source evidence**, not a runtime accessibility-setting toggle or measured rendering pass. Root must compile and inspect the actual reduced fixture images before claiming runtime verification.

Changed files in this slice:

- `Sources/NextNotes/UI/Components/RecordingIndicator.swift`
- `Sources/NextNotes/UI/Dictation/DictationStatusBand.swift`
- `Sources/NextNotes/UI/Meetings/MeetingsView.swift`
- `Sources/NextNotes/UI/Meetings/MeetingDetailView.swift`
- `Sources/NextNotes/UI/Meetings/TranscriptView.swift`
- new `Sources/NextNotes/UI/ExperienceSheet.swift`

## Safe visual diagnostic

Register `--selftest-experience-sheet <output-directory>` **inside** `NextNotesApp.runRequestedSelfTest`. It calls `ExperienceSheet.write(to:)`, sets `SelfTest.failed` from the returned Bool, then terminates. Root owns this registration and serial build.

The diagnostic refuses execution outside the self-test harness, refuses output anywhere in Application Support (including symlink resolution), and compares `SelfTestStoreGuard.take()` before/after. It constructs placeholder `AgentTask`, `ToolCallReview`, and `TranscriptSegment` values, uses the actual production view types, and never submits a task, opens a permission request, invokes a send, starts audio or reads an owner meeting. Existing shared identity and view stores use their harness behavior. Fixture activity is reset before and after the render. Button closures intentionally do nothing: this is a capture surface, not a simulated production interaction.

It writes **72 PNGs**: nine surfaces × two content widths × two appearances × two accessibility variants.

| Axis | Values |
|---|---|
| Surface | Working card; ready review; missing-recipient review; failure result; dictation ready; real-capture startup; finishing; recovery error; transcript |
| Content width | `DS.Size.detailMin` (560 pt); 1000 pt |
| Height | `DS.Size.windowMin.height` (600 pt) |
| Appearance | Aqua/light; Dark Aqua/dark, explicitly applied both to the host and SwiftUI |
| Accessibility variant | Standard; Reduce Motion + Reduce Transparency together |

The 560 pt capture is the app's detail floor, stricter than simply taking 900 pt as the whole content width. It is **not a 900×600 main-window screenshot**: the sidebar, toolbar, inspector, meeting split view and island are absent. The diagnostic uses the existing SettingsSheet offscreen `NSHostingView.cacheDisplay` approach so native controls and List actually draw. It needs no Screen Recording grant and never orders a panel on screen. `EXPERIENCE_SHEET_OK` means images were produced and owner-store snapshots matched. It says nothing about keyboard behavior, VoiceOver, focus rings, live motion, effect success or latency.

## Accessibility and visual source audit

| Area | Source evidence | Required remaining observation |
|---|---|---|
| Semantic appearance | DS semantic window/text colors; native controls; host scheme explicitly light/dark; glass boundaries reused | Review both appearance images and contrast on a real busy background |
| Recording signal | Red dot plus Recording accessibility label and real elapsed counter; Reduce Motion now static | Toggle setting during recording; confirm indicator remains legible and voice output is not repeatedly interrupted |
| Working mark | Existing AgentAvatarView hides decorative face from accessibility, removes TimelineView under Reduce Motion; step title is task scoped | Verify one live mark in the actual pane and island during overlapping work |
| Approval | ToolReviewCard combines title/reason once; separate field labels/hints; missing values disable primary action; native default/cancel shortcuts; keyboard and accessibility focus on appearance | Actual Tab order, focus ring, Return/Escape routing, blocked primary action, one VoiceOver announcement and restored focus after decision |
| Result/failure | Selectable native result text; failure combines summary/undo; actions are native labeled buttons | Verify result remains reachable, actions individually accessible, long failure text readable at actual minimum window |
| Scroll continuity | Agent reader intent/Latest update; meeting List uses actual geometry and latest-line affordance; search jump honors Reduce Motion | Real chunk/final arrival while reading old text, text selection and VoiceOver reading; no unwanted jump |
| Reduce Transparency | GlassSurface branches to existing material; island/HUD use it | Actual system preference and busy-screen readability; offscreen branch image alone cannot prove this |
| Background motion | ThinkingOrb removes TimelineView under Reduce Motion; OrbBackdrop pauses for inactive control state; avatar uses frozen branch | Profile active/collapsed/offscreen row drawing during real voice, dictation and meeting load |
| Meeting names | Finished meeting title also has a native Rename menu; live title has double-click plus list context-menu route | Confirm keyboard discovery/accessibility of rename while live, without requiring double-click |

## Remaining source handoffs

- Root owns `AgentView`: its explicit scroll `withAnimation` sites need the same Reduce Motion branch. Streaming text already scrolls without repeated animation in current source.
- Onboarding owner/root owns `OnboardingWindow.swift`: `OnboardingFlowView` attaches an unconditional reveal animation to `model.step`. Its `move`/`finish` methods contain no independent animation. Add the environment branch there; `OnboardingFlow.swift` is the state model and does not own motion.
- Dictation/onboarding owner owns `DictationView`: history insertion still attaches `.animation(DS.Motion.fluid, value: runs.map(\.id))`; apply the existing accessibility branch there.
- `HUDView` currently leaves `RecordingIndicator` mounted with `.opacity(0)` outside recording. The pulse can continue invisibly in normal motion. Its owner should conditionally render the recording indicator while `isRecording`, retaining the same layout as needed. This is a concrete offscreen animation concern; no CPU regression measurement has been made.

## Gates still open

1. Root serial packaged build and named self-tests after integrating concurrent producer/UI work; bare-binary evidence from the previous checkpoint does not cover these files.
2. Run the new fixture diagnostic, inspect the images, and fix any observed clipping/readability problem at its layout producer. Keep images or explicit artifact paths with the exact build identity.
3. Sanitized real four-journey captures in light/dark at 900×600 and larger, actual notch/floating display as available. Record event → state → first-visible-frame timestamps; a static sheet cannot supply them.
4. Keyboard and VoiceOver review; Reduce Motion and Transparency setting toggles; text selection/scroll continuity through real streamed updates. Mark unavailable physical displays or grants explicitly unverified.
5. AGENT-OVERHAUL Phase 2 measured main-actor/voice gates and UX-00 feedback timing. No artificial delay or extra user-turn await was introduced by this slice, but absence of a new await is not a latency measurement.

`git diff --check` passed for the assigned files. No build, install, self-test execution, screenshot capture, manual accessibility session or latency measurement was run by this worker. UX-00/01/10 retain their open visual/live gates until root records that evidence.

## Freeze review follow-up — before serial build

Source was reread after root's Reduce Motion branches in `AgentView` and `OnboardingWindow` and the single-active-avatar selection. Those two handoffs above are now implemented in source; their original live gates remain open.

### One confirmed SDK type blocker repaired

The installed macOS SDK's `SwiftUICore.swiftinterface` declares `accessibilityReduceMotion` and `accessibilityReduceTransparency` as get-only properties. The fixture's first `.environment` calls therefore supplied read-only key paths to an API needing writable ones. The same SDK declares `_accessibilityReduceMotion` and `_accessibilityReduceTransparency` get/set. Root authorized changing exactly the two **diagnostic-only** key paths to these writable keys, after which the file was frozen again. Production views continue to read the public accessibility properties. SHA-256 after the narrow change: `2c17b0732be5f3098364e10dc88bd74cc27716e61659eecdaa1cf4e7289f81ab`. This is a confirmed source/API contract repair, not a completed compile: root's serial build is still required.

Other fixture calls were checked against current signatures: `SelfTestStoreGuard.take`, `AgentTask` running constructor, `AgentActivityStore.begin/update/resetForSelfTest`, `.writing` avatar state, `ToolCallReview`/`ToolCallField` members, `.send` risk, transcript constructors and the existing NSHostingView cacheDisplay approach. No further concrete signature mismatch was found. This does not substitute for Swift type checking or packaged resources.

### Minimum-window and pending-review cases the current sheet does not cover

| Source relationship | Concrete missing case | Action after serial build |
|---|---|---|
| `MainWindow` sets 900×600; sidebar min/ideal/max is 200/230/320; detail floor is 560 | Actual sidebar + toolbar + Agent pane switcher + composer + review, rather than a 560×600 leaf | Capture the actual shell at 900×600 and larger with sidebar at ideal and expanded width. The current content PNG cannot establish the shell gate. |
| Agent uses `ViewThatFits`; inspector arrangement requires 960 pt of detail; inspector is 340 pt wide | Inspector hidden/offered across its real threshold | Capture below and above 960 pt detail width; verify toggle disappears when it cannot be offered and composer remains usable. A 1000 pt card-only image never exercises the inspector. |
| External pending review is inside `AgentView.safeAreaInset(edge: .bottom)` in a non-scrolling VStack | Open “Read and edit” (140 pt body editor), open “Tell me instead”, keep a multiline composer draft and a model caption visible in the 600 pt window | Reproduce through the actual card controls. Measure available content height and verify both primary decision and composer remain reachable. If overflow is observed, fix the inset's review layout with bounded scrolling while keeping the composer stable; do not shrink text or hide fields/actions. This is a **source-identified overflow risk**, not an observed clipping failure. |
| Ready fixture passes `alwaysAllow: nil`; missing fixture uses email only | Long primary labels (calendar action), scoped “Always allow this”, many/long fields and suggestions | Add these layout cases after the freeze, inspect narrow images, and use native wrapping/adaptive arrangement only where a real overflow is demonstrated. |
| Fixture starts reviews collapsed; private `asking`/`expandedBody` state is reached only via controls | Expanded editor and question path never appear in the current 72 images | Drive those controls in a sanitized actual fixture window or add a narrowly justified diagnostic initializer/state seam, without adding a production state layer. |
| Meetings uses a fixed HSplitView with minima 220 + 360 plus divider | Actual meeting detail can be 360 pt, narrower than the generic 560 pt diagnostic | Capture the meeting shell at 900×600 with sidebar and split divider at supported extremes. Add a 360 pt transcript/detail layout case; do not claim the 560 pt image covers it. |
| `Sidebar` still has unconditional recording/selection fluid animation | Reduce Motion across the shell during real recording/section navigation | After freeze, add the same public setting branch if this shell motion is within the reviewed release slice; inspect while recording starts/stops. |

### Original four-journey coverage remains a separate requirement

The new sheet is static layout evidence for individual real components. It does not contain an accepted user row, real chunk arrival, sent choice acknowledgement, effect result, meeting lifecycle, dictation insertion, island/HUD continuity, first-success onboarding or a real main window. The original roadmap's four journeys still require sanitized production flow captures and event/state/frame timing. A static fixture can fill the visual baseline where screen capture is unavailable, but cannot prove the agent performed an action, the target retained focus, the speaker/microphone overlapped, or the first visible frame arrived within budget.

Root reported native app capture failing with `SCStreamError -3811`; that is an observed capture limitation, not a manual VoiceOver or keyboard pass. Record it beside any substituted offscreen imagery. Keep unsupported physical notch/external-display evidence unverified. No SDK/prototype evidence changes the explicit roadmap release gates.
