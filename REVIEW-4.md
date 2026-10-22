# Round 4: claude2/no-apple

**Verdict: APPROVE WITH FIXES.** The current-reply failure regression is fixed at its owner. The retained RED36/fixed0 and census6-missed/29-to-29/29 results are supported within their stated scopes. The census still misses ordinary command forms, so round-3 finding 2 is only partially fixed. Settings and peer integration remain open and honestly disclosed.

Reviewed `62da58a3..8097108a`, specifically `f6265ca2` and `8097108a`. Read BRIEF-4, RULES-2, REVIEW-3, subject AGENTS, RESULT's round-4 section, the committed source/fixture/scanner diffs and surrounding consumers, and retained round4 evidence. No builds, tests, mutations, model loads, application launches, GUI actions, owner-store reads or source changes. Only this requested review report was written; relay coordination was explicitly requested. File:line references use the no-apple head `8097108a`.

## Findings

1. **P2 — Simple shell syntax and wrappers still bypass the census.** `Tests/Reports/no-apple/check-sink.py:10`, `:11`, `:12`, `:54`; mutation coverage at `Tests/Reports/no-apple/review-fixes/test-census.py:11`.

   Ordinary Swift/C receives only the first four patterns. The new command-string expression requires `say` immediately after the opening quote, optionally after `exec`, or after an operator followed by at least one whitespace character. It does not handle initial whitespace or `env` options. Consequently these ordinary source forms escape all applicable patterns:

   ```c
   system(" say Hello");
   popen("env -i say Hello", "r");
   system("printf Hello|say");
   ```

   A Swift Process invoking `/bin/sh` with arguments `["-c", "env -i say Hello"]` escapes for the same reason. None requires splitting a forbidden name or disguising an executable.

   Scripts get additional patterns, but `printf Hello | env -i say` still escapes: the command-position pattern sees `env`, and the final pattern requires an argument after `say`. A direct no-space heredoc also escapes because `<` is absent from the allowed command terminators:

   ```sh
   say<<EOF
   Hello
   EOF
   ```

   These are source-derived counterexamples, not reviewer-run mutations. No shipping instance of these sinks was found in the reviewed delta. Extend the same mutation fixture for whitespace/operator adjacency, bounded shell wrappers/options and heredoc redirection, and keep the exit1 plus FAILED-marker rule. This does not require defending against arbitrary obfuscation. The retained 29/29 result proves the included cases; it does not establish that these simple executable forms are covered.

## Current-reply settlement judgment

**Round-3 finding 1 is fixed.** `AgentSpeechSynthesizer.swift:753` checks the current playback token, stopped state and current clause text before settlement. At `:759` it delegates only the selected-voice latch to `noteSelectedVoiceFailure`; that method still checks the complete engine/selection/preparation request at `:171`. There is no intervening await. Changing the selection or calling cached same-engine preparation cannot discard a failure belonging to the still-current output, and cannot make that failure latch the new/recovered selected voice.

The admitted failure retains `outputAvailability = .failed`, disables speech for that reply, and runs the existing stop owner without advancing the output generation (`:760`). The stop clears clause/token/queue/pause/resume state and reports rendered partial versus unheard queued clauses through `interruptCurrentClause` (`:768`). `noteOutputFinished` releases the audio speaking state. The new admission at `:435` lets subsequent clauses in that same failed stream receive enqueued/unheard facts without reaching the backing. Explicit stop restores the blocking condition and advances the generation (`:501`); the audio session's append/finalize checks reject old-generation streams (`RealtimeAudioSession.swift:227`, `:237`). A new reply chooses its route through the existing preparation owner, with no automatic replay or voice switch.

An OLD reply failure still cannot settle a new reply: tokens increase at each submission, replacement changes the token, and stop clears it. Duplicate failure/completion callbacks after settlement fail the current-token/clause/stopped checks. OLD file failures retain the separate captured request and guarded latch in `LongFormRenderer.swift:433`, `:442`; this round does not remove that fence. I found no newly introduced wrong-voice latch or stale-reply settlement.

The four new cases at `VoiceFailureEpochSelfTest.swift:71` cover both engine selections crossed with actual Settings selection changes and explicit cached preparation. They use the real audio session, streaming buffer, synth owner and new file-consumer entry, substituting external playback/generation. They check invalid token/text, a rendered head, unheard queue, later streamed text, availability, no extra submissions, late callbacks and explicit stop. The real Pocket failure sends empty text after stopping (`PocketAgentVoice.swift:696`); Kokoro sends its clause text after stopping (`KokoroAgentVoice.swift:287`). Both callback forms remain admitted by the producer.

One qualification on “double settlement”: `finishStream` still calls the lifecycle observer again at EOF for a non-speaking reply (`AgentSpeechSynthesizer.swift:479`), after failure's stop already called it. That behavior predates this delta. The observer is a state notification, and the session guards terminal publication with its announced/open state (`RealtimeAudioSession.swift:506`); `noteOutputFinished` is guarded by `isSpeaking` (`:553`). I found no duplicate interrupted clause receipts or new terminal-settlement regression. The fixture's exact release-count assertion (`VoiceFailureEpochSelfTest.swift:125`) is before finalize at `:131`, so it proves one notification at the failure boundary, not exactly one notification over the whole stream. A late old failure during an actively playing replacement reply is source-fenced but is not a new retained round-4 test case.

