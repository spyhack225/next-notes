# Meeting source-selection experiment and production hold

Confirmed new native failure: the MiniCPM source-ID mapped producer selected five of 519 included utterances across three map calls. All arrays were structurally valid; none hit its token limit. The four-pass workflow finished in 53.79964792728424 seconds with 106 generated tokens and no collapse/drop. The semantic verdict fails: weak coverage and the owner follow-up missing. Faster execution does not justify production promotion. `incompleteFacts=false` is only the absence of reported structural failures, not complete meaning coverage.

## First bounded contract hypothesis

The staged prompt experiment removes the small three-ID example and asks for every distinct substantive topic, speaker qualification/contrast, explanation, constraint, question with necessary answer, and future intention within the existing utterance-word budget. It retains the strict ID grammar, 24-ID ceiling, source order, full source-owned text/speaker/time, and existing map/collapse/reduce flow. No minimum selection quota is introduced. Counts or time bands cannot establish semantic coverage.

This is a prompt-contract hypothesis, not a confirmed fix. Run the current unchanged input/contract on Qwen first for model comparability; only then use the separately staged prompt change if needed. Whole source-index and mapped output use their actual counted model context; a complete transcript must not bypass the existing whole-input fit check. Added prompt words may increase prefill; measure exact tokens/time rather than claiming free improvement.

## Smallest production safety seam

Append `sourceIndices: Bool = false` to `NotesGenerator.init(...)`. Store `private let sourceIndices: Bool` and set it to `SelfTest.isRunning && sourceIndices`. Keep the existing observer guard. There is no persisted setting or production model/default change.

Restore HEAD's `mapSystem`, `collapseSystem`, map word-limit text and reduce evidence-introduction text as normal production prompts. Keep current selection prompts under `mapSelectionSystem`/`collapseSelectionSystem`; select the prompt at the existing call site from the guarded bool. Append `sourceIndices: Bool = false` to mapUser/reduceUser only where wording differs, preserving normal HEAD strings byte for byte.

Reuse the current `NotesEvidence.Batch` container by adding `init(text: String)` that keeps the exact text and sets sources to an empty array. In normal mode, use HEAD's unchanged `Self.chunk(segments, speakerNames:, targetTokens:, transcriptCharacters: transcript.count, transcriptTokens:)`; map its returned strings to Batch(text:). This preserves the original chunk boundaries and token-count cost. In the diagnostic mode only, use the current source-index transcript count/chunks/Batch(sources:).

Reuse the same loops, group, recorder, budgets and retry/drop logic. For normal maps, call recordedComplete with nil grammar; stripThinking/trim as HEAD did, append only nonempty Batch(text:). For normal collapses, call with nil grammar; retain the original input on empty output exactly as HEAD did. For diagnostic maps/collapses, use current strict source-ID grammar/admission/trace/fallback and derive Batch from original sources. Choose the reduceUser introduction using the same flag. Do not duplicate mapReduceCore, create a ledger/store or append a checker model pass.

The copied private replay harness explicitly passes sourceIndices: true when exercising this experiment. Production construction stays false even if a caller mistakenly requests true outside SelfTest. The quote-copy contract helpers and final quote/index diagnostic replay remain diagnostic-only.

## Acceptance before any install

Retain the original HEAD generated-facts fixture behavior and unchanged assertions for normal mode. Test production default generated-facts prompts, plain transcript chunks, nil grammar and original pass/token boundaries; separately opt in source-index fake-provider fixtures and the retained exact-source/negation/scope regressions. Adapt provider system comparisons to recognize experimental prompt names rather than silently passing index output through the legacy producer. The current source-derived fixtures are not a legacy default parity test.

Native normal-mode owner fixture must reproduce the accepted baseline's generated-facts behavior and inherited cut/disclosure contract. The structural footer separator fix is orthogonal and may intentionally alter only paragraph spacing. Source-selection promotion additionally requires private gold review of the two speakers' experience attribution, future visit intent without invented deadline, substantive domain distinctions and coverage, plus readable notes and measured latency/token/pass/memory costs. Every failed/native-empty output remains retained and labeled failed. A larger selection cardinality is not a semantic pass.

If no strategy meets those gates, install only independently verified capture/responsiveness, speaker/citation and bounded performance-observation chunks with the legacy default producer preserved. Keep the installed owner notes strategy and saved preferences stable. Do not describe the inherited notes quality failure as fixed; the broader quality loop remains open. No canonical source edit, compiler or model was invoked for this proposal.

Cache prompt patch: `/Users/sergekadjo/Library/Caches/NextNotesBuild/meeting-notes-coverage-hypothesis-59sw1byp/experimental-comprehensive-selection.patch`. Frozen NotesPrompts SHA-256: `e26309ce25a9146b3b9576e108d49713b144289bd4ad1d20f7111fe6d651ac08`; proposed experimental prompt SHA-256: `7f6da00dfa86ac62bd087d901e1fa9128318ad7017126805972c3d423d16ef33`.
