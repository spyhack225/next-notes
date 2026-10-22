# P4-04 final169 Island rebase after public notice privacy

**OFF-SOURCE, COPY-ONLY, HELD, UNCOMPILED AND NATIVE UNRUN.** This packet contains relative Island source hunks and one additive COMMON fixture correction. The frozen final169 P4 packet and root privacy8 packet remain byte-identical. The source from root privacy FIXED (`395dd955…`) is a **prerequisite**, not an accepted runtime state at the time of this preparation. No product code, worktree, owner store, index, asset, OSLog or installed application was changed or read by this packet.

## Why the fixture needs an amendment

The frozen P4 final169 fixture has 169 checks. Its F26 expects `agentHeadsUp`; F27 expects `notice` for an Agent reply from `IslandState.noticeLogLabel`. Root privacy8, however, repairs the **actual** public push operand to the constant `Kind.noticeLogKind`, whose reply label is `agentReply`. Preserving F27's old expected string while forwarding the helper to the real producer would leave a false oracle; returning `notice` only from the helper would make it disagree with the public logger. `ADD-F27-label-on-final169-COMMON.patch` changes only F27's expected value from `notice` to `agentReply`, on a copy of the frozen fixture. Apply the same amended COMMON before both P4 original and P4 fixed measurements. The authored private reply canary, assertion name, 169-check count and every other input/check remain identical. This amendment is source-only and needs independent review and unchanged original/fixed qualification.

The inherited P4 prediction of 56 original feature failures no longer applies after root privacy's producer repair: F26/F27 may be green before the P4 producer change. Do not manufacture a logging regression to preserve that old count. Report measured results of the amended fixture.

## Exact Island stages

`manifest.json` pins all stage preimages, postimages and patch bytes. Every patch is relative to the repository root and was applied only to copied source for `source-only-replay.json`.

1. Root privacy COMMON Island `c3fc7961…` → `HELD-p4-common-after-root-privacy-COMMON.patch` → `361fc3a8…`. This is a **blocked comparison stage only**. It retains the root diagnostic observer and raw public operand, and adds the heads-up kind/priority seam. It is not an admissible P4 producer release because the public payload leak remains.
2. The root privacy8 producer patch takes the same COMMON source to root FIXED Island `395dd955…` in a separate acceptance run. Only after root accepts that exact producer should `P4-common-after-root-privacy-FIXED.patch` produce `de227516…`. The merged COMMON retains the observer and uses `kind.noticeLogKind` as the actual public operand; the P4 `noticeLogLabel` fixture helper forwards **that same policy**. Its new `.agentHeadsUp` enum arm returns the constant `agentHeadsUp`.
3. `P4-fixed-after-combined-COMMON.patch` produces `c7daea91…`. It changes the response-notice duration and passive-heads-up versus real dictation presentation priority, while retaining the notice/deadline, root observer, exact category logger and other notice behavior. There is no second logger and no String(describing:) fallback in this admissible branch.

The only mechanical merge conflict was Island notice plumbing: P4 added `noticeLogLabel` and replaced the log statement while privacy8 installed an exact observer and `noticeLogValue`. The merged stage retains privacy8's observer/log statement and makes the P4 helper call `kind.noticeLogKind`. Adding `.agentHeadsUp` also requires a new arm in privacy8's exhaustive `Kind.noticeLogKind` switch. The source-only replay verifies these hunks and exact postimages; it does not validate Swift exhaustiveness, run the fixtures, prove OSLog contents, render Island, or establish native quit/display behavior.

## Admission still required

Runtime root must qualify root privacy8 ORIGINAL→FIXED with its unchanged eight checks before accepting `395dd955…`; this package does not grant that acceptance. Then, with all P4 owner preimages rechecked, apply the amended 169-case COMMON to both P4 variants, capture the actual P4 ORIGINAL failures and FIXED pass on the same inputs, and run the related privacy8, Island, dictation, meeting and owner-isolation checks. The full P4 packet spans 18 files; these relative hunks cover only the Island collision. No source-only result here promotes Phase 4, a product claim, full UI accessibility or the physical microphone path.
