# Integration manifest (claude-positioning, 2026-10-08, updated as branches clear review)
Base for all branches: main c6d850c (main HEAD has since moved to 55d402ee; commits are cherry-pick friendly).
Rule: nothing below is merged. The owner of the canonical working tree integrates after its own uncommitted work is committed.
The shared prerequisite commit (AgentTaskStore.recoveredReadHistory, 20d8f9b8 / aae0a5c6 / 7de63841 / 57c51f69: all copies of the same 10 lines) must be SKIPPED: the canonical uncommitted AgentTaskStore.swift already has the real one.

## READY (independently reviewed APPROVE)
### claude2/thinking-review: stream leak fix
- Cherry-pick, in order: 8e4243d6 (hide marked reasoning and split controls at the stream producer), 0be933e6 (flush visible marker prefixes at stream EOF). Evidence/reports: c7463dba, 98700836, 6d2c66aa (docs/Tests/Reports only).
- Source files: Formatting/LLM/ChatTemplate.swift, ChatTemplateSelfTest.swift, NotesModelRuntime.swift.
- Conflict check vs canonical uncommitted edits: only NotesModelRuntime.swift is dirty there; branch hunks old-lines 1166-1254, canonical hunks 1003-1134 and 1267+, so no textual overlap expected; re-run the chat-template flag after merge.
- Proof: frozen V2 fixture bbd42ce7: original 8e4243d6 fails 201/658, fixed 658/0; CHAT_TEMPLATE_OK, NOTES_TRUNCATION_OK, LLM_PREFIX_CACHE_OK (646/666, 2.00 s to 0.37 s), STORE_ISOLATION_OK 21 files / 0 defaults. Review: wt/review-leak/REVIEW.md (round 2 APPROVE).
- Known limit: a multi-byte character split across two native tokens is decoded per token upstream (LlamaHelpers.piece), not covered.

## IN REVIEW / IN FIX
- claude2/google-c (Google Option C): reviewer REJECT (6 findings), author fixing; re-review needed.
- claude2/catchup-ui2 + claude2/catchup-audio (Catch-up screens + audio guard / yes-context): reviewer APPROVE WITH FIXES; fixes in progress; second review needed after both land. Island hunks conflict with canonical IslandState.swift (one line) per review-ui.
- claude2/listen2 (PL-13 voice): route-only experiment committed (0c0354d5, small gain, gates not met); resident prefill in progress.
## NOT STARTED / BLOCKED
- bakeoff2: waiting for meeting-performance's go.
- tooling: heavy.sh fair queue is already live (dae49e1d candidate installed in wt/).

## UPDATE 2026-10-09 (orchestrator)
- google-c: round 5 (structural grant-identity fence for the calendar list) in progress after 4 review rounds. Do not integrate before the final APPROVE.
- no-apple (Apple TTS removal, head 3b1f1038 + round 3 fixes in progress): conflicts to reconcile by hand: AgentTaskManager.swift, AgentTaskStore.swift (shared prerequisite 9a63761b == canonical copy: insert once), ModelResidencyPolicy.swift (keep BOTH the cold-seed/notification and the dictation cleanup warm), NextNotesApp.swift (launch order), AgentView.swift, IslandView.swift.
- voice-ack and voice-mini branches still use `appleSynthesisCallsForTesting` (AgentSpeechSynthesizer.swift:99, VoiceAcknowledgementSelfTest.swift:22,137, VoiceDiagnosticSpeech): replace with the neutral `speechSynthesisCallsForTesting` (counts allowed-engine request entries only; clip prewarm legitimately counts 2) at integration. voice-mini is PARKED (resident Mini 0/5 qualified vs Apple 1/5): integrate only its no-cold-load fallback commits (82591312 RED, e8c2f0e2 repair), not an answerer switch.
- voice-settings-ui (Sonnet) must replace the legacy voice section: committed head d52ebaca still had the Apple tile; its newer work addresses review finding 3.

## READY #2 (2026-10-09): claude2/google-c, Google Option C backend (reviewed APPROVE on round 5)
- 20 commits on top of c6d850c; head 7ac342ce. Code commits to take (in order): 713cbe8c (Makefile client injection into the BUILT bundle only; private JSON never in repo),
  00ae3b03, c86ecf40, 3b20f943 (tests), db8b8fac, d26a96c3, 35a0414d, e2ea9f4d, 10d6663f, 1c72fe09, c32bcc99, 27c24e23, 8a3aec0f, 08ffb2ec, 6e490cec, 14382546.
  Evidence-only commits (docs/Tests/Reports; take or skip): ddf30b7b, 59b8bbba, 7ac342ce. SKIP 7de63841 (copy of canonical AgentTaskStore.recoveredReadHistory).
