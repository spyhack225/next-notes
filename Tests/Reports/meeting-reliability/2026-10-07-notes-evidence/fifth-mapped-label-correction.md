# Fifth mapped label: invalid comparison retained

The run originally named `fifth-legacy-mapped8192-mini` supplied `--notes-window 8192`. The App accepts `--notes-replay-window`; the supplied modifier was unrecognized, so `rawWindow` was nil and no ReaderWindow was constructed. This is a diagnostic invocation error, not evidence that an 8,192-token reader accepted the full input or that tokenizer sizing selected the wrong branch.

Actual trace and usage establish one `meeting.notes.single` call, 13,062 prompt tokens, 175 completion tokens and a 1,600-token allowance. Result reports mapReduce=false, chunks=1, collapse/drop=0 and structural incomplete=false. Root records 126.691 producer and 128.976 wall seconds. Treat it as a second whole-reader observation only. It provides no map/collapse/reduce localization or mapped acceptance.

Preserve the original private log/arguments, public metadata/usage/memory files and their original names. This receipt corrects interpretation rather than renaming history. The offline mapped-mode reviewer rejects its actual topology. A corrected `--notes-replay-window 8192` native replay is pending coordinated peer handoff; no new native run was performed for this correction.

Original metadata: [retained run](../2026-10-07-quality-loop/fifth-legacy-mapped8192-mini-metadata.json). Normal production prompts/defaults remain unchanged.
