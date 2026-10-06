# P2-02: enforce the requested first-token budget

The existing voice latency diagnostic printed transcript-to-first-token timing but ignored the roadmap's `--voice-latency-first-token-budget` option. The existing closed-turn aggregation now checks the requested finite, positive seconds budget against that same measured median. A missing span or incomplete counted batch fails; no timing, threshold, model choice or voice pipeline behavior is changed.

Red-first qualification used the actual timeline's five authored closed turns through the same aggregation function used by the native file-fed consumer. Original missing-validator scaffold failed four assertions: slow batch, incomplete batch, empty batch and missing span. The unchanged fixed cases pass, including below-budget and exact inclusive-boundary cases. This is instrumentation-contract proof, not hardware latency measurement.

Focused flag and three related flags passed once: first-token contract, full latency instrumentation, metrics and owner-store isolation. Isolation retains 21 files and 32 defaults; its inherited nested A02 browser fixture INPUT_INVALID / TOOLLOOP_PRODUCTION_FAILED remains open. No full tool-loop or voice phase acceptance is claimed. The native argument admission rejects NaN, zero and missing values before any measured turn. Temporary roots are removed after joined tests.

Use `--voice-latency-first-token-budget 0.600` for the P2-02 five-turn comparison. The separate `--voice-latency-budget 0.900` still measures speech-end-to-first-audio. Current latency targets remain open; this change cannot improve speed itself.

Raw original/fixed logs, Source maps, binary pins, parser admission results and cleanup records are outside the iCloud repo in `~/Library/Caches/NextNotesBuild/integration/p2-first-token-budget/`.

Original binary SHA256: `48faf8a743667ae5299c8ee877df4a833b1eb0eff7b8d9570eeb663259b64729`. Fixed tested binary SHA256: `c10c2a5069062cd430b0d8669ab7cf2ff3a34eeac6d6a6b8f076a1d5aa2bb83a`.
