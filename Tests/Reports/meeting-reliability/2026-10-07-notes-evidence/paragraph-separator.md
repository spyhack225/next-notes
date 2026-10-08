# Dropped-coverage paragraph assembly

The first actual native mapped replay ended with this sanitized structural marker (no meeting speech):

```markdown
## Related context
_None.__Part of this meeting could not be included in these notes (2 of 3 parts left out)._
```

Confirmed producer cause: `NotesGenerator` concatenates its final body and `NotesPrompts.truncatedLine` without a separator. On the no-context path, `NotesFormatter.emptySection` removes final whitespace, merging the empty marker and warning. This is a presentation/assembly bug; fixing it does not recover dropped facts or improve factual note coverage.

The cache-only patch adds `"\n\n"` at that existing assembly seam. The maintained longform test keeps its original stubborn-collapse case and adds the same generator/provider path with an empty brief, requiring positive drops and a separate paragraph after `_None._`.

Staged patch: `/Users/sergekadjo/Library/Caches/NextNotesBuild/meeting-notes-paragraph-stage-navoh0hl/pending-paragraph-separator.patch`. Canonical sources were not edited. No compiler or model was invoked because a peer native build was active. The regression has not been compiled or run; this is not a passing test verdict.

Source pins before/after staging:

| File | Frozen canonical SHA-256 | Proposed SHA-256 |
| --- | --- | --- |
| NotesGenerator.swift | `4c7b46b4df0aee656e6c866020a10ea4bd9c4cb7753fccd62047e4d1c4a3ea02` | `6637dfe2d16e779c7eb85bfb2f7c3c1ccacfad610d631fa47019a2c1b36dba11` |
| NotesLongformSelfTest.swift | `fe6d43dd011fdc1e0d26128642c5655cc6845a249c2fce07d366c8c8a63305b5` | `0d0116a26b266f3ee181d60ab58397a4e9e24fe5aa965754d5938dff5ec5fbce` |

Native acceptance remains the unchanged original owner replay, readable separate warning, and the relevant longform flag passing after the patch. Existing native note-quality failures remain open.

## Corrected root execution

The first no-context positive-drop fixture was impossible under the original fake budget and is superseded. Its failed attempt is retained. The same original stubborn+realbrief case now has the new separate-paragraph assertion: original actual source fails only that assertion, fixed and comprehensive source variants pass, and their exact legacy comparisons/production guards pass. See legacy-parity/corrected/summary.json. The original private no-context adjacency remains the actual product failure evidence; native third-release acceptance remains pending.
