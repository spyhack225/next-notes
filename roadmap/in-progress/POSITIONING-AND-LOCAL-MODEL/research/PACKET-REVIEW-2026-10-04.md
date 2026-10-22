# Packet review: PL-11 Catch-up and PL-08/09 first run + Google (2026-10-04)

Read-only review. Nothing was built, run, installed or edited. Source: worktree
`~/Library/Caches/NextNotesBuild/claude-worktrees/positioning` (base `b62e76d`, a snapshot of
the main working tree, not for merge). Line numbers refer to that worktree. Both patches
reverse-apply cleanly to the worktree (`git apply --check --reverse`), including the PL-11
packet as refreshed at 20:24, which adds the real-voice render case and the
`LongFormSynthesisFactory.pocket` `prepare()` change.

Bar applied: AGENTS.md "What we optimize for", "Reuse, integrate and clean up" and "Fix bugs at
the source", plus the two specs (`05-FIRST-RUN.md`, `06-CATCH-UP-AND-ANTICIPATION.md`).

| Packet | Verdict |
|---|---|
| PL-11 Catch-up | **Ready after the fixes listed below** (3 must-fix, all small) |
| PL-08/09 first run + Google | **Ready after the fixes listed below** (2 must-fix, small). It ships dark behind the placeholder client, so the risk to users is low until the owner registers a client. |

---

## PL-11: Catch-up

### Correctness

**M1. A catch-up can be delivered twice when the Mac wakes from overnight sleep (must-fix).**
`AgentScheduler.recentCatchUp` (AgentScheduler.swift:915–923) only counts another catch-up as
having reached the person if its `lastRun.outcome` is `.completed/.ranNow/.delivered/.deferred`.
Scenario: the lid is closed at 23:00 and opened at 07:30 on a weekday. `runOnce(07:30)` calls
`observePresence` first (:459), which publishes `.returned` (8.5 h away). The subscriber is a
plain `Task { @MainActor … handleTriggerEvents }` (:865–868) and is **not** serialized behind the
pass. The same pass then claims the missed 06:00 morning slot (`lastRun = .started`) and awaits
the model. While that await is pending, the event handler runs. The morning row is either still
yesterday's (more than 8 h old) or `.started`, so neither counts, and the return trigger runs a
second catch-up. If the second run is refused as "local model busy", the trigger's retry path
(`processTrigger`, :1030 `due.append`) runs it later without asking `triggerDecision` again. The
cooldown never applies on that path either.
Fix (about 3 lines in the same function): count `.started`, and count any enabled catch-up whose
`nextRunAt <= now` (due, not yet claimed). Re-check the cooldown on the trigger retry path. The
self-test cannot catch this today because `ScriptedRunner` returns at once, so no run is ever in
flight. Add one case that runs `runOnce` at a due morning slot with a held runner and publishes
the return in between.

**M2. The real-voice case is inside the scripted INTEGRATION suite, where it can download models
and hide failures (must-fix).** `CatchUpSelfTest.run` (:52–58) always runs `realVoiceFailures`
(:956–1023):
- On a Mac without the voices, `PocketAgentVoice.shared.prepare()` → FluidAudio
  `PocketTtsManager.initialize()` → `PocketTtsResourceDownloader.ensureModels` **downloads**
  the model. The packet itself says forcing the absent branch "would mean a model download".
  Kokoro behaves the same way. A self-test must not fetch a model nobody chose.
- When neither voice loads, the run prints `CATCH_UP_VOICE_ABSENT` and then `CATCH_UP_FAILED`.
  `Scripts/acceptance.sh` `classify()` lets the last `*_ABSENT` line beat a missing `*_OK`, so the
  **entire suite is reported SKIP**. Every scripted regression (migration, budget, presence,
  ceiling) is then invisible on any machine without a voice, and the same happens through the
  `--selftest-digest` / `--selftest-podcast` aliases.
- It also does not test the producer fix it accompanies. The test warms Pocket itself (:964,
  with retry) before rendering, so the new unbounded `prepare()` in
  `LongFormSynthesisFactory.pocket` (LongFormRenderer.swift:434), which is meant to fix the cold
  start, is never exercised from cold.

