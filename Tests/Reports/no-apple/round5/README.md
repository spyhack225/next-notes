# Round 5 source census

Base: `8097108a`. Producer/fixture commit: `e728d84e`.

The census is a tripwire against ordinary forms, not a proof against obfuscation.
The first broken contract was the scanner's command-boundary expression: quoted
commands required no leading whitespace, operators required trailing whitespace,
wrappers/options were not consumed, and `<` did not end a command name.
The existing scanner now shares a bounded wrapper/flag/assignment expression
between command strings and script command positions, permits adjacent pipes and
redirections, and accepts leading whitespace. Closing prose quotes and leading
regex word-boundary strings are excluded from shell-command starts; the actual
repository census verifies the existing regex/prose lines without new allowances.
This is not a general shell parser or string evaluator.

The expanded maintained fixture retains all 29 previous cases and adds 34 cases:
spacing, no-space pipes, env -i, command/nohup/absolute env and combined wrappers
in Swift Process shell arguments, C system/popen and stdin-only scripts; direct
Process env options/argv; Python stdin/env; and heredoc/input/here-string forms.
Injected commands are source text only, never executed. A detection requires
exit 1 and a final VOICE_SINK_SOURCE_FAILED marker; crashes do not count.

| Check | Exit | Final marker |
| --- | --- | --- |
| Pinned original scanner, same 63 cases | 1 | VOICE_CENSUS_MUTATIONS_FAILED |
| Fixed scanner, same 63 cases | 0 | VOICE_CENSUS_MUTATIONS_OK |
| Whole repository census | 0 | VOICE_SINK_SOURCE_OK |
| Isolated Swift6 wrapper compile | 0 | NO_FINAL_MARKER |
| Actual unchanged census wrapper | 0 | VOICE_POLICY_CENSUS_WRAPPER_OK |

Original misses 27/63; fixed misses 0/63. Final counts are forbidden0,
explicit_nonplayback_exceptions30, files908. The allowlist is byte-identical to
8097108a; no exact or whole-file exception was added. Pins record the identical
fixture and unchanged production wrapper and accepted reply-settlement source.
Raw logs and process exits are retained in checks.json.

The wrapper probe compiles the unchanged production AgentVoicePolicySelfTest.swift
with only SelfTest guard/diagnostic and entry-point stubs. The production wrapper
locates this worktree and launches the maintained Python scanner through its real
Foundation Process/Pipe path. Compilation/run uses one normal heavy.sh slot,
with no NextNotes application launch, app build, model load or owner-store access.
This probe does not establish complete app/self-test registration, native voice,
physical UI, performance, or any inherited Settings/ACK/Mini acceptance.
The temporary executable is removed by TemporaryDirectory on exit; no owned
wt-scratch/no-apple tree was created. No shared scratch is changed.

The one heavy.sh slot exited0 after FIFO waiting and an unchanged memory gate
hold at49%/required50%; no threshold override was used. The actual wrapper
reported the same forbidden0/exceptions30/files908 counts. Its executable and
module cache were confined to its temporary report subdirectory and removed.
Source/fixture/allowlist invariance and git whitespace checks pass.
