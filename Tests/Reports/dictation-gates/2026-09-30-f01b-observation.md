# F-01b — enforce D-13's observation minimum

The normal `--gates` command could recommend pipelined dictation holds after a
single day. Its seven-day check ran only when `--since` was supplied; an arbitrary
older cutoff could also manufacture an observation window that the hold rows did
not support. F-01a preserved this pre-existing logic; this follow-up repairs that
gate-decision producer without touching dictation execution.

## Contract and producer change

The original D-13 task requires checking after **at least seven days and 100 owner
holds**; the current rates roadmap says **≥7 days of use**. Neither specifies a
rolling last-seven-days window. The reader now derives a conservative observed
window from the earliest valid eligible hold through the diagnostic's current
time. `--since` still selects rows; requesting an older start cannot invent
unobserved days. Both default and filtered modes apply the same seven-day bar and
report `observation_days`, `days_required`, and any missing days.

Missing retained history can postpone readiness rather than fabricate it. No new
window/store/scheduler was added. The 100-hold, seven-day and three-refused-presses
per 100 thresholds remain unchanged. D-14 logic is unchanged from F-01a.

## Before and after

The real subprocess fixture with 100 same-day holds and three finishing refusals
returned `proceed` before this change, both in default `--gates` and with an older
`--since` cutoff. Both must remain `not enough data`. Those two wrong verdicts are
captured in [red](2026-09-30-f01b-red.txt); two additional failures there require
the newly explicit observation fields. Existing F-01a cases remained green.

All **15 real CLI fixtures** now pass: [green](2026-09-30-f01b-green.txt). Added
cases also pin recent-cutoff exclusion of older rows and the exact seven-day
boundary with 100 holds, preserving both material `proceed` and non-material
`won't do (evidence)` verdicts after enough observation. Fixture stores are
unchanged; scoped `git diff --check` passes.

The read-only owner command now reports **27 holds, three observed days, 73 more
holds and four more days required**. It remains `not enough data`. No owner-use
task, app gate or pipeline behavior was completed by this diagnostic repair.

Changed source/test: `Scripts/dictation-stats.py` and
`Scripts/test-dictation-stats.py`. No build, install, model run, data upload or
owner-store mutation was needed.