Fix: move the real render behind an explicit modifier (for example
`--selftest-catch-up --real-voice`, or its own flag outside INTEGRATION), refuse up front when the
model files are not already on disk (never call `ensureModels`), and do not pre-warm, so the cold
`prepare()` path is what gets measured. The evidence already gathered (`CATCH_UP_REAL_RENDER:
engine=pocket … audio=19.76s peak=0.708`) is valid and should be kept as the first real render.
It has not been listened to.

**M3. The detached render competes with the live voice that is speaking the same text (must-fix,
small).** Text first is right, but with `.notifyAndSpeak` and a person present, `makeDelivery`
(:830) speaks the full catch-up through `OutputScheduler.speakSessionless` while
`CatchUpTemplate.detached` (:252/:277) starts the file render immediately. That render uses the
same `PocketAgentVoice.shared` manager. `LiveLongFormEnvironment` (LongFormRenderer.swift:370–386)
yields to meetings, dictation, the ASR lane, the notes lane and cleanup, but not to live agent
speech or a voice conversation. The podcast never overlapped because it rendered before
delivery. This is a full-duplex/latency regression under the owner's bar. Fix: add the existing
"agent is speaking / voice turn active" signal to the renderer's yield predicate (one property on
the existing environment), or skip the render when the delivery itself is spoken.

Should-fix / notes:
- **The cooldown only works one way.** A return at 05:30 is followed by the 06:00 morning
  catch-up anyway. Apply the same `recentCatchUp` check to a catch-up routine slot (record it as
  skipped, as the trigger does).
- **No return is detected after a relaunch or reboot.** `AbsenceDetector.lastPresentAt` is in
  memory only, so a person who shuts down for the weekend gets no "While you were out" on Monday.
  The packet records this. It should go in STATUS as a known gap, not a silent one.
- **Quiet hours drop returns.** A return more than 45 min before quiet hours end is dropped
  (`holdWindow`), even though delivery already holds results through quiet hours. Holding the
  event is what the spec asks for, so this is a product note only.
- **The detached render has no owner at quit.** `CatchUpTemplate.detached` is unstructured, and
  `PocketAgentVoice.finishTermination` joins warm-up, not caller synthesis streams. Quitting
  mid-render is the PID41058 crash class (native work outliving AppKit teardown). The podcast had
  the same gap inside the run, but the detached task makes it more likely. Tell the owner of the
  quit-safety work in AGENT-OVERHAUL. No new owner should be added in this packet.
- **Downgrade hazard.** `ScheduleStore.load()` decodes the whole array or returns `[]`. An older
  binary that reads a file containing `{"returned":{}}` sees no schedules, and its next save
  writes an empty list. The same was true of every earlier trigger case, but the risk window is
  real while staged Codex bundles built from older bases exist on this Mac. Hold installs of
  older bases after PL-11 lands, or note it.
- `ScheduleStore.loadMigrated` writes on `init` and on every `reload()` until a write succeeds.
  That is acceptable: it is idempotent, never writes an unreadable file, and the 30 s pass bounds
  the retries.

Migration and decoding are otherwise sound. `templateID` is optional (synthesized `Codable` uses
`decodeIfPresent`). Legacy titles are matched by identity first and title second. Ids, rules and
`createdAt` are preserved. A second enabled legacy routine is paused, not deleted. Edited prompts
are kept. Retired budgets are replaced only when they hold the template's own values.

### Over-engineering and size (product ≈ +470 net lines, test 1,082)

| Cut | Lines saved |
|---|---|
| `NextNotesApp.swift:1211–1233`: three identical branches → one `if contains(catch-up) \|\| contains(digest) \|\| contains(podcast)` | ~14 |
| `CatchUpTemplate.libraryKey(title:edition:)` (:101–104) has no caller | 4 |
| `AbsenceDetector: Equatable` + hand-written `==` (AgentTriggerEvents.swift:223–235): nothing compares detectors | 6 |
| Shape checker plus "nine bad controls" plus two of the three persona texts (CatchUpSelfTest.swift ~:73–116, :353–431). These grade hand-written fixture prose that a scripted model returns verbatim, so they test the test, not the product. Keep one persona run through the real `ScheduledRunner` | ~110 |
| `restatement()` / `createArguments()` have no production caller (the spec accepts this; P4-06 owns the offer). Keep them, but the AGENTS rule "a finished feature with no call site" applies until P4-06 wires them | — |

