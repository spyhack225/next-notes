# Exact model-free participant coverage component probe commands

Prepared source-only on 2026-10-08. Root must independently admit and run each compilation sequentially; none has run. Canonical Sources/Resources remain unchanged. These commands compile only Foundation-backed, source-pinned walker/selector component fixtures. They load no ASR/model and perform no actual AX/browser/app/provider observation.

Cache root: `/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1`.

## Original, first

```sh
/usr/bin/xcrun swiftc -parse-as-library -swift-version 6 -O -module-cache-path '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/ModuleCache' '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/original-coverage-probe.swift' -o '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/original-coverage-probe'
```

After successful compilation, run this separately and retain stdout/stderr plus exit code:

```sh
'/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/original-coverage-probe'
```

Expected, not observed: exit1; `PARTICIPANT_COVERAGE_FAILED checks=11 failures=6 substituted-AX-boundary`. The six failures are child/depth/useful limit reporting, small-tree limits not observed (original coverage absent), and two landing URL refusals. The four exact output counts and room raw-read case should pass. An unexpected original pass invalidates the comparison; investigate it before claiming a fixed pass.

## Fixed, after the original result is retained

```sh
/usr/bin/xcrun swiftc -parse-as-library -swift-version 6 -O -module-cache-path '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/ModuleCache' '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/fixed-coverage-probe.swift' -o '/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/fixed-coverage-probe'
```

Run separately:

```sh
'/Users/sergekadjo/Library/Caches/NextNotesBuild/participant-coverage-source-50dee560aab1441c9af6e639c0754fc1/fixed-coverage-probe'
```

Expected, not observed: exit0; `PARTICIPANT_COVERAGE_OK checks=11 failures=0 substituted-AX-boundary`.

## Source and patch pins

| Input | SHA256 |
| --- | --- |
| Original component fixture | `752a7dee43e53158f2a2263b85d6d2eff0c368bfbb196bea8d5722ed505149c4` |
| Fixed component fixture | `b95e2637a25ea67bcaca2c521a4aeba7c112eb6d09c45db9565477c4d21f16c2` |
| Canonical AX before image | `c5de8d7de9b67d27a133aa266687b8faf3bd89972d414356e9685f2ad31e15a4` |
| Cache-staged AX after image | `a03d3c85aa1352e7cdda159ac70aa358450abb8bd23bdebed424af382eaae9b6` |
| Canonical diagnostic before image | `c745c8d8ea126765301c33adb471130bb0d3b515313d9db26b25dc153fbe84b4` |
| Cache-staged diagnostic after image | `9a165d8adc88b303a451ddb4171b526a9353b6f51dcf8c02d24a0dedf09c8673` |
| Surgical staged patch | `3588266c146534c532953d9e0064368e3167652973538beb590e432783796be9` |

The exact walker bodies and Meet selectors appear byte-for-byte in their respective source-pinned fixtures. Both runners/assertions are identical. The current helpers isUseful/shortRole are also copied exactly. The fake public Node/attribute reader replaces the OS attribute boundary; the scoped dictionary replaces the native snapshot cache. Original traversal metadata is honestly represented as absent (nil), not fabricated false fields. Snapshot.captureFixture is a fixture adapter, not the real process capture/private JSON writer. Original fixture includes the new passive coverage value type solely so both versions can consume the same unchanged assertions; its old walker never supplies that type.

## Exact scope of the eleven assertions

- Wide41 direct children:40 retained text controls and child-cap reporting.
- Eight nested group edges: depth8 terminal excluded and depth-cap reporting.
- Four groups of39 useful leaves:120 retained controls and useful-budget reporting.
- One useful leaf:one retained control and no limits observed.
- Empty/root Meet URLs: unavailable; a non-root room URL: raw observation still possible.

The URL cases **do not reject a room lobby** and do not prove joined state. Current raw fields cannot distinguish that honestly. The staged actual Observation always carries callState unverified and names remain unassigned; source review pins that contract but the component probe does not exercise its JSON encoding/writer. No output count establishes a complete roster. Current private writer/native22 contracts and physical call identity/participant/clock/performance acceptance remain open until separately run. Any syntax error must be repaired only in the cache with new hashes/parity review; canonical sources stay frozen.
