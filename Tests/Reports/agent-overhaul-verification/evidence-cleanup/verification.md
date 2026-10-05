# Evidence and staged-app cleanup

The closure archive now lives at `~/Library/Caches/NextNotesBuild/evidence/agent-overhaul-closure`. The same-volume move preserved all 35,442 entries, 1,105,281,007 regular-file bytes, file hashes, modes and symlink targets. The full relocation record is in the sibling `closure-relocation.json`.

Obsolete root-owned staged apps 410, 440 and 441 were removed after checking process/open-file references. App 442, the running app, foreign build caches and model files were preserved. No abandoned native/startup temporary directories remained in the checked roots; no 43 GB reclamation is claimed. Available space after cleanup was 12.6 GiB.

Short per-commit verification notes remain in `Tests/Reports/agent-overhaul-verification`. Historical raw evidence is local cache data, not a product acceptance claim.
