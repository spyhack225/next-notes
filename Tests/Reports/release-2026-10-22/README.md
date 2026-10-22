# Main release — 22 October 2026

Owner authorizes commit, push, live website deployment and installation of the latest integrated main, with settings, recordings and history preserved. Installation and public deployment are verified below.

## Preservation and publication

The public origin was 503 commits behind the integrated main at entry. Its unpublished merged ancestry contains original recovery `.worktree-preservation` archives, command/session logs, and a test API credential captured in process diagnostics. Original history remains private and recoverable under local `refs/archive/private-worktree-history-20261022`; it must not be pushed. A separate bare repository filters only unpublished ancestry: remove `.worktree-preservation/` and `codex-run*.log`, replace the exact captured credential in text, retain the existing published boundary and application tree. The public push remains a fast-forward. Original evidence/source pins are historical IDs retained by the private archive; rewritten public commits have new IDs.

Private backup: `~/Library/Application Support/NextNotesReleaseBackups/2026-10-22-main`. An APFS copy-on-write clone contains all 1,185 support files (13,228,682,144 logical bytes); every original and cloned file has matching SHA-256. All 89 preference keys are exported privately. Only aggregate witnesses enter this report; file names, settings values and owner payloads stay outside the repository. Copy-on-write logical bytes are not exclusive disk consumption.

## Installer producer repair

The original installer unconditionally used `pkill -x NextNotes` and swept unrelated stage bundles. It could stop an unrelated checkout's self-test and delete another owner's rollback. The real installer now identifies only an installed executable via `proc_pidpath` and refuses replacement while it runs, preserves all other processes/artifacts, validates the complete candidate signature before replacing anything, and retains the previous installed app under `NextNotesBuild/rollback/`. The release caller must close the installed app gracefully before installation.

[Regression](check-installer.py) redirects only `/Applications` into a disposable directory; it uses real signed Mach-O bundles and intercepts the old `pkill` rather than executing it. Original fails preservation; fixed passes. Separate invalid-signature and actual active-process cases refuse installation with the old app intact. [Results](installer-check.json). No owner app/data is used by this fixture.

## Obsolete compiler cleanup

Both active owners acknowledged the exact scope. Old cache metadata points to the removed dictation-perf and voice-ack worktrees; no process had files open in either root. Seven named compiler-intermediate folders were retired, preserving all Products, executables, dependency artifacts/checkouts, the current shared native cache and owner data. [Receipt](obsolete-cache-cleanup.json): 2,868,121,600 allocated bytes unlinked; observed free space 5,713,080,320 → 8,594,358,272 bytes. Native and retained old executable hashes are unchanged. The ASR agent separately retired 2,297,290,752 allocated bytes of unused SwiftBuild intermediates under the shared scratch's separate `out/` tree. These are scoped removals, not unique APFS physical attribution.

## Release validation

The optimized native build compiled all 900 app sources. Five later app primaries were rebuilt with that exact source context and original compiler arguments; each retained its defined-symbol contract. The signed final candidate is 0.2.24 build 809, executable SHA-256 `bce5ef99b315110ef535122ded59329eb6bec1d7a53d6e573ac9a07f4af95620`. See [package](final-package.json) and primary repair receipts.

SwiftPM's external CLI resource accessors assumed resources next to the executable or in an absolute development cache. The release boundary now recompiles only the generated accessors to use the app resource directory and relinks the same object list. An independent signed real-SwiftPM fixture fails before and passes after with its development resource directory hidden. All SDK source and original SDK objects remain unchanged. Resource copies are staged writable before signing; bundles live under Contents/Resources. [Original/fixed fixture](resource-fixture-results.json).

[Final native checks](candidate-summary.json): 33 of 34 root checks pass, including dictation, usage, speech, TTS producer, task authority/restoration, meeting coverage and playback. The worker-attempt missingSnapshot failure also reproduces on the old installed executable ([baseline](installed-baseline-worker.log)); it remains open. Store-isolation passes while retaining inherited nested tool-loop R02 failures. These results do not resolve aggregate Agent quality, meeting factuality or physical full-duplex acceptance. The eight-model app comparison used a preceding binary with the same ASR production path; its 45 paced holds exclude physical mic/UI/cleanup/insertion and concurrent voice.

The final check run exposed a diagnostic history leak: AgentHarnessRouter isolated only two self-test flags. Its existing persistence switch now covers all diagnostics except the separately checked temporary settings fixture, and SelfTestStoreGuard watches the harness history too. The original 80-row harness file was restored exactly after retaining the diagnostic version privately. A prior peer-owned normal baseline launch refreshed four derived cache/metrics files before candidate tests; both original backup and current derived values are retained. The admission baseline reconciles those four derived files only. All original 89 preference values are unchanged; the authorized ASR comparison added two SDK device/license cache keys, retained for the working model. Final comparisons cover all 1,185 files and all 91 current preference values without an ignore list.

Public history also removes host process titles/arguments from report inventories, while retaining numeric timing/resource facts. Exact original recovery history remains in private archive refs and an offline bundle. Public snapshot mappings track sanitized recoverable code commits.

## Deployment receipts

[Installed build](installed.json) is 0.2.24 build809 at `/Applications/Next Notes.app`, with the exact tested binary and strict signature. [Post-install witness](owner-after-install.json) passes for all1,185 support files and91 preferences. Previous app retained under `NextNotesBuild/rollback/20261022-154959-78463/`. Normal startup retains all62 taskIDs; visual native UI inspection is unverified because Computer Use capture failed. Only this release-owned idle verification process was stopped before the TTS handoff; unrelated process99601 was preserved.

[GitHub release v0.2.24](https://github.com/spyhack225/next-notes/releases/tag/v0.2.24) publishes the exact tested package. Both DMG assets have SHA-256 `1f0eae718c86f9df8dcf478740089a8c6a93f598eae4a4c005dda0e09cdae0d0`. The automatic tag rebuild was cancelled to preserve these locally tested assets. This is a locally signed development build, without Apple notarization.

[Live benchmark site](https://next-notes.com/?page=benchmarks) serves `assets/index-CMUF80hd.js` byte-identically to the committed build; DigitalOcean deployment `7eb9c670-ccab-49d9-ab7a-4b31e46bf665` is ACTIVE from main `3d154470`. Browser verification confirms51 reviewed public rows, eight English model rows, separate accuracy/latency conditions and retained open gates. [Asset receipt](live-site.json) and [screenshot](live-benchmarks.png).

Catalog CI initially caught one newly indexed cleanup receipt omitted by generation before staging. After staging receipts and regenerating, GitHub run39844182049 passes in a clean Linux checkout. Local catalog/privacy regressions pass20 tests; website build/lint pass. Remote macOS dictionary CI is queued at handoff; focused native evidence above is completed locally. No broader acceptance is inferred.

The current matching dSYM is retained; an obsolete nonmatching424,103,936-byte dSYM was removed after UUID/open-file checks. Original recovery refs and private bundles, current SDK cache, owner data, installed app and rollback are retained. Physical TTS work owns its new uncommitted evidence and is deliberately left untouched.
