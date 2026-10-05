# Explicit model selection verification

Confirmed original: the native probe requested the existing Qwen3-4B file, but its next activeSpec adopted the saved MiniCPM default. Awaited select now resolves the existing startup-adoption flag before applying the explicit model (including nil/built-in); later UI selections remain supported.

Same pinned native probe now identifies the exact Qwen file and passes native-tools (5/5 grammar-valid, 3/4 tool prompts, calls-only positive). Its grammar channel prerequisites are a separate verified slice. Existing model-fit idle/deferred/built-in swap, model-roles and store-isolation checks pass. No model/default promotion or owner setting changed.

Original/fixed logs retained outside iCloud: ~/Library/Caches/NextNotesBuild/integration/promise/native-tools-diagnostic/native-qwen-{pinned,selection-fixed}.log. Related logs: ../f03-real-review/verified-*.log.
