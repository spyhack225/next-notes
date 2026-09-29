# Needle 3 direct execution with Agent base models — 2026-09-29

> Historical measurement: these runs used the first benchmark prototype. Afterward, the
> fixed confidence cutoff and eight-tool truncation of a matched intent class were removed,
> and the ad-hoc UTC date fact was dropped to follow `AGENTS.md`. The table has **not** been
> rerun on that revised path. P1-31 in the Agent overhaul roadmap requires a new paired
> comparison before any default-path decision.

## Question and method

Would Cactus Needle 3 as a fast first tool caller improve the Agent when the base LLM
answers after the tool? This is **not** a Choice/Score/Noul experiment: the installed
Needle 3 returns `function_calls`, `confidence`, and `validation` fields. Choice/Score/Noul
belong to a different family of typed-decision models.

`--selftest-toolloop-live --needle-first` is an opt-in diagnostic only. On a planned
tool turn with a selected intent class, it offers Needle up to eight tools from that
turn's `AgentCapabilityManifest.selected`, limited to matched classes. It drops
arguments Needle marked ungrounded and rejects negated or low-confidence calls.
Needle's first call goes through the existing `ToolStepRunner`, which enforces the
manifest, argument grounding, execution policy, and approval boundary. The base LLM
then answers from the verified result. Compound requests resume the normal planner.
If Needle abstains, the base planner runs normally. The diagnostic does not run in
ordinary app use.

The eight-tool cap is another limit of this diagnostic. An abstention can mean the
right tool was excluded by the shortlist, so those cases are evidence about this
**combination**, not proof that Needle cannot recognize the request with another
catalogue. Some Agent turns use an existing shortcut before the planned tool loop;
the Needle-first flag does not replace those paths.

The nine selected cases were fixed before comparing models: M02, K03, R03, Y01, Y02,
F03, A04, A02, N04. Seven were missed-tool cases for Qwen3-4B; A02 is a compound
browser control and N04 a no-tool control. The base column is the same nine rows from
each model's earlier full 40-case run. All results are single runs. The times are
sum of case wall times, excluding the one-time model warm-up, and were measured at
different system loads. They are directional only.

| Base LLM | Base | Needle direct | Base time | Needle time | Raw Needle run |
|---|---:|---:|---:|---:|---|
| Qwen3-4B-Instruct-2507 | 2/9 | **4/9** | 48.7 s | 40.9 s | [report](2026-09-29-needle-exec-qwen3-targeted-v2.md) |
| Gemma 4 E4B | 2/9 | **3/9** | 128.9 s | 46.9 s | [report](2026-09-29-needle-exec-gemma4-targeted-final.md) |
| Qwen3.5-4B | 2/9 | **4/9** | 180.1 s | 168.1 s | [report](2026-09-29-needle-exec-qwen35-targeted-final.md) |
| MiniCPM5-2B | 2/9 | **4/9** | 28.6 s | 25.3 s | [report](2026-09-29-needle-exec-minicpm5-targeted.md) |
| Ling 3.0 Flash Sante free | invalid baseline | unavailable | — | — | Keychain credential lookup timed out before a case ran |

The nine-case threshold printed by the self-test is 8/9, scaled from the full
25/30 release bar. **Every local Needle run failed that gate.** None is a full
30-case score, and the improvements must not be added to the earlier 30-case totals.

## What changed, and what still failed

- Needle's `search_email` call turned M02 green for all four local LLMs. Its
  `computer.active_app` call turned A04 green for Qwen3-4B, Gemma, and MiniCPM5.
- Needle chose `memory.recall` for Y01, which asked to **save** a fact. Gemma's
  baseline Y01 was green and became red. Some final replies claimed the fact had
  been saved even though the log shows only recall. Confidence was 0.46–0.50 on
  these wrong calls, so the existing 0.3 filter does not distinguish them.
- Needle abstained on several R03 and Y02 turns. The base model then fell back
  to its usual planner and often refused or answered without reading. The direct
  path did not solve those cases. A [roster diagnostic](2026-09-29-needle-exec-roster-diagnostic.md)
  confirmed that `schedule.list` was offered for R03 and `memory.recall` for Y02;
  these abstentions were not caused by the eight-tool cap.
- F03 needs a file search followed by email or an address question. Needle
  often supplied the file search, but no model completed the second step. The
  existing `likelyMultiStep` test missed requests joined by “and”; it now counts
  two distinct action verbs joined by “and” while leaving a direct app/page
  shortcut alone. F03 remains red even after that correction.
- The first version offered unrelated core tools to Needle and chose
  `computer.open_app` for a YouTube request. The final diagnostic limits the
  shortlist to the matched manifest classes. The benchmark also incorrectly
  marked navigation plus a snapshot as success for “play the video”; the A02
  grader now requires a click on the named video or direct navigation to it.
  Gemma's final A02 is correctly **UNGROUNDED** because it stopped to ask before
  clicking; Qwen3-4B and Qwen3.5-4B completed the click.
- Qwen3.5-4B's R03 final reply was graded FABRICATED without a tool call. A
  successful first call does not remove the base model's answer-grounding risk.

## Decision

Keep direct Needle execution **benchmark-only**. It is faster and improves a
few one-step reads in this targeted sample, but wrong tool selection, abstentions,
and unfinished compound work remain. Before using it for normal Agent turns,
the release gate needs the fixed 10-case quick run and two full 30-case runs on
each proposed base model, plus a save-versus-recall negative and a browser
follow-through check. The app should continue to use its one manifest and one
`ToolStepRunner`; Needle should never call a separate executor.

MiniCPM5's Q4_K_M file was downloaded from OpenBMB, verified as 1,561,318,368
bytes with SHA-256 `ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`,
and removed after the run. Free disk returned to about 4.1 GiB. Ling was not
graded because the process could not read the saved OpenRouter credential in the
15-second lookup window; the earlier full Ling run was also invalid after HTTP 429.

Verification: `make build`, `--selftest-model-roles`,
`--selftest-toolloop-live-grader`, `--selftest-capability-manifest`,
`--selftest-agent-answers`, and `git diff --check` passed. The fixed ten-case
quick gate without Needle ran after the conjunction fix and remained red at
[7/10](2026-09-29-after-conjunction-fix-qwen3-quick.md), versus 8/10 for the
same rows in the earlier full base run. Its additional failure was M04, a
draft-email turn with no conjunction, so this single run does not show a
conjunction-specific regression; it does confirm the Agent is below the 9/10
quick gate.
