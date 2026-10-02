# Root-owned staging recipe (not executed by child)

Baseline HEAD `e6e5790bc215e3a5faf9f735173c3b4dae2efde2`; only seven ACP registration lines are added by `registration-HEAD-e6e5790.patch`. Foreign NextNotesApp hunks must stay outside this patch. Root may run `git apply --cached --check <patch>` then `git apply --cached <patch>` after verifying its index; do not stage the whole App file. This child performed no index operation.

Owned sources:
- `Sources/NextNotes/Agent/Backend/JSONRPCStdioClient.swift`: exact reviewed shared producer repair.
- `Sources/NextNotes/Agent/Backend/ACPStdioTerminationSelfTest.swift`: new isolated fixture, revised solely EOF text before original48.
- `Sources/NextNotes/NextNotesApp.swift`: only the seven-line wrapper, via the patch above.

Root owns commit and all subsequent source/build/native changes. Reports are under this `acp-review` directory. Both original prepared fixture/producer proposals and revised originals are retained; full raw build48/build49 logs, native log/stdout, bundle/source manifests, installed/cache binary metadata and root-brokered post48/post49 process inventories support the accepted bounded change. Denied build48 attempt and unrun44/45 must not be called native evidence.