## Census assessment, ranked by simplicity

All judgments below come from reading the expressions and file-selection rules; I did not execute these forms.

| Form | Judgment |
| --- | --- |
| Swift `/bin/sh -c "say Hello"`, C `system("say Hello")`, `popen("say Hello", "r")` | Caught; retained new mutations support these exact forms. Round-3's exact command-string escape is fixed. |
| `exec say` with piped stdin, bare `exec say`, bare `say` | Caught; retained mutations support these exact forms. Round-3's exact stdin-exec escape is fixed. |
| Conventional `osascript -e 'say "Hello"'` | Caught by the quoted command-string expression. Not a retained mutation. |
| Direct `/usr/bin/say`, including a Python subprocess array using that path; subprocess array with literal `"say"` | Caught by absolute-path/quoted-token patterns. These have retained counterparts. |
| `say <<EOF` followed by text and EOF | Caught because whitespace follows `say`; not a retained heredoc mutation. |
| Initial whitespace in a Swift/C shell string, no-space pipe in a Swift/C shell string | **Escapes. Highest-priority extension:** routine formatting only. Examples in finding 1. |
| `env -i say Hello` in a Swift/C shell string; stdin-only `env -i say` in a script or Python shell subprocess | **Escapes. Ordinary wrapper:** no forbidden name is disguised. Python example: `subprocess.run("env -i say", shell=True, input="Hello", text=True)`. Script `env -i say Hello` is caught by the additional argument pattern; arrays with literal `"say"` are caught. |
| `say<<EOF` | **Escapes. Ordinary redirection syntax:** one space changes detection. |
| `NSClassFromString("NSSpeech" + "Synthesizer")` | **Escapes. Lower priority:** the scanner never sees the complete forbidden class name. This deliberately constructed name is beyond the simple literal-command fixes required above. Do not claim obfuscation resistance, and do not require a general string evaluator for this review. |

The six added allowances are exact existing conversational/prompt/UI lines with reasons and occurrence bounds. They grant no file-wide exception. The changed operation check at `check-sink.py:58` restricts that extra check to files with existing operation allowances; the existing unexpected-operation mutations remain included. I found no newly exempted synthesis operation or weakened mutation success criterion.

## Retained evidence

- `round4/producer-red-selftest.log:42` ends `VOICE_POLICY_REVIEW_FAILED: 36 assertions`, with nine failed consequences for each of the four cases. `producer-green-selftest.log:6` ends `VOICE_POLICY_REVIEW_OK`. Both preserve the four 17-assertion case markers and the separate native PCM companion's receipts2/callback observations206/muted=true. This is production-owner/consumer evidence with external voice work substituted, not native Pocket/Kokoro audio proof.
- `census-red.log` records six undetected cases out of 29 and `VOICE_CENSUS_MUTATIONS_FAILED`; `census-green.log` records none out of 29 and `VOICE_CENSUS_MUTATIONS_OK`. `census-source-final.log` records forbidden0/exceptions30/files908 and `VOICE_SINK_SOURCE_OK`. The required marker plus exit1 prevents a scanner crash from counting as a detected mutation.
- Red/green pins record dirty snapshots based on `62da58a3`, not binaries built from the final commit IDs. Their fixture hashes agree with pre-run/invariance records; the source patches show only the synth producer changing between the two Sources snapshots. The retained apply script matches the reviewed repair. Final-source equality is recorded in fixture-invariance. I inspected these records, but did not independently recompute every source hash or load/rebuild either binary.
- Build logs retain completed debug builds of 283.62s and 23.19s. `checks.json`, `slot.log` and cleanup agree on 18/19 focused flags passing: 11/12 requested roots plus the four receipt companions, authority63, residency and scheduler. Settings' raw assertion log ends OK, but `checks.json:94` records exit -11 and cleanup records batch exit1. The batch explicitly checks both process exit and marker. Settings remains a failed process, with no voice-removal causality claim.
- Delivery13 and duplex2 diagnostics remain in raw logs. Store isolation's outer 21-files/0-defaults OK coexists with 18 browser failures and `TOOLLOOP_PRODUCTION_FAILED` in its CLI log. Diagnostic-comparison records all six normalized streams equal to round2. RESULT and PERFORMANCE-STANDARDS disclose these inherited scopes. No assertion, performance bar or quality threshold is removed or loosened by the reviewed source/fixture delta.

## Could not verify

The newly identified census escapes through executed mutations; native Pocket/Kokoro failure/playback/quality; production positive resume receipts; real first-launch/download/offline Settings recovery; Settings crash cause; actual device duplex, release latency or reference-machine performance; combined Settings/ACK/Mini compilation and interaction; cleanup/process invariance outside retained author records; final binary reproducibility. Settings and peer counter/PCM integration remain integration-owned. The shared task-store prerequisite is unchanged. No quality/default, phase or broader Agent readiness is promoted.
