# Scheduling fixture fidelity — 2026-10-05

The live-evaluation fixture reported success for a retained malformed R01 call that the actual ScheduleToolExecutor rejects: time “Tomorrow 09:00”, routine model “gpt-4o-mini” and repeat “Never”. The fixture now uses the existing native kind/time/trigger/model/end-date parsers before recording a call or synthetic result. No corpus, grading threshold or product scheduling rule changes.

The identical retained call and field controls fail 13 assertions before the producer change and pass afterward. Valid reminder/routine/trigger cases remain accepted. The actual private executor rejects the original payload without saving a schedule. Four related flags pass once: production tool loop, scheduler, tool review and owner isolation.

A focused native R01 replay on the same explicit MiniCPM5-2B file, baseline sampler and fixed 09:00 clock passes with kind=reminder, date=tomorrow and time=09:00. It is one model replay, not a new aggregate score or live account action. The historical 27/30 and 25/30 runs predate this fixture correction and retain their false-positive caveat. Full routine execution/admission fidelity and broader scheduling quality remain open.

Also corrected the checkpoint's N03 description: the original request asks for Australia's capital; it is not a personal-memory request. Exact case/raw qualification is retained in the cache.

Evidence: `~/Library/Caches/NextNotesBuild/integration/r01-schedule-fixture-fidelity/` and `integration/n03-original-request-qualification/`. Bulk artifacts remain outside iCloud.
