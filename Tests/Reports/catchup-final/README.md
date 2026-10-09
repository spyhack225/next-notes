# Combined Catch-up merge verification

The tested merge is `eaafc732`, with parents `63a7e471` (audio) and `c0d37462` (screens).
The only conflict was the offer row in `CatchUpViews.swift`. The merged row keeps Reply
for questions without a verb phrase, No thanks, the existing Library acceptance seam,
and the audio branch's shared permission wording. Both parent histories/diffs and the audio
parent RESULT are retained here; the UI parent has no tracked RESULT.md.

A bounded additional copy repair changes the Settings footer to reuse that same
permission explanation. `verify-copy.py` checks the original screens parent and fixed
producer with the same predicate; `copy-pair.txt` retains original FAILED/fixed OK.
The actual Agent-panes source consumer now checks the same contract. This is copy
correctness, not a change to permission behavior. Covering standing grants still apply.

`verify-slot.sh` runs one debug build, then the nine requested flags sequentially.
Agent-panes also renders injected offscreen previews under a unique temporary folder.
Raw stdout/stderr, separate available self-test diagnostics, source hashes/invariance,
binary hash/UUID and environment are retained. Debug scripted checks are not optimized
performance measurements, real-model action accuracy, live acoustic safety, physical
controls or an owner-store migration. The inherited Settings SIGSEGV is kept separately,
and embedded browser failures must not be labelled passes by the isolation root marker.

See root [RESULT.md](../../../RESULT.md) for actual verdicts, screenshots inspected,
cleanup and all six canonical dirty-file conflicts. Performance/acoustic and broader
recovery/readiness contracts from both parent reports remain open.


Round 2 review repairs and the explicit saved-file audio decision are retained in
[round2](round2/README.md). The original combined proof above remains historical;
round2 retains a separate native original/fixed pair and final nine-flag batch.
