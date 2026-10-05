# Diagnostic stdout boundary — 2026-10-05

Confirmed producer: buffered SelfTest.diagnostic print mixed with the App's immediate final-marker write. The retained actual pinned voice run completed a native42-token answer but its model metric was split by VOICE_LATENCY_OK. The diagnostic now uses the same immediate stdout writer; its existing output mirror is unchanged.

Focused actual4096-byte boundary reproduces the split on COMMON and passes on fixed output with a separate adjacent marker and intact mirror. The same accepted-haiku native consumer now emits an intact model metric. C2 instrumentation, usage26, owner isolation21files32defaults and voice delivery pass once. This does not claim atomicity across every concurrent external writer or fix voice latency.

Bulk original/fixed stdout, mirror and native logs: ~/Library/Caches/NextNotesBuild/integration/diagnostic-output-boundary/ and ../pl01-c2-fixed256/root-proof/.
