# Native trial quit fixture integration

Adds the omitted actual trial caller fixture used by the committed native quit test. Restores its existing confined hardware and preferences bindings in ModelLibraryStore. Normal nil/default calls retain their existing behavior.

Historical paired builds151/152 exercised the same 40 checks: four failures before the producer repair, zero afterward. The fixture and constructor bindings were present in both tested compiler inputs but omitted from the earlier integration selection. This commit repairs that selection; it introduces no new runtime repair. Combined compile/install remains pending the 8 GiB swap gate.

Raw evidence: `~/Library/Caches/NextNotesBuild/evidence/agent-overhaul-closure/native-termination-crash-review/2026-10-02-pid41058/native-verification/trial-parent151-152-paired-verification.json`. The exact owner SIGSEGV and full live quit acceptance remain open.
