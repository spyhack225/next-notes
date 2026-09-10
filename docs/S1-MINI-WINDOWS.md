# S1-mini on Windows

## Recommendation

Use **S1-mini by Superwhisper** as an optional local cleanup engine after Parakeet and before
Next Notes' deterministic dictionary correction pass:

```text
microphone -> Parakeet ASR -> S1-mini cleanup -> dictionary corrections -> SendInput
```

It is a good fit for transcript cleanup, but not for Command Mode. The model card explicitly
describes it as an English-only text normalizer that does not follow general instructions.
Command Mode still needs a general instruction-following model or a remote provider.

Do not add the weights to this repository. The recommended Q4_K_M GGUF is 462 MiB (about
484 MB in decimal units) and should be a pinned, checksummed, user-initiated download with
progress, cancellation, and license display. The Windows app has not yet been exercised with
a real microphone, physical hotkey, or foreground text injection, so local cleanup should not
be described as working until it also receives a real-hardware pass.

## Runtime shape

The official GGUF build supports llama.cpp on Windows. A production integration should embed
llama.cpp (directly or through maintained .NET bindings) behind a platform-neutral formatter
interface in `NextNotes.Core`/`NextNotes.Speech`; do not put orchestration or retries in
`NextNotes.Platform.Windows`. A command-line or localhost-server prototype is useful for
measuring latency and memory, but it should not be the final shipping architecture.

The model's required request format is load-bearing:

- Use the exact system prompt published in the model card.
- Prefix every transcript with its exact Styling/Structure/Context control line.
- Disable Qwen3 thinking through the chat template's `enable_thinking=false` behavior.
- Use greedy decoding (`temperature: 0`).
- Keep inputs around 1,000 tokens or chunk longer transcripts.
- Treat an empty result as valid for filler/noise-only input.

## Product controls

S1-mini v1 exposes four styling values: `casual`, `semi-casual`, `semi-formal`, and `formal`.
It does **not** expose a distinct `balanced` value. If Next Notes presents a five-position
slider, “balanced” can only alias `semi-formal`; it would not be a fifth model behavior. Four
honest presets are preferable until a model revision adds another trained value.

`Structure` accepts `prose` or `lists`; list mode conservatively emits Markdown bullets for
clear enumerations of at least three items. `Context` accepts `general` or `email`; email mode
formats greeting, body, and sign-off blocks. S1-mini also resolves filler, false starts,
spoken self-corrections, punctuation, casing, numbers, dates, currency, and email addresses.

Next Notes' existing correction dictionary must remain the final pass. S1-mini makes a
probabilistic cleanup; dictionary mappings are the cross-platform deterministic contract in
`shared/dictionary-test-vectors.json`.

## License and validation gates

The model card states Apache 2.0 plus an additional naming requirement: wherever the model is
used it must retain the exact name **“S1-mini by Superwhisper.”** Before redistribution,
include the required license/attribution notices and have the additional clause reviewed for
the intended distribution.

Before enabling it by default, measure:

1. Cold and warm latency on representative CPU-only Windows laptops.
2. Peak resident memory alongside Parakeet's roughly 2 GiB working set.
3. Exact-output regression cases for each styling, structure, and context value.
4. Failure behavior for missing/corrupt weights, cancellation, and long inputs.
5. The full real-hardware flow into Notepad after `--selftest`.

Primary references: the
[`superwhisper/s1-mini` model card](https://huggingface.co/superwhisper/s1-mini) and the
official [`superwhisper/s1-mini-GGUF` build](https://huggingface.co/superwhisper/s1-mini-GGUF).
