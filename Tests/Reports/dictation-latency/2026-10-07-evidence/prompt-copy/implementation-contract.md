# Prompt-copy acceleration: bounded implementation contract

Status: next experiment prepared; not implemented or promoted. Current source remains frozen for sixth build.

## Confirmed reason to test

Long full Core finishing still waits about 6.3 seconds for the unchanged layout deadline. Semantic cleanup also rewrites substantial unchanged dictation text one token at a time. The second problem can benefit from verifying several proposed copied tokens in one native batch. This does not repair global layout by itself.

Use only the existing NotesModelRuntime completeForDictationCleanup entrance and its completeWhileScheduled body. No second model, task store, worker queue, sampler, generated-text sanitizer or runtime owner. Initial experiment is SelfTest-only and off by default. Existing notes/voice/grammar entrances retain their normal route.

## Native algorithm

1. Tokenize the actual supplied user text without adding a new BOS token. Keep an ephemeral index of token continuations within this one request, or start with a bounded suffix scan to measure lookup cost. Never copy words to the delivered answer without target-model verification.
2. Sample the next actual token with the existing sampler from current logits. Preserve existing EOG, family stop marker, output construction, counts and scheduler checkpoint semantics.
3. Find a 3-to-8-token suffix of accepted generated history in the input. Propose at most four following tokens; ordinary mismatches are expected. The proposed tokens are not accepted into the sampler.
4. Decode the actual chosen token plus proposed following tokens in ONE causal native batch, requesting logits for each position. Append only the chosen actual token to the existing kvTokens ledger initially.
5. At each next actual-token checkpoint, sample and accept exactly once using logits index0, then index1, in output order without gaps. The bundled llama.h explicitly defines llama_sampler_sample as sample AND accept; never call accept a second time. Sampling advances randomness/grammar/repetition history only for actual accepted output.
6. For each matching proposal, expose the actual sampled token through the existing output/count/stop logic and append its already decoded KV entry to kvTokens. On the first mismatch, delete every unaccepted future KV entry from the exact current position, decode that actual mismatching token, and resume normal generation. Do not sample remaining speculative logits or rewind the sampler.
7. EOG and family stop need special attention: serial EOG/stop does not decode that ending token; a token that merely reaches maxTokens does get decoded before the serial loop ends. Match those ledger/position contracts exactly. Keep budget, whitespace, control markers, UTF-8 pieces, token counters and finishedByLimit unchanged.
8. On cancellation, trim unaccepted future KV entries before releasing the SAME native context reservation. Checkpoints may park while a predicted batch remains in memory, but no other request can own that context. Cancellation must leave only accepted prefix positions. Native failure or refused rollback clears native memory and ledger instead of pretending cache reuse is safe; report the original failure without retry or extra model pass.

## Required proof, in order

- Pure continuation lookup: repeated phrases, overlapping matches, Unicode token IDs, empty/short/history mismatches and length bounds. Measure lookup overhead against actual prompt sizes; do not create a permanent cache or scan an entire long prompt after every token if that erases the gain.
- Actual native private S1 CPU: same fixed sampler parameters/seed, same prompt/source, original versus copy path. Require exact output, EOG/stop/limit counts and KV ledger; force early mismatches and complete matches using known native generation, not a fabricated model reply.
- Actual parked cancellation while ASR lane is held, plus same-prompt successor/cleared-context controls. No stale speculative entries or leftover owned producer. Reuse the installed native prefix/cache fixture.
- Actual MiniCPM CPU/Metal sampling: exact before/after output and independent source-content checks. Batch numerical differences can change stochastic choices even when mathematics is equivalent; no blanket distribution/accuracy promise from the C header.
- Full existing 42-case cleanup quality plus production exact command/quote/file-tag tests, held/rapid/superseded jobs, model swap, shutdown and existing usage/source counters. Disclose inherited failures and reject any newly introduced regression.
- Real public 8/60/121s Core replays with every feature enabled, cold/warm/long latency stages and ASR-plus-voice duty on the 16 GB Air. Record native batch count, accepted/proposed/mismatch tokens, rollback refusal, CPU/footprint and lookup CPU. Benchmark original/fixed as one joined process sequence, not during a compiler.

## Limits

This is a larger optimization and requires actual native KV/sampler evidence. A syntactic prototype or fake scorer is insufficient. Model copying cannot infer missing acoustic words. The quiet producer, global structure planning, physical capture/display/insertion and all existing feature gates remain separate. It is not a two-second result claim.
