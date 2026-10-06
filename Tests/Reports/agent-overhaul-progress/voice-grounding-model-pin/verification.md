# Voice grounding model qualification — 2026-10-06

The original diagnostic ignored its explicit MiniCPM file argument and loaded Gemma before selecting a provider. Selection now uses the existing resolver before shared-runtime token checks; selected/completed artifact receipts require the same loaded file. No saved defaults or product voice path changed.

Identical explicit-file command: original staged66354 selected Gemma (4,977,171,584 bytes); fixed66546 selected MiniCPM5-2B (1,561,318,368 bytes), loaded=true and matches=true. Candidate qualification is corrected. **VOICE_GROUNDING remains FAILED**: Mini fails the original referent, timeout and user-name expectations. Four questions, histories, token caps and predicates are unchanged. This direct model diagnostic does not establish ASR/playback acceptance.

Capture, meeting-health and store-isolation pass on the same tested bundle. Exact binary SHA256: 4c5f81a307c1edc32b61e34a50063cce42c2c6ff8521e46f16d65ca442fcc74d. Raw logs/results: `~/Library/Caches/NextNotesBuild/integration/voice-grounding-candidate-pin/`; owned test temporary roots removed. Full/owner/quick results from earlier commits are not relabeled as this artifact.
