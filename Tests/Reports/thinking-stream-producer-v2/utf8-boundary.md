# Native UTF-8 boundary: source finding, not a split-byte preservation pass

`LlamaHelpers.piece` receives a token ID and vocabulary, calls `llama_token_to_piece` (including the existing two-pass buffer sizing), then returns:

```swift
return String(decoding: storage.prefix(Int(count)).map(UInt8.init(bitPattern:)), as: UTF8.self)
```

This return at line 59 decodes each token independently. The function has no state that could retain the first bytes of a scalar for the next token. `NotesModelRuntime.streamWhileScheduled` calls it once per sampled token (lines 1185–1186) and passes the resulting `String` to `ChatTemplateStreamOutput.consume` (line 1192). Thus this producer sees decoded strings, never raw byte fragments. The scripted stream seam takes `[String]` too.

If a native token ends partway through a multi-byte scalar, Swift's `String(decoding:as:)` repairs the ill-formed UTF-8 in that individual piece with U+FFFD; the next piece is decoded separately and cannot reconstruct the original scalar. For example, bytes F0 9F followed in the next token by 98 80 are not joined before decoding. The four joined bytes would encode 😀, but independent decoding produces replacement characters. This is an inherited upstream limitation, not caused or repaired by the EOF-tail change. This source finding does not claim to have observed a particular vocabulary producing those exact token boundaries.

V1/V2 Unicode cases preserve complete Swift strings/Characters (including emoji and decomposed accents) at the filter boundary. They do **not** demonstrate native token-byte scalar preservation. A raw-byte-fragment test cannot be passed to this producer's actual API; a future byte-decoder repair needs original/fixed native token evidence at `LlamaHelpers`, outside this bounded EOF fix.

No change was made to LlamaHelpers, tokenizer, sampler or role/default behavior.
