# Current app observation — 2026-10-05

The selected screen class had no current-app read floor after the model omitted a call. The existing account-read seam now supplies computer.active_app only for a complete simple current-app question. An exact completed current-turn observation suppresses duplicates; previous-turn or unrelated screen reads cannot supply fresh current-app state. General screen questions, compounds and quoted prose remain outside this seam.

Same “Which app is frontmost?” and raw “The frontmost app is... let me check.”: original nine failures -> PASS. Actual registry/executor/permission admission and final provider receive the fixture observation. Two subsequent turns each observe; already-completed, missing descriptor and denied policy controls pass. Capability manifest, tool review, voice routing and owner isolation pass once. No owner window or clipboard was read.

Pinned MiniCPM5-2B baseline at Oct 5 09:00 New York: A04 now observes computer.active_app and answers Safari/YouTube from the actual fixture result; PASS in two planner rounds. Physical UI and general screen-content freshness are separate open requirements; no broader roadmap or latency acceptance follows.

Evidence: `~/Library/Caches/NextNotesBuild/integration/a04-active-app-read/`. Bulk artifacts remain outside iCloud.