- Source: Calendar/Google/* (GoogleScopes nine-scope list in GoogleAppClient.swift, token store/refresh/grant fence, provider, connection controller, managed gws, many self-tests),
  Agent/GoogleWorkspaceCLI.swift, Agent/AgentCapabilityManifest.swift, Agent/Mac/MacWorkspace.swift, Calendar/CalendarService.swift, NextNotesApp.swift (self-test registration), Makefile, Resources/Info.plist, Tests/GoogleOptionCChecks.sh.
- Overlap with canonical UNCOMMITTED edits (merge by hand): Makefile, Agent/GoogleWorkspaceCLI.swift, Agent/Tasks/AgentTaskStore.swift (skip: already there), Calendar/CalendarService.swift, Calendar/Google/GoogleTokenStore.swift, NextNotesApp.swift.
- Proof: native RED then GREEN on the same fixtures: round-5 402/402 GOOGLE_CONNECT_OK (9 failing on 6e490cec), earlier V3 340 and V2 318; seven requested root flags exit 0; mutations (any 400 = revoked / unpinned gws / no Google-only mailbox filter) fail 7/1/7 then restored; secret greps clean (no real client id or GOCSPX; private JSON never read).
- Known open: nested TOOLLOOP_PRODUCTION_FAILED/18 is the StoreIsolation test-wiring defect, not Google. Default Settings/onboarding still call the old Terminal installer/login UI (this is backend only): a Settings card for Google (Option A first, "Other ways" below) is NOT built yet. Google verification: restricted scopes (gmail.modify, drive) need Google's review and a security assessment only if restricted data goes through a third-party server; five of the nine scopes have no tools yet (verification justification); Testing-mode sign-ins expire after 7 days.

## READY #3 (2026-10-09): claude2/no-apple, Apple built-in voice removed app-wide (head 19a212a8)
- 39 commits on top of main 55d402ee (git log 55d402ee..19a212a8). Take the range as a whole (cherry-pick in order, or merge the branch); it contains the shared prerequisite 9a63761b (AgentTaskStore.recoveredReadHistory): insert ONCE, canonical already has it uncommitted.
- Rule: only Pocket and Kokoro speak. Failed or not-ready voice = text only with one plain line, never another voice. A fresh Mac downloads Pocket in the background at first launch (existing preparation owner, resource-admitted). Approvals: an unheard spoken approval never arms a spoken yes.
- Reviews: wt/review-noapple/REVIEW-1..4.md. Round 4 (REVIEW-4): APPROVE WITH FIXES, the reply-failure producer fix f6265ca2 is accepted (RED 36 -> 0); the census gaps it found were fixed in round 5 (e728d84e, 19a212a8: census RED 27/63 -> 0/63, Sources unchanged, NOT re-reviewed).
- Overlap with canonical UNCOMMITTED edits (merge by hand): AgentTaskManager.swift (keep Catch-up audio-absence progress AND typed/recovered worker changes), AgentTaskStore.swift (already there), Core/Compute/ModelResidencyPolicy.swift (keep BOTH the new admission notification + unknown-pressure re-observation AND canonical cleanup warm recovery), NextNotesApp.swift (keep startup order; add voice preparation + policy diagnostic), AgentView.swift (voice notice stays with the written message), IslandView.swift (reply availability line).
- Proof: native flags 18/19 exit 0 in the last slot; Settings prints SETTINGS_OK then exits -11 (inherited, unassigned, also on catchup-final and voice-settings-ui); inherited delivery13 / duplex2 / nested browser18 unchanged. Final source census forbidden 0, exceptions 30 (a tripwire, not an obfuscation proof).
- Not verified: real Pocket/Kokoro audio quality, real first-launch download/offline UI, post-resume playback, release performance, combined build with the other branches.
- Order: land no-apple FIRST. The next three build on it: voice-settings-ui (head 514fcfc7, based on no-apple 8097108a; Sources identical to 19a212a8 so no re-rebase), voice-ack (baf56231, must swap appleSynthesisCallsForTesting for the neutral speechSynthesisCallsForTesting), catchup-final (233b5dd8; round 2 pending; Catch-up spoken output depends on no-apple).

## STATUS 2026-10-09 (orchestrator): not ready yet
- claude2/voice-settings-ui: 514fcfc7, Retry wired to the recovery owner, 16/18 self-tests + 11 previews; Sonnet UI review of the previews running.
- claude2/voice-ack: baf56231, ack median 120 ms / p95 129 ms (n=5, file-fed, ack START only); independent review running.
- claude2/catchup-final: 233b5dd8 approved with fixes; round 2 (later-live-card priority, font token; saved-file playback documented as NOT accepted for the one-channel rule) running. Owner decision needed on that audio-channel gap.
