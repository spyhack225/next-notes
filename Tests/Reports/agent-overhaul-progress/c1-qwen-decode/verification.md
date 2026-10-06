# Qwen C1 candidate — 2026-10-06

Source `8aeb7fb52ba4066dc5b88dc60023fb3fb4a450b6`, installed binary SHA256 `e5f96b00e0d0f97cedfd18281c23ce5d2ca0e9b68f02adc29e76400582fea486`. Apple M3 / Mac15,12, 16 GB, AC power, low-power mode off. Existing Qwen3-4B-Instruct-2507 Q4_K_M: 2,497,281,120 bytes, SHA256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`. Same authored haiku SHA256 `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`, native C1 workload and production sampler as the Mini comparison; no model setting/default changed.

Actual 609.30-second sustain: 60 distinct native rounds of exactly 256 completion tokens, median 26.29 tok/s and p10 24.30. Minute 1 full-pass rate 27.05 tok/s (six complete passes); final requested minute 540–600 seconds 24.19 tok/s (five complete passes). Uncached 2,000-token prefill recorded. All 124 native ASR returns succeeded; all 60 decode rounds overlapped ASR. Peak app RSS 3035185152 bytes; swap decreased 8,388,608 bytes. Independent thermal samples start nominal and become fair at about 290 seconds; sampler joined, zero skipped deadlines.

**Unqualified C1 acceptance:** guardian pressure reached warning (two recorded pressure observations, no history gap). Native prints `status=CONTENDED` although the functional flag ends `LLM_METAL_OK` with exit 0. The controller correctly returns exit 1 / `FAILED_OR_CONTENDED`, refusing normal-pressure and measured-sustain acceptance. The observed decode rates exceed 20 tok/s, but do not qualify the complete floor contract. No attribution to a particular other process and no unchanged rerun.

Before: load 1.89, swap 4.85 GiB, free 11.09 GiB; after join: load 3.12, swap 4.85 GiB, free 10.83 GiB. App/model/WAV identities unchanged; native/model/thermal work joined; owned temporary root removed; model-evaluation claim released. No builds or competing native/model jobs ran.

Mini's separate C1 report records p10 36.14 and minute-10 rate 39.23 with normal observed pressure. This comparison selects no winner: Qwen's complete C1 acceptance, C2, full repeated quality/mandatory owner rows, cleanup/notes and model-default promotion remain open. Current Qwen quality comparison is recorded separately.

Raw command, all native usage rounds, thermal/pressure metadata and result remain outside the iCloud repository: `~/Library/Caches/NextNotesBuild/integration/pl02-candidate-c1/qwen-8aeb7fb/`.
