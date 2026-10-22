# First run with no technical question (PL-08, PL-09)

The four people in `00-README.md` will not open Terminal, paste a client secret or choose a
model. If the first ten minutes ask them to, nothing else in this folder matters. These tasks
coordinate with MODULES-ACTIVATION MOD-08, SHARED-BRAIN SB-05, WEBSITE-TO-MAC-EXPERIENCE UX-09
and AGENT-OVERHAUL X09; they supply the persona and floor requirements and do not duplicate
those tasks' implementation.

---

## PL-08 — Onboarding that never asks a technical question

**Goal.** From install to a first useful result for any of the four people with no model,
key, account, file format or terminal on screen, on the floor machine, while the model is
still downloading.

**Current state (verified 2026-10-04).**
- `Sources/NextNotes/UI/Onboarding/OnboardingFlow.swift`: seven steps — welcome, dictation
  (permissions), shortcut, meetings, files, brain ("Assistant"), all set.
- `OnboardingSteps.swift` already states the copy rule at the top: no product of a technology
  is ever named, no model names, no file formats, no "API". `OnboardingBrainStep` downloads
  `NotesModels.spec` (Gemma 4 E4B, 4.98 GB) and Parakeet when dictation will use it, and only
  promises a download the downloader will accept (artifact + 4 GiB reserve).
- `OnboardingModelResume.swift` takes over an interrupted download.
- Gates: `--selftest-onboarding`, `--selftest-guided` (calendar → names → proposal →
  approval → executed → follow-up), `--selftest-ui-strings`, `PersonaCareEval`.

**Work.**
1. Audit every onboarding and first-run string against the four people: would a parent, an
   office manager, a legal operations manager and an editor understand it read aloud? Record
   failures in a report; fix copy at its producer, not with a filter.
2. Replace the model download's place in the flow with PL-03's silent default: one progress
   state, Apple answering in the meantime, no size or name on screen, and a plain sentence when
   disk is short (what to free, not which file).
3. First success per person, using only what works without an account: a dictation into the
   app they use; a meeting armed or recorded; for the editor and legal operations manager, a
   file found by the indexed folders step. Calendar and mail examples appear only once Google
   is connected (PL-09) and only for capabilities that pass their gates.
4. Optional, one tap, skippable: "What do you spend most of your week on?" with the four jobs
   in plain words. It only chooses starter examples and proactive defaults (PL-06); it is
   stored in the existing `Settings`, never a new store, and never asked again.
5. Measure time to first useful result from first launch on the floor machine, including a
   fresh download, and record it in the report.

**Acceptance evidence.** Fresh-profile runs on the floor machine for grant accepted, grant
denied, granted later, offline, low disk and no meeting yet — each ends at a useful action or
one clear next click. `--selftest-onboarding`, `--selftest-guided`, `--selftest-ui-strings`
pass. Three people outside the repo (X11's usability rule), one per at least three personas,
finish a first success without help; their sessions are recorded as content-free notes.

**Must not.** Add an onboarding step that delays the first success; show a model, size picker,
API key, OAuth field or Terminal instruction on the default path; download something for a
module the person turned off; name a technology in copy.

## PL-09 — Connect Google without Terminal

**Goal.** One "Connect Google" button, the person's browser shows Google's own consent screen,
and mail and calendar work. No Homebrew, no Terminal window, no Cloud project, no client id or
secret to paste.

**Why it matters.** Every one of the four people lives in mail and calendar. Today the path to
them is the most technical part of the app, and the closest rival advertises Google's approval
for exactly these scopes.

**Current state (verified 2026-10-04).**
- `Sources/NextNotes/Agent/WorkspaceInstaller.swift`: installing `gws`, authorising a Google
  Cloud project and signing in "all happen in Terminal", reached by writing a `.command` file
  into `Application Support/Next Notes/Scripts/` and opening it.
- `Sources/NextNotes/UI/Settings/CalendarSettingsTab.swift` asks for the person's own OAuth
  client id and a "Client secret" (`GOCSPX-…`); `AGENTS.md` records that Google's installed-app
  client type needs the secret at the token endpoint even with PKCE. The OAuth plumbing itself
  (`GoogleOAuthClient`, loopback + PKCE; `GoogleTokenStore`, Keychain) already exists; what is
  missing is a client the app owns, so the person is asked to bring their own.
- `gws auth status` exits 0 when nobody is signed in; auth state is read from its JSON fields
  (`GoogleWorkspaceCLI.authState`). `--selftest-gws` has a fixture half that needs no account.
- Workspace tools: `workspace.search_email`, `read_email`, `draft_email`, `reply_email`,
  `send_email`, `get_agenda`, `create_event`, `find_drive_files`, `upload_to_drive`,
  `create_doc`, `read_doc`, `append_doc`. No write has ever been approved live.

**Work.**
1. **Owner decisions first (cannot be done by an agent):** register a project-owned Google
   OAuth client for this app and take it through Google's verification for the scopes the
   personas need. Gmail scopes are in Google's restricted tier, which requires a security
   assessment; record the decision, cost and timeline in STATUS before engineering starts.
2. Replace the Homebrew/Terminal install with a pinned, checksum-verified `gws` shipped or
   fetched by the app itself (check its licence against `AGENTS.md`'s rules and add it to
   `THIRD-PARTY-NOTICES.md`), or call the same Google APIs through the existing calendar path —
   whichever keeps one Workspace runner. Do not add a second Google client.
3. Sign-in reuses the calendar side's existing flow — `Sources/NextNotes/Calendar/Google/GoogleOAuthClient.swift`
   (Desktop client type, loopback redirect, PKCE S256) and `GoogleTokenStore` (refresh token in
   the login Keychain) — with the app's own client prefilled, so the person only sees Google's
   consent page in their browser. Mail and calendar share one sign-in, not two. Nothing to paste.
4. Keep the advanced route (own client, own `gws`) as an opt-in for people who want it, never
   first.
5. Keep the permission model unchanged: reads run, every send/create waits for approval, an
   unanswered write is "not sure" (`WorkspaceCLIError.outcomeIsKnown`).

**Acceptance evidence.** A fresh profile on the floor machine connects Google with no Terminal
window and no text field; the auth state reads signed-in from JSON, not an exit code; revoking
access in the Google account is noticed and offers one reconnect button; `--selftest-gws`
(fixture half) and `--selftest-ui-strings` pass; one attended run per persona reaches a real
mail or calendar answer. The first live approved write is recorded as its own evidence.

**Must not.** Run `brew` or any shell installer on the person's behalf without showing it; ship a
second Workspace runner or token store; widen scopes beyond what a persona job uses; let a
connected account change the approval rule; claim "Google approved" anywhere before Google
says so.
