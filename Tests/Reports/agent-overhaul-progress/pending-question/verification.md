# Pending confirmation question — 2026-10-05

`PendingAction.lastSentence` accumulated every sentence rather than retaining the final one. After the recorded six-email summary, literal “yes” carried the whole summary as “You then asked”. The existing accumulator now retains the final completed sentence or unfinished tail.

Original/fixed `--selftest-toolloop-production`: **RED6 → GREEN**, identical raw summary/yes inputs, actual typed consumer, one successful fixture-backed mail read, exact raw round, grounded prior context and no invented writes. Voice routing, tool review and store isolation pass. The COMMON fixture was corrected before the matched pair: normal encoded reads use the runner receipt; the existing renderer collapses double spaces. Initial failed checks remain retained.

Evidence: `~/Library/Caches/NextNotesBuild/integration/m05-4f3b52c-review/pending-question/`. Latest installed-model baseline before this slice is MiniCPM **7/7/7**; fresh M05 model composition, full/owner and latency gates remain open. This repair adds no model pass, wait, store or confirmation.
