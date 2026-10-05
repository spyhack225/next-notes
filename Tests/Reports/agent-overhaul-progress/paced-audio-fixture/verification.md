# Paced audio fixture prerequisite — 2026-10-05

PL-01 requires real-time audio input while decoding. The existing private file feeder delivered all audio immediately, so it could not measure that overlap. It now optionally feeds the same one-second chunks at cumulative monotonic audio deadlines through the existing ChunkedTranscriber. Normal file transcription stays unpaced. Cancellation drains the same transcriber before the feeder returns; no additional ASR owner or product wait is added.

The identical authored 5.25-second fixture failed five pacing/cancellation assertions on the original and passes on the fixed build, including the actual ASR entry and collected segments. Real Parakeet transcription of the retained authored haiku WAV also passes through the unchanged default call site. Backlog, meeting resume, usage log and owner isolation pass once. Meeting-finals reported missing fixtures and is unavailable, not a pass.

This proves the input prerequisite only. Native concurrent ASR/decode C1, sustained decode, fixed-token C2, memory and latency acceptance remain open. Evidence: `~/Library/Caches/NextNotesBuild/integration/pl01-c1-paced-file-prerequisite/delivery-b11df78/`. Disposable audio is removed by the self-test.
