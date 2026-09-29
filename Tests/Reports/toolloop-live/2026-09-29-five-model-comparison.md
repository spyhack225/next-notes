# Agent tool-loop benchmark review — 2026-09-29

## Scope and method

`--selftest-toolloop-live` sends 30 scored requests and 10 unscored owner-regression
requests through `RealtimeAgent.handle(_, source: .text)`. The Agent chooses tools and
answers with the named real model; the tool executor returns deterministic fixture data.
No real mail or calendar action runs. Each local model was forced explicitly at the same
32,768-token configured context and completed one full run on this Mac. The cloud run
used the named OpenRouter endpoint with a 32,768-token configured context; its provider
reported 30,720 usable tokens after its safety margin.

The bar in the roadmap is 25/30. These are tool-use and grounding results on a small
synthetic corpus, not a general writing, speech, or latency assessment. Times include
the Agent's route and tool loop. A single run per model does not measure variance.

| Model | Scored | Owner cases | Full elapsed | Median scored-case time | Validity |
|---|---:|---:|---:|---:|---|
| [Qwen3-4B-Instruct-2507](2026-09-29-compare-qwen3-4b.md) | **19/30** | **8/10** | 394.1 s | 6.5 s | Complete |
| [Gemma 4 E4B](2026-09-29-compare-gemma4-e4b.md) | 15/30 | 6/10 | 454.9 s | 5.3 s | Complete |
| [Qwen3.5-4B](2026-09-29-compare-qwen35-4b.md) | 14/30 | 6/10 | 889.2 s | 19.0 s | Complete |
| [MiniCPM5-2B](2026-09-29-compare-minicpm5-2b.md) | 11/30 | 6/10 | 176.5 s | 3.3 s | Complete |
| [Ling 3.0 Flash Sante free](2026-09-29-compare-ling-sante-free.md) | — | — | — | — | **Incomplete: OpenRouter HTTP 429** |

The Ling endpoint completed only the first seven scored cases before rate limiting:
six passed and one was ungrounded. The old runner incorrectly continued after provider
failures and printed 8/30 and 3/10; those numbers are **invalid** and excluded here.
The raw report is kept as diagnostic evidence and labelled invalid.

## What the runs show

- Qwen3-4B led the valid runs, yet missed seven required tool calls and is six cases
  short of the roadmap bar. It is the best measured local Agent candidate for now,
  not a passing release gate.
- Gemma 4 E4B was quick on many individual cases but refused six scored requests,
  often asking permission to do a read that should proceed directly.
- Qwen3.5-4B was the slowest and missed nine required tool calls. It frequently
  promised to perform a lookup without making the call.
- MiniCPM5-2B was the fastest. It refused six scored requests, missed seven tools,
  and chose a wrong tool twice. Its reminder cases asked follow-up questions rather
  than finishing the action.
- The cloud sample is too small and rate-limited to rank against the local models.

## Benchmark defects found and fixed

1. A question from the model could trigger the same scripted follow-up repeatedly.
   MiniCPM5 reproduced this: the first attempt kept appending `yes` and never yielded
   a usable score. The runner now sends at most one scripted follow-up. The corrected
   MiniCPM5 run completed 40 cases in 176.5 seconds; its R01 and R02 cases each took
   exactly two turns.
2. The grader could score the provider's “model didn't finish” failure sentence as a
   normal answer. The runner now detects failed model passes, stops an incomplete run,
   and suppresses its full score. It also stops after a case timeout so a cancelled
   model decode cannot compete with later cases.
3. Model-identity grading previously accepted generic words such as `model` or `free`,
   and a read tool could back a claim that the Agent sent something. Both checks are
   tighter, with grader regression cases.
4. Mail fixture clock times could be in the future during morning runs. The six
   messages now retain their relative ordering and age at any run time; the grader
   self-test checks an early-morning start.
5. The harness formerly used `forgetAllConversations()` between cases, which implies
   deletion. It now starts a fresh isolated conversation. Unknown `--only` IDs and
   report write failures fail explicitly. Markdown tool arguments remain on one row.
6. GGUF files in the app's Models folder and explicit OpenRouter IDs can be selected
   without changing the installed model manifest or the user's Agent choice. The
   runner rejects paths outside that folder, because the model runtime would silently
   resolve their filenames inside it. Cloud use still requires `--allow-cloud`.

`make build`, `--selftest-toolloop-live-grader`, and `git diff --check` passed after
the fixes. The four local full runs had zero provider errors and zero case timeouts.

## Next engineering work

Keep Qwen3-4B as the measured baseline and improve the Agent's tool decision path
against its seven missed-tool cases. Re-run the fixed 10-case quick gate after each
Agent change, then two full runs for the phase gate. Run Ling again when the free
endpoint permits a complete uninterrupted run; partial cases cannot be compared.

The MiniCPM5 file came from
[OpenBMB's GGUF repository](https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/tree/main).
Its 1,561,318,368-byte Q4_K_M file matched the repository's LFS SHA-256
`ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`.
It was run by file path, was not added to the user's model manifest, and was removed
afterward to restore disk headroom.
