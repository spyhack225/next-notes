# Pinned quick runner

Requires an explicit model and fixture clock, at least three runs, and the existing install lock. Every run prints load, swap and free space and keeps raw reports outside the repository. Only complete matching rows, model/clock receipts and final verdicts contribute to min/median/max. Changed binaries or fallback models invalidate a run.

`PYTHONDONTWRITEBYTECODE=1 python3 Scripts/pinned-quick-selftest.py`: 11 checks pass for actual `.md.jsonl` naming, score/exit mismatches, incomplete/duplicate rows, fallback, missing raw rounds, clock/model mismatch, binary replacement and resource refusal. Temporary fixtures clean up on exit. These are runner contract checks, not a model-quality evaluation.

Swift instrumentation and the three real pinned runs remain pending. The machine still exceeds the owner’s 8 GiB swap limit; no new model score or installation is claimed.
