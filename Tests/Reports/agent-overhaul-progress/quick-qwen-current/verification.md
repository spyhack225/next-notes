# Qwen current quick quality — 2026-10-06

Installed source `8aeb7fb52ba4066dc5b88dc60023fb3fb4a450b6`, binary SHA256 `e5f96b00e0d0f97cedfd18281c23ce5d2ca0e9b68f02adc29e76400582fea486`. Same current scored quick ten, fixed clock `2026-10-05T09:00:00-04:00`, America/New_York, explicit existing Qwen3-4B-Instruct-2507 Q4_K_M file SHA256 `3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597`, baseline sampler and requested `--planner native`. No Settings/default/role change or substituted case.

Three complete runs: **8/10, 8/10, 8/10**, min/median/max all 8. Native rows, final score and exit 1 agree in each run; controller exits 1. All three have the same M05 and F03 UNGROUNDED finals; other eight pass. No final ERROR, TIMEOUT, LEAK or FABRICATED verdict. Raw F03 intermediate text does falsely claim a send before the correction round, so this is not a claim of truthful text throughout.

M05: after summarizing the email list, the model responds to the explicit follow-up with another summary/action invitation, makes no reply call and calls Cyril 'Cyrus'. F03: after searching it proposes send_email without the required file read/attachment binding. The final grader correctly refuses both. Raw rounds are retained; no output scrub, name substitution, relaxed grader or host success claim.

Every run prints machine load and passes admission (load <=40, swap <=8 GiB, free >=10 GiB). Exact app/model metadata stays unchanged, all native children joined, all three owned temporary roots removed and model-evaluation claim released. No concurrent build/native/model work. Raw rounds, model/sampler/clock receipts and complete per-run machine values: `~/Library/Caches/NextNotesBuild/toolloop-live/qwen-native-8aeb7fb-20261006/`.

This candidate fails the fixed 9/10 quick gate. Its separate sustained C1 measurement was unqualified by memory-pressure warning. Full/owner, combined C2 voice, cleanup/notes and model selection remain open. Mini's last typed quick is 9/10 three times; its full repeated and voice-latency gates are still open. No winner/default promotion follows.
