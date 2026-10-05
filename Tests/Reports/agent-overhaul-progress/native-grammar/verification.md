# Native grammar channel verification

Confirmed original: extension-only grammar overloads on any LLMProvider dropped the constraint; actual planner/existential forwarding failed six checks, and the calendar completion used XML outside the requested grammar. The existing three overloads are now protocol requirements; Llama supplies the missing single-message witness.

Forwarding exposed b10621 rejecting finite repetitions at 2,000 and silently making larger maxima unbounded. The existing schema emitter preserves exact string/free-text limits with bounded alternatives and exact prefixes. Adjacent optional chunks were rejected during verification after excessive validator CPU; they are not shipped. Native parser plus empty/exact/over/escape/first-character boundary checks pass without cap or prompt changes.

Correctly pinned Qwen native-tools passes: unchanged five prompts 5/5 grammar-valid, 3/4 tool prompts call, greeting answers; actual calls-only probe passes. Original MiniCPM ordinary prompts remain 0/4 calls/red; its calls-only probe passes. No native quality/default promotion from that narrower proof. Cloud not invoked.

RED/fixed raw logs and patches: ~/Library/Caches/NextNotesBuild/integration/promise/native-tools-diagnostic/. Five related production/model-fit/model-roles/tool-review/store-isolation checks pass. Calls-only API is default-off and used by the separately verified bounded continuation.
