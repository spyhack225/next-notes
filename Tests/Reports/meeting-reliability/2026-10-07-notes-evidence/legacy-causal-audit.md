# Legacy notes: first-loss localization remains open

Read-only audit during the fourth shared release build. No source edits, compiler calls, model loads or native generations were performed. Normal production remains the legacy generator; source-ID selection stays an explicitly requested SelfTest experiment. This report does not establish a new repaired producer or promote a strategy/model.

## What is confirmed

The retained legacy 8,192-window Mini replay contains three maps and one reduce, with no collapse or dropped groups. The first two maps each exhaust their 600-token allowance; the third stops at 462 tokens. The reduce receives a 2,229-token rendered prompt and stops at 198 generated tokens. The unchanged body and four-pass generation now disclose incomplete extraction through `incompleteFacts`; the disclosure does not recover facts. The original and disclosure replay timings are 159.56 and 125.38 seconds respectively; their matching output/pass counts do not show a semantic improvement or establish a reliable speed difference.

The whole-meeting Qwen3.5 replay reports 14,516 actual prompt tokens, 340 completion tokens, `finishReason=stop`, and `truncated=false`. It uses one generation, not map/collapse/reduce. The roughly 40-minute meeting permits approximately 1,600 output tokens before window clamping, and the 32,768-token reader has sufficient space. Its unsupported deadline and missing distinctions cannot be explained by the two legacy map limits. The retained Mini whole replay is similarly thin at 175 generated tokens; its older log lacks the detailed usage row, so do not invent that row's finish/counter evidence.

The owner gold review already demonstrates omissions and incorrect attribution in these final notes. The private original legacy map completions were not retained, so the exact first stage where each material fact or attribution is lost is **not** established. The newer source-index traces demonstrate refusal/underselection in that separate experimental contract; they are not raw evidence of what the legacy maps produced.

## Mechanical boundaries inspected

| Boundary | Actual implementation | Finding for this incident |
| --- | --- | --- |
| Transcript preparation | `NotesGenerator.notes` submits `segments.plainText(speakerNames:)`; meeting-note filtering excludes agent commands. | The earlier ordinary-speech wake classification defect is documented/fixed separately. The private gold still contains material evidence in the filtered input. Do not attribute all remaining loss to those exclusions. |
| Whole/map decision | Real provider token count for transcript and brief, counted prompt scaffolding, reserved output space. | No confirmed silent prefix/suffix clipping. Whole input is appended completely to the user message. |
| Native window | `NotesModelRuntime.completeWhileScheduled` tokenizes the full rendered prompt and rejects prompt + output allowance + 256 headroom above the context. | Overflow is an explicit refusal, not a successful silently shortened prompt. The retained Qwen whole generation was accepted. |
| Prefix cache/prefill | `preparePrefix` retains an exact cached prefix, then decodes the entire remaining prompt tail; context grows as needed. | Cache prefix removal concerns retained KV state, not removal of the submitted transcript. No demonstrated cache/window defect here. |
| Legacy map chunks | Original segment-order loop with measured characters/token ratio, segment boundaries, and every segment assigned once. | Approximate sizing can require overflow fallback in other inputs; no reported overflow or dropped input in this retained three-map run. |
| Map compression | Free attributed fact bullets, shared reduce-space allocation, 600-token ceiling. | Two actual length stops are a confirmed incomplete-output boundary. Their semantic consequences need raw pass evidence; completion alone does not show which facts were omitted or altered. |
| Collapse/group/drop | Adjacent, ordered grouping, bounded rounds and explicit last-resort dropped-part notice. | No collapse/drop occurred in the original legacy replay; those branches cannot explain its attribution error. |
| Reduce/whole contract | Six headings, short Summary, labels and no inference; accepts model-generated prose. | The code does not prove fact coverage or preserve individual experience distinctions semantically. The final producer output fails those contracts; map-vs-reduce ownership of individual errors remains open. |
| Decode termination | Ends at EOG/turn boundary or output allowance. | A `stop` with ample allowance is model termination, not a request to decode fewer tokens. Increasing an unused output allowance alone has no demonstrated remedy. |
| Markdown assembly | `tidy` keeps ordinary section text and preamble; no-context rule empties Related context only. | No inspected mechanical transformation transfers experience between speakers or deletes ordinary Key points/Action items text. Missing headings can receive `_None._`; this does not establish semantic absence. The independent warning paragraph separator fix is covered by its own before/after regression. |

The original map prompt prioritizes decisions, commitments, dates, numbers, names and unanswered questions, and requests removal of filler/repetition. There is no explicit exhaustive material-topic or qualification/tense coverage obligation. The final prompt asks for a short Summary and prohibits inferred owners/dates. Underselection, compression emphasis and semantic misclassification are plausible explanations, not experimentally isolated causes. Another broad prompt rewrite would change the symptom without locating the first broken pass.

## One narrowly falsifiable experiment

Run **one unchanged legacy Mini/8,192 replay** on the same guarded copied owner fixture when root owns the native test slot. Use the existing diagnostic provider wrapper to privately retain each call's exact system/user strings, requested output allowance, raw completion, actual usage and finish metadata. Forward all arguments unchanged to the installed provider. There are the same three maps and one reduce, with no new checker generation, retry, model/default promotion, queue or store. This is an observational replay, not a candidate fix.

Before running, pin the filtered transcript, speaker map, brief, generator/prompts, installed model and requested window. Compare the captured map inputs against the private source-linked gold, then classify every gold target at the first failing boundary:

1. Missing from submitted map input: investigate filtering/chunk representation.
2. Present in input but omitted or wrongly attributed in raw map: responsible map output contract/model compression. Distinguish a chronological cutoff from earlier underselection; an allowance exhaustion alone is insufficient to infer which one occurred.
3. Correctly retained in raw map but omitted or altered in raw reduce: responsible reduce contract/model.
4. Correct in raw reduce but altered in assembled notes: responsible formatter/assembly.

Evaluate the full private gold, not valid IDs, output cardinality or generation success: individual experience/qualification attribution; material topics and answered-question context; past activities versus future follow-up; illustrative quantities versus commitments; no invented owner/deadline; readable final notes. The transcript remains a text gold, not independently labeled audio accuracy evidence. Keep the raw material private and report only stage/category verdicts and cost counters publicly.

If the unchanged run's final body differs because native generation is nondeterministic, analyze its own captured pipeline and disclose that divergence rather than claiming it reproduces the retained original. If the stage capture cannot be enabled without a shared build, stage it only after the current compiler joins and root authorizes source ownership. Do not run another selector or promote an output strategy before this localization and its original factual regressions succeed.

## Evidence references

- Owner-private retained `replays/window8192.log`, `window8192-fixed.log`, `whole.log`, `qwen35.log`, and the source-linked review/reference notes under the owner Diagnostics meeting-quality review. Payloads are intentionally not copied here.
- [Third source-index native failure](third-native-selection-review.md): separate selection contract, observed refusal/underselection and additional prefill cost.
- [Production legacy parity](legacy-parity/README.md): corrected actual-source fixture boundary, retained initial failures, default legacy comparison PASS.
- [Paragraph separator regression](paragraph-separator.md): independent assembly repair, not a factuality claim.
- Producer source: `Sources/NextNotes/Meetings/NotesGenerator.swift`, `NotesPrompts.swift`; native boundary: `Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift`.
