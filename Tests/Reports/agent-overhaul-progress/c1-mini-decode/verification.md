# Mini C1 decode — 2026-10-06

Installed source `22675db948bb60ffbd09c957a7813a6db50bee6d`, binary SHA256 `0321ba4fe5b3358d587f8eb1fca7b6ac5b1482e1e0c4ee484a7a97c2554e215c`. Apple M3 / Mac15,12, 16 GB, AC power, low-power mode off. Pinned MiniCPM5-2B Q4_K_M SHA256 `ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`; existing authored haiku WAV SHA256 `ec9f48e5b38281e2ef3022904db9eb2e3eb5b69bdcbaab94faf000a9c91fbeab`.

One actual C1 run: 604.28 seconds sustained; 96 native rounds of exactly 256 completion tokens. Median 42.20 tok/s, p10 36.14; minute 1 full-pass decode 41.15 tok/s, final requested minute 39.23 (8 complete passes within 540–600 seconds). Exact uncached 2,000-token prefill recorded. Parakeet: 122 native returns, all successful; all 96 decode rounds overlap ASR. Peak app RSS 1,965,965,312 bytes; observed pressure normal, no guardian history gap; swap decreases 41,943,040 bytes. Independent thermal samples start nominal, change to fair at 340 seconds, with zero skipped deadlines and joined sampler. This follows the committed nominal-at-start qualification; it does not assert nominal temperature for the entire run.

Native `LLM_METAL_OK`, controller `C1_DECODE_QUALIFIED`, no qualification problems. App/model/WAV identities unchanged. Native process and sampler joined; owned temporary root removed; relay model-evaluation claim released. Quiet preflight: load 2.74, swap 4.90 GiB, free 10.88 GiB; after join load 2.11, swap 4.86 GiB, free 11.05 GiB.

This is C1 decode acceptance only. C2 combined voice workload, full artifact/cache qualification, current per-role cleanup/notes acceptance and model-default promotion remain open. No default changed. Latest typed quick is 9/10 three times; repeated full is 25/30 and 23/30, owner 9/10 twice with mandatory owner subset 8/9, as recorded separately. No unchanged benchmark repetition.

Raw rounds, command, native log and result: `~/Library/Caches/NextNotesBuild/integration/pl01-current-c1/mini-22675db-600s/`. Larger artifacts stay outside the iCloud repository.
