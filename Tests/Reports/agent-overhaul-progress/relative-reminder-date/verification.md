# Relative reminder date — 2026-10-05

The recorded schedule.create call specified 09:00 without a date. The existing one-shot parser chooses the next such clock time, which persisted today at 09:00 when the person explicitly requested tomorrow at 07:00. The existing grounding seam now applies its shared single-relative-day rule to a simple one-shot reminder’s timing clause. Confirmed turns recover only the original objective from the exact existing PendingAction frame and a bare acknowledgment. Changed-time answers, recurrence, offsets, ambiguity and dates occurring only in the reminder body stay untouched.

Same recorded raw call: four original producer/private-store/actual-handle failures -> PASS. A real private ScheduleToolExecutor/store/fresh reader now retains tomorrow’s exact instant, unchanged text and timezone. Original assertion block remains identical; additive wrapper controls pass. Scheduler, routine authority, tool review and owner isolation pass once. The existing single approval, model-pass budget and parser remain unchanged.

Pinned MiniCPM5-2B baseline at 07:00: original and fixed both MISSED_TOOL. Original promises without calling; fixed emits a call missing title and does not complete repair. Native completions differ, so this is not an exact model-output comparison or improved readiness claim. The exact recorded no-date raw is repaired in the identical controlled real-store flow. Existing malformed explicit-date repair was preserved after a caught regression. Other scheduling language and model scheduling correctness remain open.

Evidence: `~/Library/Caches/NextNotesBuild/integration/r01-relative-reminder-date/`. Bulk artifacts stay outside iCloud.
