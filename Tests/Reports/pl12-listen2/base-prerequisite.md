# Baseline build prerequisite

The original `fb1e6210`/`c6d850c` debug build actually ran via heavy.sh v2 and failed
at TaskAuthoritySelfTest.swift:372: `AgentTaskStore` has no `recoveredReadHistory`.
The retained baseline-build.log is the actual compiler evidence. No native run
started. This is an inherited source/test mismatch, not a voice regression.

AgentTaskStore receives the exact ten-line method already in the read-only
canonical working diff. It uses the existing-only primary snapshot and original
witness validator, never creates/repairs a store, and retains the SelfTest temp
persistence guard. On this branch only the already-committed authority test calls
it; the baseline voice/model producers remain byte-identical to fb1e6210.
No test assertion was removed/weakened and no canonical file was changed.

This out-of-voice-scope prerequisite must be skipped by the integrator because
canonical already has the identical hunk. This branch's baseline is qualified as
base voice sources plus that missing reader; it is not a pure fb1e6210 binary.
