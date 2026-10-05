# Joined voice model metrics — 2026-10-05

The existing voice-latency validator joined model passes to the counted turn but emitted none of their measurements. It now reports each joined model pass's stored TTFT, decode rate, output count, estimate flag and warm state. Missing fields stay unavailable. Turn-summary latency is excluded; its validation and stage medians are unchanged. No second log/store or production-path await is added.

Original existing instrumentation flag: **RED3 → GREEN**, byte-identical actual timeline/persisted usage/joined-consumer assertions. Usage-log26, voice-delivery, turn-routing and store-isolation21files32defaults pass. The retained authored haiku WAV (ec9f48e5…fbeab) also passes the real voice pipeline (warm-up plus one counted turn). Its joined Apple answer reports TTFT1332ms, decode315.068tok/s, 23 estimated tokens; unavailable route/warm values remain labeled. The authoritative selftest file preserves lines that the combined stdout/stderr log can interleave.

One counted turn is not a latency acceptance sample or C2 floor: L1=.674s, L2=2.449s, L3=2.661s and main stall=.033s. Speed gates remain unmet; this reporting change claims no latency improvement. Source, logs and fixture pin: `~/Library/Caches/NextNotesBuild/integration/voice-model-pass-metrics/`. Bulk evidence stays outside iCloud.