### Spec and owner-rule fit
- Met: one template replaces both; identity, not title, decides budget, transform and answer rule;
  moment titles; reads-only ceiling unchanged (`get_agenda`, `search_knowledge`, `search_email`)
  with a write refused (tested); no web reads; text first; one voice; no new store, scheduler,
  queue, timer or audio path (`AbsenceDetector` is sampled on the existing pass and published
  through `AgentTriggerEvents`); one task ledger (artifact folded into the same task).
- The `ScheduledRunner` answer rule now switches on `isCatchUp`. That is the producer-level fix
  for the contradiction with the three-sentence cap, and it is correct.
- Open, and honestly recorded by the packet: the closing offer is not a pending offer (P1-02/P4-06);
  "catch me up" in a live conversation is not wired to the voice output path (only
  `schedule.run_now` works); per-person section order (PL-08 answer) is not used; the real render
  has not been listened to.
- Stale AGENTS.md text that the packet must update: line 1024–1026 ("`--selftest-digest` and
  `--selftest-podcast` pin the two scheduled content routines …") and the "What has never run"
  bullet at 2743–2746 ("The podcast routine with real voices … neither voice model is
  downloaded"). That bullet is now false: models are present and one real render was produced.

### Self-test honesty
- Good: a red run on the old code (budget, two hosts, 600–900 words, `{"returned":{}}` not
  decoding, moment title not rendered); a mutation of `observePresence` turns 11 checks red;
  triggers run through the real `AgentScheduler.runOnce` / `handleTriggerEvents`; runs go through
  the real `ScheduledRunner`; the artifact is linked through the real
  `AgentTaskManager.foldArtifacts`; migration goes through the real `ScheduleStore`.
- Gaps: M1's overlap is not covered; M2's cold-start producer fix is not covered; the persona and
  shape section grades fixtures.

---

## PL-08/09: first run and Google without Terminal

### Correctness

**G1. When the app's own sign-in is in use, a failed token refresh silently switches to another
Google account (must-fix).** In `GoogleWorkspaceCLI.run` (GoogleWorkspaceCLI.swift:466–480), any
error from `GoogleAccessTokens.workspaceToken()` other than `accessRevoked` is swallowed ("the
tool tries its own credentials"). If the person also has a Homebrew or older `gws` signed in as a
different account, a transient 5xx or a timeout on the refresh runs the call, **including an
approved `send_email`**, as that other account. Fail closed: when the app sign-in covers
Workspace and no token can be minted, throw an error whose outcome is known (nothing was
launched). `.notAuthenticated`, or `.launchFailed` with plain words, is enough. Add the case to
`runnerCases`.

**G2. A connected app sign-in can run an unpinned `gws` (must-fix).** `authState()` (:303–312)
returns `.signedIn` whenever `binaryURL()` finds any binary, and `binaryURL()` falls back to the
Homebrew/npm/login-shell candidates (:241–246). For a person with an older `gws`:
`GoogleConnection.derive` says `.connected`; `prepareTool()` only runs on `.gettingReady`, so the
pinned tool is never fetched; and an old binary that predates `GOOGLE_WORKSPACE_CLI_TOKEN` ignores
the token and uses its own login, which leads back to G1's wrong-account case. Fix: when the app
sign-in is in use, require `ManagedWorkspaceTool.executable()` for both the auth state and the
spawn. The fallback list stays for the advanced route only.

Should-fix / notes:
- **Every HTTP 400 counts as "revoked" and deletes the key.** In GoogleAccessTokens.swift:44, any
  400 from the token endpoint (`invalid_client`, `unauthorized_client`, a misregistered or rotated
  shipped client) runs `GoogleTokenStore.clear()`. The rule existed before, but it now governs
  every user of a shipped client: one bad client config would sign everyone out. Match `error ==
  "invalid_grant"` (the reason is already parsed into `tokenRequestFailed`).
- **The token cache does not merge concurrent refreshes.** `GoogleAccessTokens.token` is an actor
  method that awaits the network, so with reentrancy two concurrent callers refresh twice. The
  doc says "one round trip, not two", and the test only checks sequential calls. Keep the
  in-flight `Task` (about 5 lines) or reword the doc.
- **Test hooks on the shared token actor are unguarded.** `useEndpoints` / `useClient`
  (GoogleAccessTokens.swift:12–19) mutate the shared production actor with no `SelfTest` guard,
  unlike `appAccountFixture`. Guard them.
- **`ManagedWorkspaceTool.run` has no timeout** (:147–160, for `tar` and `gws --version`). A hung
  binary leaves "Getting ready…" up forever. Use the existing `withBoundedWait`.
- **The pinned digests, sizes and archive layout were never checked against the real release**
  (no download was made; the self-test uses a fixture tarball). The design fails closed, so a
  wrong digest means Google never connects. One attended fetch must confirm these before the
  client id is registered.
- **Regression for existing calendar-only users who brought their own client.** The Calendar tab
  now shows only `GoogleConnectCard`. A calendar-only token (no recorded scopes) derives to
  `.needsMoreAccess`: a warning chip saying "Needs a little more access" on a calendar that works.
  "Disconnect" exists only in `.connected`, so the old Disconnect button is gone, and "Connect"
  now asks their own client for restricted Gmail scopes. Offer Disconnect whenever a token
  exists, and do not warn on the Calendar tab when `coversCalendar` is true.
- **After a failed fetch, every app activation retries the download** (`prepareTool` via
  `didBecomeActive` → `refresh` → `.gettingReady`). This is bounded, but it is a loop while
  offline. Consider keeping `.failed` until the person presses the button.
- Token handling is otherwise correct. The access token goes only into the child's environment
  (`spawn` merges it into `childEnvironment()`), and only the first two arguments are logged. The
  consent URL carries no secret (tested). Revoke sends the refresh token in a POST body. Nothing
  is added to `usage.jsonl`. The client secret in Info.plist is public by design. A self-test uses
  a per-pid Keychain service. A crashed run would leave a stray item in the login Keychain;
  accept or note.
- Checksum: the archive is verified by SHA-256 and size through the existing
  `ModelDownloader.download`. A mismatch removes the archive and throws `.damaged`, and nothing
  runnable is left (tested). The extracted binary must answer `--version` with the pinned version
  before it is moved into place. This is good.

### Over-engineering and size (product ≈ +1,050, test 690 + 15 in onboarding)

| Cut | Lines saved |
|---|---|
| `GoogleConnectRoute.swift` (`WorkspaceStep` + `WorkspaceRoute`) is a second state machine beside `GoogleConnection.State/derive`. `defaultStep` has three outcomes that `derive` already gives, and only `PermissionsChecklist` uses it; `advancedStep` renames `WorkspaceAuthState` cases. Have the checklist read `GoogleConnection.state` and switch on `authState` inline in the advanced section | ~45 + ~20 test |
| `GoogleConnectSelfTest.sourceCases` (:237–255) greps source files through `#filePath`, which is fragile (depends on the repo path at build time) and weak (a string match on `WorkspaceInstaller`). `UIStringsLint.defaultPathProblems` already covers the copy | ~20 |
| Info.plist check reads `Resources/Info.plist` from source (:156–168). Read `Bundle.main` (the shipped value) or drop it | ~10 |
| `OnboardingSelfTest` additive block duplicates checks the packet says `--selftest-google-connect` already makes. Keep one copy | ~15 |
| `OnboardingBrainCopy.swift` is a 28-line file for one footnote. Optional: make it a static function on the step | ~15 |

### Spec and owner-rule fit
- Met: one client seam (`GoogleAppClient`); one token store (Keychain, plus a shared in-memory
  access-token cache that **replaces** the Calendar provider's private one); one Workspace runner;
  the approval rule is unchanged and a revoked grant is an outcome-known refusal; the advanced
  route is opt-in behind a disclosure; there is no Terminal on the default path; fails closed with
  plain words while the client is the placeholder; `WeekFocus` lives in the existing `Settings`,
  is asked once, adds no new step, and offers a starter example only for something that works now.
- **Scope breadth (owner decision, flag it).** `GoogleScopes.connect` asks for seven scopes,
  including `documents` (read/write of all Google Docs), `calendar.events` (write) and
  `drive.metadata.readonly` (restricted). The persona jobs in the spec are mail and calendar. The
  rule "never widen scopes beyond what a persona job uses" suggests the default sign-in should be
  `required` + `calendarList`, with Drive and Docs requested incrementally when a person first
  uses them. Either way, CASA is needed because of the Gmail scopes.
- Open, and recorded honestly: PL-08 item 2 is blocked on PL-03; items 1 and 5 (string audit
  report, timing on the floor machine), fresh-profile runs, outside-person sessions, a real consent
  page, Google verification, and Gatekeeper behaviour of a downloaded unsigned binary.
  `--selftest-onboarding` could not run from an unpackaged build and must be run from the
  installed bundle.

### Self-test honesty
- The real `GoogleOAuthClient.signIn` runs against a loopback fixture (PKCE, state forgery,
  decline, scopes, Keychain, revoke). The real runner `run()` is exercised through
  `appAccountFixture`. The real `ManagedWorkspaceTool.install` runs against a fixture release
  (checksum, offline, idempotence). These are good production-path checks.
- The RED is partly synthetic. The nine red rows came from `WorkspaceRoute`, a new function
  written to reproduce the old view logic, plus the footnote. The producers that matter most
  (token handoff, fail-closed revoke, scope gating) have no before/after, because their APIs are
  new. That is acceptable, but say so. G1 and G2 have no cases.
- Not exercised: the `.live` dependencies of `GoogleConnection` (`afterConnect`, `disconnect` →
  revoke → refresh), and the wiring of the card, checklist and onboarding row.

---

## Integration risks (both packets)

- **Shared files.** `NextNotesApp.swift` and `AGENTS.md` on main have already drifted from
  `b62e76d`. Codex added the task-repeated-read branches and rewrote several AGENTS paragraphs.
  The hunks do not overlap, but they must be applied by hand. Both packets edit adjacent branches
  (catch-up at :1211, google-connect at :1241), so apply them in one edit.
  `Scripts/acceptance.sh` is unchanged on main: PL-11 replaces two INTEGRATION rows with one;
  PL-09 adds one EXPERIMENTAL row (its `.md` says INTEGRATION, but the patch and `selftest-gws`
  are EXPERIMENTAL, which is consistent).
- **Codex areas.**
  - PL-11 writes an artifact onto an already-terminal task through
    `AgentTaskManager.foldArtifacts` → `update` (allowed today when the status does not change).
    That is the P6-02b artifact/SQL-authority area. A future admission rule for terminal rows
    would silently drop the link (`foldArtifacts` ignores the persistence result). Tell Codex.
  - PL-11 changes `ScheduledRunner`'s task objective and answer rule (routine-authority area;
    `--selftest-routine-authority` passed).
  - PL-09 touches `GoogleWorkspaceCLI.run` (receipts / outcome-unknown area, and the P6-02b-2 mail
    sources pass through it). The new early throw is outcome-known, which is correct.
  - `VoiceCapabilitySnapshot` has a one-line change in the voice area.
  - The ACP, voice-session and receipt code are untouched.
- **Merge mechanics.** `b62e76d` is a snapshot commit, not for merge. Apply the patches to current
  main; do not merge the branch.
- **Cleanup.** The packets report three concurrent `make build` runs in the shared scratch, killed
  duplicates, and free disk falling to 1.3 GB. After integration, the `positioning` worktree and
  the `claude-scratch` build cache should be reviewed for removal under AGENTS "Reuse, integrate
  and clean up".

## Must-fix list

PL-11:
1. Close the duplicate-delivery race: `recentCatchUp` must count `.started` and due-but-unclaimed
   catch-ups, and the trigger retry path must re-check the cooldown. Add a held-runner case.
2. Move the real-voice render out of the scripted suite into an opt-in modifier. It must never
   download (refuse when the files are absent), must not hide scripted failures as SKIP, and must
   not pre-warm, so the cold `prepare()` fix is what gets tested.
3. Make the long-form render yield to live agent speech or a voice turn (existing environment
   seam), or skip it when the delivery is spoken.
   Also update the stale AGENTS.md lines 1024–1026 and 2743–2746, and collapse the three
   `NextNotesApp` branches.

PL-08/09:
1. Fail closed in `GoogleWorkspaceCLI.run` when the app sign-in is active and no token can be
   minted. Never fall through to the tool's own credentials.
2. With the app sign-in, require the pinned managed `gws` for both `authState` and spawn.
   Before the client id is registered: treat only `invalid_grant` as revoked, add a timeout to
   `ManagedWorkspaceTool.run`, guard the token-actor test hooks, confirm the pinned digests with
   one real fetch, and keep Disconnect for calendar-only tokens.
