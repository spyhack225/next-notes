# Installed Agent quality checkpoint — 2026-10-06

Verified source commits 2ec0efd (per-answer successful tool sources) and 4683f7f (bounded O01 email-history grader correction). Installed exact tested artifact with OPEN=0; binary SHA256 e11863982b853ecfbaf0450a0b5774a500ca64ab5114e26bc4d202716e7dfb0f; deep/strict codesign passes. These producer and measurement fixes have separate original-red → fixed-green notes and focused related checks.

Current pinned MiniCPM5-2B-Q4_K_M baseline, fixed 2026-10-05 09:00 New York clock: two consecutive full runs **25/30 and 26/30**, minimum25/median25.5/maximum26. **O01–O09 all pass both; O10 also passes both. Zero ERROR, TIMEOUT, LEAK, FABRICATED or WRONG_TOOL.** Raw40-case rounds retained. Admission load4.29/4.71, swap4.56 GiB, free11.62 GiB. Binary unchanged; owned temporary roots removed after process joins. The roadmap numerical full-score and required owner-case items now pass on this artifact; the runner conservatively exits1 for remaining refusals, explicitly recorded.

Three pinned quicks on 2ec0efd source scored **9/10 each** (minimum/median/maximum9), before the grader-only4683 correction. They are not mislabeled as three runs of the final artifact. Final full failures remain K03/R03 UNGROUNDED, F02 MISSED_TOOL and F03 REFUSAL in both; N03 UNGROUNDED only in the first. Source passing and corrected O01 scoring do not resolve those product failures.

Phase1 remains open: current Apple full (required zero fabrication), current required functional flag reconciliation including native-tools and voice-work-lifecycle, make test/CORE and owner documentation reconciliation. Broader roadmap voice latency, wake accuracy, PL01 floor/C2, live acceptance and default promotion remain open. No model/default or needle-first promotion is claimed.

Raw evidence outside iCloud: ~/Library/Caches/NextNotesBuild/toolloop-live/mini-full-4683f7f-20261006/{summary.json,full1.md.jsonl,full2.md.jsonl}; quicks in integration/o01-answer-tool-provenance/native-fixed2/. Adjacent answer-tool-sources and email-history-grading notes retain producer/grader red→green proof. Model and git-index claims released.
