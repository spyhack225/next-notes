# Fifth release: diagnostic trace review plan

The cache-only pass-trace patch and optional forwarding fixture were checked against all three exact canonical preimages before root's fifth source gap. Primary and optional `git apply --check` succeeded. Root owns applying the hunks and the frozen fifth build. These applicability checks do not establish Swift compilation, native forwarding or semantic quality.

## Protocol/concurrency review

`MeetingNotesReplaySelfTest.run`, `loadFixture`, `runExtractive` and `runTraceForwardingSelfTest` inherit the enum's MainActor. The private provider adapters and their helper methods are value-type instance methods. `PassTracingProvider` contains the Sendable `LLMProvider` existential and `OSAllocatedUnfairLock<[PassTrace]>`; `PassTrace` contains only Sendable value fields and conforms to Encodable. Locks bracket append/update operations and never span an await. No Task or new recorder is created by the adapter. Its direct delegated await retains the caller's current recorder. The immutable SelfTest-only `replayIdentity` getter reads the recorder's let feature/pass and does not read mutable usage or saved state.

The plain/grammar completion overloads delegate exactly once to the same overload with the unchanged system, user, allowance and grammar, and return the original completion or rethrow the original error/cancellation. ID, display name, reader window, availability, grammar enforcement and tokenizer delegation remain intact. Streaming/tool APIs are not used by this notes path; no claim of an independently tested general-purpose stream adapter is made. The fixture's TaskLocal operations capture only Sendable values and the existing Sendable recorder; its write callback and failure list remain on MainActor. The immutable test failure uses explicit unchecked Sendable; its fields have no mutable state. Native compiler/forwarding proof remains root's gate.

Failure ordering is intentionally unchanged in shape: defer sits **inside do**, so it emits captures/failed usage while unwinding that scope, before the **outer catch** writes the final FAILED marker. Fixture-load failures occur before any model call or installed defer. Success writes OK from defer after captures. Verify this ordering on an actual native failed copied replay as well as the generic completion/error/cancellation forwarding fixture.

## Two independent native captures

1. Whole-reader legacy Mini first, with explicit pass trace and no forced window/source-index modifier. Expected existing topology: one single call. Compare source input → raw single output → markdown. The original owner note is 137 tokens/99 words from a 14,062-token prompt; the earlier copied whole replay is a separate 175-token output. Empty replay brief and missing original raw prompt preclude a byte-identical production claim.
2. Legacy Mini with the explicit 8,192 reader window, same copied fixture and private trace. Expected alternative: three maps plus reduce. Compare source inputs → aggregated map facts → raw reduce → markdown. Its length/compression findings concern this controlled alternative only.

No extra inference/checker/retry is added to either workflow. Record any existing retry/overflow/body divergence rather than forcing the expected counts or silently accepting a mismatched topology.

## Offline script

A generic `review_passes.py` is retained in the owned pass-trace staging cache's `review-tools` directory. The independently derived owner gold config remains private in the diagnostic review's `quality-loop/legacy-pass-gold.json`. Ten categories cover individual experience/qualifications, future follow-up, answered handoff context, stage distinctions, illustrative quantities, budget/BOM/tools, supplier-link verification, AI prototype/engineering limitations and cross-disciplinary iteration. The original private reference remains authority, not the search patterns.

The script rejects absent raw calls, wrong call count/order/features, mismatched usage/completion/finish counters, wrong model/fixture, unexpected experimental grammar and missing final success marker. Full source-line checks include original speaker labels and actual counter formatting; public metadata contains only coverage booleans/source IDs and cost counters. Exact fixture/system/user/raw/markdown hashes and matched source membership stay private. Input hashes refer to the captured copied run, not the unavailable original production prompt.

Private lexical markers identify review candidates. They never prove semantic preservation, attribution, negation, tense or action classification. Semantic stage verdicts require explicit source-reviewed annotations tied to exact log/fixture hashes; unreviewed values stay null. The script can then report the first reviewed loss/error. Its public `gold_checks_passed` is limited to those reviewed gold checks; `semantic_quality_proven` remains false, and no audio accuracy or default promotion follows. Broader readability and unsupported additions still require the full private human review.

Python syntax parsing passed. The upcoming actual native logs and complete script execution remain pending; no source/compiler/model/native calls were made by this review.
