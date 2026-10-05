# thinking — 2026-10-05

Completed in the assigned files on `claude/thinking`. The original strip-and-cap regression is red → green; all six required checks pass. The reserved-provider integration remains the handoff below.

## Confirmed producer cause and change

The base runtime closes thinking in every prompt. Its streaming producer removes control markers within individual token pieces, leaving reasoning contents visible and missing split markers. It has one generated-token budget and one sampler profile. To reproduce it, I stashed the six prepared edits, extracted that original stream processing into `ChatTemplateOutput`, and wired the actual base runtime stream loop to it. The extraction added no hidden state or cap. I then restored the prepared edits and ran the same strip-and-cap assertions against the fixed producer.

Completion and streaming now share the output boundary. MiniCPM Agent work has 512 thinking tokens and meeting notes have 1,024, in addition to the visible budget. Cleanup and conversational voice stay off. Forced closing tokens extend the same native KV ledger; failed decoding clears both native state and its token ledger. Thinking bypasses answer grammar, which resumes after closure. The MiniCPM thinking sampler is 1.0 / 0.95 / 0 / 1.05; other requests keep 0.6 / 0.9 / 0.05 / 1.05. Hidden text is discarded before output callbacks and completion results; only its numeric count reaches the existing usage recorder.

Review also found that the prepared completion renderer exposed native tool delimiters in cleanup and notes. The actual producer's renderer was extracted without changing that behavior, and a native-vocabulary regression failed twice. The fix retains thinking/turn markers for stripping, preserves native tool markup for Agent work, and keeps the previous special-token handling for other completions. Those identical assertions pass in the final build.

## Required handoff — reserved provider

`Sources/NextNotes/Agent/MeetingAgent.swift:310` calls `provider.complete(system:user:maxTokens:tools:)` for review and live proposals. This bypasses AgentPlannerBackend. In this worktree, LlamaLLMProvider has no tools-completion override, so the LLMProvider extension forwards to generic completion, whose thinking default remains off.

Do not turn every generic completion on: cleanup, extraction, memory and other consumers share it.

Serial-root should wrap its MiniCPM native tools-completion implementation in `Sources/NextNotes/Formatting/LLM/LlamaLLMProvider.swift` with:

```swift
try await LocalThinkingRole.$current.withValue(.agent) {
    // Existing tools-completion body, including its runtime.complete call.
}
```

The wrapper must enclose creation/execution of the actual runtime request. This gives proposals the same 512-token profile without editing MeetingAgent or LLMProvider. That route is still incomplete in this branch. Neither reserved provider file was edited.


## Verification

The initial unchanged-base build was cancelled while still queued, before Make ran. Delivery-priority holds later returned gate exit 75, and the resource gate waited for swap to fall. Those attempts ran no tests and are not counted as passes. No gate bypass was used.

The original-producer extraction built in 177.25 seconds and chat-template exited 1 with `CHAT_TEMPLATE_FAILED: 77 problem(s)`. `<think>private reasoning</think>Answer` emitted `private reasoningAnswer`; a split after `<` emitted `<think>private reasoningAnswer`. Two reasoning pieces emitted `private reasoning` and reported `closure=false`.

The strip-and-cap function is byte-identical in red and green, including its actual 512/1,024-token cap assertions. SHA-256: `81d016bc5dbf1c67ebefcdb0524fbec1b501c90c21bdd5f8e0e58937ebaad59c`. Role/sampler cases are additive in green. An intermediate restored build passed in 42.00 seconds. The additional completion-rendering red built in 26.86 seconds and exited 1 with exactly two delimiter failures. The final corrected build passed in 21.62 seconds.

Every build and self-test ran through `lockf -k .../heavy.lock` and `gate.sh`. The final job used the updated `heavy.sh` wrapper, which invokes that lock and gate, with two build jobs:

```sh
/Users/sergekadjo/Library/Caches/NextNotesBuild/wt/heavy.sh 'make webrtc-audio && swift build -c debug -j 2 --scratch-path /Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/thinking && sh /tmp/thinking-green-checks.sh'
```

The temporary runner retained the lock and checked `gate.sh` immediately before each of six explicit sequential self-test calls. Each call used the scratch binary and `--selftest-out $TMPDIR/thinking-$$.log`. There was no build loop. The runner has been removed after recording the results.

| Check | Exact final marker | Exit |
|---|---|---|
| Original strip-and-cap red | `CHAT_TEMPLATE_FAILED: 77 problem(s)` | 1 |
| Completion-rendering red | `CHAT_TEMPLATE_FAILED: 2 problem(s)` | 1 |
| Green chat-template | `CHAT_TEMPLATE_OK: 6 families; thinking strip/caps, role profiles, prefixes and native control tokens` | 0 |
| Notes truncation | `NOTES_TRUNCATION_OK: a cut answer says so on the page, the single pass and the reduce each retry once at double the budget, the cap scales with the meeting, the wire finish reasons are read` | 0 |
| Model roles | `MODEL_ROLES_OK: fallback, routing, call paths, discovery and tool-call bridging verified` | 0 |
| Usage log | `USAGE_LOG_OK: 26 cases` | 0 |
| Store isolation | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` | 0 |
| LLM prefix cache, exactly once | `LLM_PREFIX_CACHE_OK: reused 646/666 tokens, prefill 1.33s → 0.18s; stable prompt front 90% (was 73% before P1-28)` | 0 |

Actual test process IDs: original red 53989; completion red 67152; final six 71799, 71811, 71823, 71835, 71847, 71873. Store-isolation also ran its scripted production tool-loop and memory checks successfully. No model evaluation was requested or run.

## Limits

Serial-root owns model evaluation. Native MiniCPM forced-cap generation, live notes quality/cut-short rates, dictation tail and voice latency still need live acceptance evidence. Vocabulary round-trips and the production output-boundary fixture do not establish those outcomes. The prefix-cache live portion uses a private S1-mini runtime; the added MiniCPM role cases verify prompt-prefix invariants, not live MiniCPM cache timing. The proposal-completion route requires the reserved-provider handoff above. No model/default promotion or broader readiness is claimed.

## Commits

- `a0b197f46c147fb9b21f0061a1a767a9a8bc5dd2` — `fix: bound and hide MiniCPM thinking per request` (six source files, validated above).
- This report is committed separately as `docs: record thinking verification and provider handoff` on the same branch.

## Files changed

- Sources/NextNotes/Formatting/LLM/ChatTemplate.swift
- Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift
- Sources/NextNotes/Formatting/LLM/ChatTemplateSelfTest.swift
- Sources/NextNotes/Formatting/AppLLMCleanupFormatter.swift
- Sources/NextNotes/Meetings/NotesGenerator.swift
- Sources/NextNotes/Agent/Planner/AgentPlannerBackend.swift
- RESULT.md

Neither reserved provider file nor any main-checkout working file, other worktree, installed app or owner store was edited. No install, push or quick evaluation was performed. The own stash used for red was popped; the pre-existing unrelated stash was retained. Own scratch and 27 PID-scoped test temporary folders/logs were removed; self-cleaning fixtures remove their own UUID directories. Own temporary regression scripts, fragments and build/test logs were also removed after their evidence was recorded here. `RESULT-previous.md` remains untouched and untracked. `git diff --check` passed.
