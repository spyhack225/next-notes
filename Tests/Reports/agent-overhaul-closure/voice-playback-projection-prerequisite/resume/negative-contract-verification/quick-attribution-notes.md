# Fixed quick gate remains open

Actual fixed app101 Gemma 4 E4B quick set is FAILED3/10 against unchanged9/10, 84.8s. Prior app99 was FAILED3/10,147.9s. The same F03 no-tool reply remains MISSED_TOOL; it is not a new failure.

C04 changes TIMEOUT38.5s→PASS21.4s. A02 changes PASS21.5s→UNGROUNDED14.4s. Both A02 runs perform browser.navigate and browser.snapshot; the first divergent planner pass then proposed/executed browser.click on99 (prompt1504/completion96) but returned prose with no tool on101 (prompt1504/completion22). The101 final answer says it will click, without doing so. The unchanged grader retains the failure.

Actual ToolLoopLiveEval dispatches handle(source:.text), which passes allowSpeech=false and voice=false to the planned model loop. The three changed resume producers are shadow voice/capture playback transitions; these are not the typed case's model decision producer. No typed prompt/provider/parser/native context/grader source changed in the 1046-entry original/fixed comparison. This narrows attribution but establishes neither model-runtime variation as the cause nor resolution of the prior timeout. No prompt/output sanitization, timeout extension, grader change or model/default promotion was made. The browser model failure and broader quality gate remain open.
