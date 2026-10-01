import Foundation

enum TaskRecoveryPlannerSelfTest {
    static func run() -> (cases: Int, failures: [String]) {
        var failures: [String] = []
        var cases = 0
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func check(_ name: String, _ input: TaskRecoveryInput, _ action: TaskRecoveryAction, word: String) {
            cases += 1
            let plan = TaskRecoveryPlanner.plan(input)
            if plan.action != action || !plan.reason.lowercased().contains(word.lowercased()) {
                failures.append("\(name): unexpected decision or reason")
            }
            if TaskRecoveryPlanner.plan(input) != plan { failures.append("\(name): planner is not deterministic") }
        }
        func input(_ status: AgentTaskStatus, durability: TaskDurability? = nil) -> TaskRecoveryInput {
            TaskRecoveryInput(task: AgentTask(id: "fixture-task", objective: "Private fixture objective",
                createdAt: now, status: status, durability: durability), now: now)
        }
        for (status, word) in [(AgentTaskStatus.completed, "done"), (.failed, "failed"), (.cancelled, "stopped")] {
            var row = input(status)
            row.effect = .outcomeUnknown
            row.observedReceiptIDs = ["fixture-receipt"]
            check("terminal \(status)", row, .noAction, word: word)
        }
        for (status, word) in [(AgentTaskStatus.waitingForInput, "answer"), (.waitingForPermission, "approval"),
                               (.waitingForCompatibilityCLI, "one-time")] {
            var row = input(status)
            row.effect = .completed
            check("pending \(status)", row, .restoreCard, word: word)
        }
        check("legacy queued", input(.queued), .reportFailed, word: "waiting")
        check("legacy running", input(.running), .holdForReview, word: "attempt")
        check("empty default durability", input(.running, durability: TaskDurability()), .holdForReview, word: "attempt")
        var durable = TaskDurability()
        durable.attempt = 1
        durable.attemptStartedAt = now.addingTimeInterval(-60)
        durable.resumePolicy = .retry
        durable.leaseOwner = "123"
        for runtime in [TaskRuntimeClass.localDeterministic, .cloudModel, .browserOrMCP, .acpWorker, .scheduledResearch, .waitingOnPerson] {
            durable.runtimeClass = runtime
            check("incomplete history \(runtime)", input(.running, durability: durable), .holdForReview, word: "history")
        }
        durable.resumePolicy = .neverAuto
        check("explicit never auto", input(.running, durability: durable), .holdForReview, word: "review")
        durable.resumePolicy = .retry
        var complete = input(.running, durability: durable)
        complete.journalCoverage = .complete
        for (lease, word) in [(TaskRecoveryLeaseObservation.unknown, "ownership"), (.invalid, "ownership"),
                              (.possiblyAlive, "may still"), (.alive, "still alive"), (.gone, "checks")] {
            var row = complete
            row.lease = lease
            check("lease \(lease)", row, .holdForReview, word: word)
        }
        for effect in [TaskRecoveryEffectObservation.inFlight, .outcomeUnknown, .completed, .failed] {
            var row = complete
            row.effect = effect
            check("uncertain/recorded effect \(effect)", row, .holdForReview, word: "action")
        }
        var receipt = complete
        receipt.observedReceiptIDs = ["fixture-terminal-receipt"]
        receipt.effect = .completed
        check("observed terminal receipt", receipt, .holdForReview, word: "receipt")
        durable.receiptIDs = ["fixture-persisted-receipt"]
        check("persisted receipt", input(.running, durability: durable), .holdForReview, word: "receipt")
        durable.receiptIDs = []
        durable.resumePolicy = .verifyThenDecide
        var verify = input(.running, durability: durable)
        verify.journalCoverage = .complete
        verify.lease = .gone
        verify.effect = .verifiedNotStarted
        check("missing receipts not proof", verify, .holdForReview, word: "missing receipts")
        durable.resumePolicy = .resumeFromCheckpoint
        var checkpoint = input(.running, durability: durable)
        checkpoint.journalCoverage = .complete
        checkpoint.lease = .gone
        checkpoint.checkpoint = .validated
        check("checkpoint not authority", checkpoint, .holdForReview, word: "reconnect")
        durable.resumePolicy = .retry
        var positive = input(.running, durability: durable)
        positive.journalCoverage = .complete
        positive.effect = .verifiedNotStarted
        positive.lease = .gone
        check("positive metadata never launches", positive, .holdForReview, word: "checks")
        check("queued metadata never launches", input(.queued, durability: durable), .reportFailed, word: "waiting")
        for source in ["voice", AgentTask.scheduledSource] {
            var row = complete
            row.task.source = source
            check("existing owner \(source)", row, .holdForReview, word: "owner")
        }
        var remote = complete
        remote.task.backend = "remote"
        check("remote owner", remote, .holdForReview, word: "owner")
        return (cases, failures)
    }
}
