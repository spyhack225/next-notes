# Main release — 22 October 2026

Owner authorizes commit, push, live website deployment and installation of the latest integrated main, with settings, recordings and history preserved. This record is in progress; no installation or deployment is accepted until the receipts below exist.

## Preservation and publication

The public origin was 503 commits behind the integrated main at entry. Its unpublished merged ancestry contains original recovery `.worktree-preservation` archives, command/session logs, and a test API credential captured in process diagnostics. Original history remains private and recoverable under local `refs/archive/private-worktree-history-20261022`; it must not be pushed. A separate bare repository filters only unpublished ancestry: remove `.worktree-preservation/` and `codex-run*.log`, replace the exact captured credential in text, retain the existing published boundary and application tree. The public push remains a fast-forward. Original evidence/source pins are historical IDs retained by the private archive; rewritten public commits have new IDs.

Private backup: `~/Library/Application Support/NextNotesReleaseBackups/2026-10-22-main`. An APFS copy-on-write clone contains all 1,185 support files (13,228,682,144 logical bytes); every original and cloned file has matching SHA-256. All 89 preference keys are exported privately. Only aggregate witnesses enter this report; file names, settings values and owner payloads stay outside the repository. Copy-on-write logical bytes are not exclusive disk consumption.

## Installer producer repair

The original installer unconditionally used `pkill -x NextNotes` and swept unrelated stage bundles. It could stop an unrelated checkout's self-test and delete another owner's rollback. The real installer now identifies only an installed executable via `proc_pidpath` and refuses replacement while it runs, preserves all other processes/artifacts, validates the complete candidate signature before replacing anything, and retains the previous installed app under `NextNotesBuild/rollback/`. The release caller must close the installed app gracefully before installation.

[Regression](check-installer.py) redirects only `/Applications` into a disposable directory; it uses real signed Mach-O bundles and intercepts the old `pkill` rather than executing it. Original fails preservation; fixed passes. Separate invalid-signature and actual active-process cases refuse installation with the old app intact. [Results](installer-check.json). No owner app/data is used by this fixture.

## Obsolete compiler cleanup

Both active owners acknowledged the exact scope. Old cache metadata points to the removed dictation-perf and voice-ack worktrees; no process had files open in either root. Seven named compiler-intermediate folders were retired, preserving all Products, executables, dependency artifacts/checkouts, the current shared native cache and owner data. [Receipt](obsolete-cache-cleanup.json): 2,868,121,600 allocated bytes unlinked; observed free space 5,713,080,320 → 8,594,358,272 bytes. Native and retained old executable hashes are unchanged. The ASR agent separately retired 2,297,290,752 allocated bytes of unused SwiftBuild intermediates under the shared scratch's separate `out/` tree. These are scoped removals, not unique APFS physical attribution.

## Pending receipts

Combined source freeze, optimized build, candidate native checks, unchanged owner witness, installed signature/binary receipt, public history scan and live website asset verification remain pending.
