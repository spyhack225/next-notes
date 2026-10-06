# P2-02 — exact split-session prewarm

The prior producer discarded staging in split mode. Capture now supplies the actual coordinator request without unfinished speech; the frontend prewarms independent route/Apple-answer transcripts and consumes only matching instructions, history and application prefix, once per generation. Expiry, cancellation and capture/turn changes refuse stale sessions. No new turn-path await, timer, queue, provider change or control-schema reduction.

Original staged17979: focused contract fails nine assertions. Fixed18218: same contract passes; the real SDK corpus consumes its exact prewarmed route in all13 successful route calls and its answer in all7 answer calls. The unchanged corpus still fails the same two calendar cases on both original and fixed: status classified as spawn, and missing task identity. Original additionally fails28 absent-staging assertions; fixed has zero session-identity failures. Routing quality remains OPEN.

Voice preparation/actual staging composer, delivery, duplex and store-isolation flags pass once; the previously recorded nested A02 production-fixture failure remains inherited after STORE_ISOLATION_OK. All native children were joined and owned temporary roots removed. Builds used load2–3/swap4.84GiB with >10GiB free. The compiled fixed binary SHA is `2c738122be79de24f2b6fda2ee9b8b47be2731f04b65786cb69640016b244f03`.

Cache-only original/fixed logs, patches and results: `~/Library/Caches/NextNotesBuild/integration/p2-split-session-prewarm/`. Exact source code and two staging diagnostic columns are included in this commit. Production Apple five-turn audio measurement follows installation; no speed improvement, P2-02 mode selection, phase closure or default promotion is claimed from session identity alone.
