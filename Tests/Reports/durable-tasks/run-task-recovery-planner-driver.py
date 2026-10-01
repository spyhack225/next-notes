#!/usr/bin/env python3
"""Pure held-recovery decisions using actual AgentTask and planner source; no store."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
tasks = root / "Sources/NextNotes/Agent/Tasks"
with tempfile.TemporaryDirectory(prefix="nextnotes-recovery-planner-") as temporary:
    folder = pathlib.Path(temporary)
    entry = folder / "Main.swift"
    entry.write_text('''import Foundation
@main struct Fixture {
    static func main() {
        let result = TaskRecoveryPlannerSelfTest.run()
        for failure in result.failures { print("TASK_RECOVERY_PLANNER_WRONG: \\(failure)") }
        if result.failures.isEmpty { print("TASK_RECOVERY_PLANNER_OK: \\(result.cases) cases") }
        else { print("TASK_RECOVERY_PLANNER_FAILED: \\(result.failures.count) assertions"); exit(1) }
    }
}
''')
    planner = tasks / "Durable/TaskRecoveryPlanner.swift"
    if "--terminal-held" in sys.argv:
        before = planner.read_text()
        after = before.replace("action: .noAction", "action: .holdForReview")
        assert before != after
        planner = folder / "TaskRecoveryPlanner.swift"
        planner.write_text(after)
    binary = folder / "fixture"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(tasks / "AgentTask.swift"), str(tasks / "Durable/TaskDurability.swift"),
                    str(planner), str(tasks / "Durable/TaskRecoveryPlannerSelfTest.swift"),
                    str(entry), "-o", str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)]).returncode)
