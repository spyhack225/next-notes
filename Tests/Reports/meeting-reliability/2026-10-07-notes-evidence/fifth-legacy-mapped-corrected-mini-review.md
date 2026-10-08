# Corrected legacy mapped Mini: loss occurs in maps and final writer

The actual corrected `--notes-replay-window 8192` replay joins exactly three maps and one reduce. All 519 filtered source lines reach the corresponding map inputs byte for byte with their original speaker/time labels; renderer pins pass. All three raw map outputs enter the reduce input unchanged. The first five raw reduce sections survive formatting unchanged. No input/window clipping, grouping/collapse/drop or formatter deletion explains this run's material loss.

| Existing pass | Prompt tokens | Output / allowance | Finish |
| --- | ---: | ---: | --- |
| Map 1 | 6,251 | 600 / 600 | length |
| Map 2 | 6,040 | 600 / 600 | length |
| Map 3 | 722 | 462 / 600 | stop |
| Reduce | 2,229 | 198 / 1,600 | stop |

Workflow is 187.393 seconds; root reports 188.862 seconds wall. There are 1,860 generated tokens, no collapse/drop and an honest `incompleteFacts=true` disclosure. This is an alternate compression topology rather than the owner's original whole-reader flow. Its cost exceeds the observed fifth whole workflow of 89.266 seconds and the prior legacy mapped 159.558-second observation; neither comparison is a paired uncontended benchmark. No speed improvement is claimed.

Source-reviewed complete criteria first fail at maps in nine of the ten categories. The first two maps largely copy opening speech, greetings/backchannels, fragments and repetitions until their output limits; they do not condense the complete submitted part into substantive facts. Later material in each part is omitted. Some broad topics and partial experience/tool/quantity details survive, but these do not meet the complete distinctions. Candidate marker hits for follow-up and AI content locate unrelated earlier material and cannot pass the gold.

One material criterion, concrete coordination/iteration, survives map 3 with correct source ownership. The final writer then drops its concrete dependencies and artifacts, retaining only a vague process description. This criterion first fails at reduce. Reduce also replaces explicit source speaker labels with ambiguous singular references for retained personal experience and explanations. That is an exact-ownership contract failure; a specific transfer to the other diarized speaker is not established by this copied reply. No invented deadline is observed, while the future follow-up is absent. Private review also records unsupported entity resolution and readability limits separately from the ten coverage criteria.

Final complete coverage is 0/10; maps preserve 1/10 complete criteria. The independent source-reviewed annotations, exact hashes and private reasons are retained in Diagnostics. [Numeric review](fifth-legacy-mapped-corrected-mini-review.json) records first loss, attribution ambiguity and counters without owner speech. Lexical candidates, valid generation and the disclosure do not establish factual quality or audio truth.

The first demonstrated failing output boundaries are the external map and final-writer generations. Copying/filler plus a length cut is observed; the model's internal cause and the necessity of a larger cap remain unproven. Existing input and assembly machinery passes this audit. Two cache-only, explicit SelfTest prompt arms can test generic substantive compression and final material preservation separately through the counted producer seams. They remain untested hypotheses, with full private gold, attribution/tense/deadline/background negatives and cost/topology checks declared before inference. Normal production prompts and model defaults remain unchanged.
