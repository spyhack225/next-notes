# Self-test launcher cleanup — 2026-10-06

Launcher retains its exact child until exit, owns only a fresh subdirectory under caller TMPDIR, and removes it after join. Via-open uses -W and explicit TMPDIR; interrupted unproven app joins retain temp with a warning. Existing install lock holder forwards signals and joins before unlock.

Same eight authored fake-process cases: original internal RED25/public RED30; changed private checkout internal8/public8 GREEN. Caller sentinel/output retained; success/failure/crash/launch-failure cleanup, verdict-before-exit, signal forwarding and lock lifetime checked. Bash/Python syntax and scoped whitespace pass. Fake fixtures/processes cleaned; no native/model runs. Raw comparisons remain outside the repo under ~/Library/Caches/NextNotesBuild/integration/selftest-owned-tmp/.
