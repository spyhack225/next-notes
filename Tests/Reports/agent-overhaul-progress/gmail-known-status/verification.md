# Carry already-fetched Gmail read status — 2026-10-06

The real Gmail metadata parser discarded labelIds before its numbered search result. Existing list/get JSON already supplies known Read/Unread; the five-line producer retains an optional Boolean and formats that known state. Missing/null/malformed labels remain unknown; valid empty labels means Read. Query, sender, count, ordering, number/date/subject/body policy are unchanged; no read body, model pass/store or inferred age/unread filter is added.

COMMON drives actual WorkspaceToolRunner→existing read-only fakeCLI list/getJSON→real parser/formatter using Marcus and empty-count arguments. Known Read pricing, Unread older contract and valid-empty Read controls fail three assertions on old producer; absence/null/string/mixed labels do not invent state. Isolated fake version/auth executable keeps --selftest-gws out of owner account/credential reads and refuses other commands. This is actual backing/formatter proof, not a LiveEval fixture/grader change. Original ambiguous “new” M02 native model output remains open because native eval replaces this external backing.

Raw original/fixed/fixed2 logs and binary results: ~/Library/Caches/NextNotesBuild/integration/c02-gmail-delivery/; reviewed packet at integration/m02-read-status-audit/gmail-metadata-packet/. No real-account, Mac-account result, latency/full/default or roadmap completion claim.

Exact tested combined artifact 312f7ea8ec60ebba3836bd5e7f648bf237256608b9545944011f1f6d30caa060: focused C02, isolated gws, full production toolloop, tool review, capability manifest, live grader and store isolation all exit0. Each subprocess joined before owned TMP removal. Scoped whitespace PASS.
