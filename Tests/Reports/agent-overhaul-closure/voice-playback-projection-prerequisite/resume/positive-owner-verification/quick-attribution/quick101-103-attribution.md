# Quick101–103 C04 attribution

Quick103 is 2/10 in 87.5s against the unchanged 9/10 bar; quick101 was 3/10 in 84.8s. C04 is the only changed verdict: PASS 21.4s → UNGROUNDED 35.8s. A02 remains UNGROUNDED, with only navigate executed this time; the previous navigate+snapshot also lacked click.

C04 executed search_email(maxResults=5) and get_agenda(tomorrow) in both runs. The first recorded planner decision difference is round two, after the email result: 101 requests agenda (42 completion tokens), 103 proposes no tool (246 completion tokens). 103 later requests agenda in round three and writes final prose in round four. The exported JSONL retains only the last raw completion, so the exact round-two prose and reason for its continuation cannot be asserted.

The available final raw completion creates Jane Doe, Support Team and Marketing Dept email rows absent from the owned fixture, then stops at an empty tomorrow-events heading. The fixture contains Marcus pricing, Ana deck, Cyril dinner and related messages; tomorrow includes Dentist, Design sync and dinner. Both unchanged grounding groups are absent from the final reply. The existing grader correctly reports UNGROUNDED. The final usage records finish=stop and 150 tokens, not a timeout or recorded token-limit cutoff.

The complete compiler maps are 1046→1047 entries. They change four playback producers/consumers, registry and the new conductor; RealtimeAgent, its tool loop, Planner backend, eval runner/cases/fixtures/grader are identical. This establishes source controls, not identical model input/runtime state. First-round and second-round token totals matching do not establish byte-identical prompts; divergent rounds subsequently change the final prompt and user length.

The typed path really does access shared Synth: handle calls finishFirstTTSTrace, which clears callbacks on AgentSpeechSynthesizer.shared, so construction can install the new resume callback. Tracker receive presents text before the speech guard. allowSpeech=false excludes its begin/append speech branch, and typed finish excludes final speak and Delivery.bind. Shared cancel/interrupt/session-stop paths still exist and can call noteUserSpeech→stopOutput→Synth.stop; their existence must not be confused with measured execution. No current resume receipt publication is recorded in this typed report, but missing instrumentation is not proof that all shared code was unexecuted.

The first available faulty producer result is the final generated answer; why the provider/plan diverged remains unresolved. Neither runtime variance nor attribution to the new playback code is established. Preserve C04 and A02 as open failures; no retry, prompt patch, output scrub, grade change or quality-bar relaxation follows from this audit. Core/full/owner gates are outside this report.

This agent performed read-only artifact/source inspection and wrote this additive report only.
