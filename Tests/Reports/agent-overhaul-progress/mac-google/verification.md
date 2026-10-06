# Mac Google integration — 2026-10-05

Integrated the non-UI Mac-account packet through the existing workspace runner: Mail/Calendar supply the default path; Google sign-in remains the advanced alternative. Fixed actual sender identity at proposal and compose boundaries, retained the exact selected sender in AppleScript, and refused reordered/replaced accounts. Calendar verification uses its saved native identifier, never matching content; uncertain Mac saves retain unknown outcome without fabricated Google artifacts. Admitted isolated CLI fixtures keep their own process route.

Original9 failed assertions become green on unchanged Mac-account inputs. The test uses generated Mail files, native calendar/runner fixtures, actual prepared result/receipt consumers and compilation of the actual script against Mail.sdef; it performs no real Mail sends or account reads. Shared production, schedule, capability manifest, tool review and owner isolation all pass. Real Automation/FDA/EventKit, first-run/onboarding, OAuth and native sends remain open. Only the required shared five-line UI lint word list is included; views/theme are outside this commit. Foreign canonical Settings-sheet and meeting-fit/evidence work is preserved.

Bulk original/fixed raw logs, patches and combined build results are outside iCloud: ~/Library/Caches/NextNotesBuild/integration/catch-up-google-integration/.
