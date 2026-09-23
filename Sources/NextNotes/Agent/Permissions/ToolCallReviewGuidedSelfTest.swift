import Foundation

/// `--selftest-guided`: D9, the guided first success (§8.2).
///
/// One scripted sequence, the one Muse's onboarding is built around: connect a calendar
/// (the unscary first step) → name two people → propose one real change → show the
/// approval card → execute → offer exactly one follow-up. The point is not any single
/// card; it is that the *path* holds — every title a person reads is a consumer sentence,
/// every factual value is grounded in the fixture, and a failure on the same path obeys
/// the FailureCard rule (what did and did not happen, what there is to undo, ≤2 buttons).
///
/// No model, network, account, calendar or microphone. The calendar connection is a
/// fixture `ToolCallContext`; the "executed" half is the review's own execution
/// arguments passing `ToolCallValidation`, which is exactly what the executor checks
/// before firing. `PermissionGate` and the schedule store are never touched.
@MainActor
enum GuidedFirstSuccessSelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        var visible: [(String, String)] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        func record(_ label: String, _ text: String) {
            visible.append((label, text))
        }

        // MARK: 1 — Connect the calendar (fixture)

        guard let agendaTool = AgentToolRegistry.shared.tool(named: "get_agenda") else {
            failures.append("the calendar read is not in the catalogue")
            return finish(failures)
        }
        let connectedTitle = ToolCallReviewBuilder.title(
            for: agendaTool, arguments: [:], context: .empty
        )
        record("calendar title", connectedTitle)
        check("connecting the calendar did not read as a consumer sentence",
              connectedTitle == "Check what is on your calendar")

        // MARK: 2 — Name two people

        var context = ToolCallContext.empty
        context.userWords = "Move Friday’s Acme renewal call to 3, and invite Sam and Ana"
        context.attendees = ["Sam", "Ana"]
        context.people = ["Sam", "Ana"]
        context.now = Date(timeIntervalSince1970: 1_790_000_000)
        check("the fixture does not confirm the two named people",
              context.confirmsPerson("Sam") && context.confirmsPerson("Ana"))

        // MARK: 3 — Propose one real change

        guard let eventTool = AgentToolRegistry.shared.tool(named: "create_event") else {
            failures.append("the calendar write is not in the catalogue")
            return finish(failures)
        }
        let arguments = [
            "title": "Acme renewal call",
            "start": "2026-09-25T15:00:00-04:00",
            "end": "2026-09-25T15:30:00-04:00",
            "attendees": "Sam, Ana",
        ]
        let review = ToolCallReviewBuilder.review(
            id: "guided-first-success",
            tool: eventTool,
            arguments: arguments,
            trigger: .youSaid(context.userWords),
            context: context
        )
        record("proposal title", review.title)
        record("proposal why", review.why)
        for field in review.fields {
            record("field \(field.name)", field.label)
            record("field \(field.name) status", field.statusLine)
            record("field \(field.name) prompt", field.prompt)
        }
        check("the proposal did not lead with the event's own name",
              review.title.contains("Acme renewal call"))
        check("the approval card was not ready to run: \(review.blockers.map(\.name))",
              review.isReadyToRun)
        check("the card's why-line does not quote the person",
              review.why.contains("You said") && review.why.contains("Acme renewal call"))
        check("a field label is not written for a person",
              review.fields.allSatisfy { $0.label.contains("_") == false })

        // MARK: 4 — Execute (what the executor checks, without an account)

        let executionProblem = ToolCallValidation.problem(tool: eventTool, arguments: review.arguments)
        check("the approved arguments do not pass the executor's own check: \(executionProblem ?? "nil")",
              executionProblem == nil)
        check("an approved field lost its value",
              review.arguments["title"] == "Acme renewal call"
                && review.arguments["attendees"] == "Sam, Ana")

        // MARK: 5 — Exactly one proactive follow-up offer

        let readResult = "Acme renewal call — Friday 25 Sep, 15:00. "
            + "Join here: https://meet.google.com/abc-defg-hij"
        let offer = FollowUpOfferBuilder.offer(for: "workspace.get_agenda", result: readResult)
        record("follow-up", offer?.sentence ?? "")
        record("follow-up button", offer?.title ?? "")
        check("the read did not offer exactly one follow-up", offer != nil)
        check("the follow-up is not fully determined by the result",
              offer?.arguments["url"] == "https://meet.google.com/abc-defg-hij"
                && offer?.toolID == "computer.open_url")
        check("two pages in the result still produced an offer",
              FollowUpOfferBuilder.offer(
                for: "workspace.get_agenda",
                result: "One: https://a.example.com Two: https://b.example.com"
              ) == nil)
        check("a write produced a follow-up offer",
              FollowUpOfferBuilder.offer(for: "workspace.send_email", result: readResult) == nil)
        check("a result with no page produced an offer",
              FollowUpOfferBuilder.offer(for: "workspace.get_agenda", result: "Nothing today.") == nil)

        // MARK: 6 — A failure on the same path obeys the FailureCard rule

        var failed = AgentTask(
            objective: "Move the Acme renewal call",
            source: "selftest",
            status: .failed,
            tool: "workspace.create_event",
            arguments: arguments
        )
        failed.failure = "Google refused the change."
        record("failure summary", failed.failureSummary)
        record("failure undo", failed.failureUndoLine)
        check("a failure did not say what did not happen",
              failed.failureSummary.contains("Google refused the change.")
                && failed.failureSummary.contains("Nothing was created or sent."))
        check("a failure did not say there is nothing to undo",
              failed.failureUndoLine.lowercased().contains("nothing to undo"))
        let sendFailure = FailureCard.forTask(failed, retryRisk: .send, retry: {}, openResult: nil)
        check("a failed send offered a retry", sendFailure.actions.isEmpty)
        check("a failure card offered more than two ways forward", sendFailure.actions.count <= 2)
        let modifyFailure = FailureCard.forTask(failed, retryRisk: .modify, retry: {}, openResult: nil)
        check("a failed change offered no retry",
              modifyFailure.actions.count == 1 && modifyFailure.actions[0].title == "Try again")
        check("a failure card offered more than two ways forward", modifyFailure.actions.count <= 2)

        // MARK: 7 — The step list the whole path renders

        let store = AgentActivityStore.shared
        store.resetForSelfTest()
        let task = AgentTask(objective: "Move the Acme renewal call", source: "selftest")
        // `begin` seeds the run (objective, no step of its own); every user-visible step
        // is an `update`, so the whole guided path is five updates.
        store.begin(task: task, title: task.objective)
        store.update(taskID: task.id, kind: .reading, title: "Calendar connected")
        store.update(taskID: task.id, kind: .reading, title: "Named Sam and Ana")
        store.update(taskID: task.id, kind: .writing, title: review.title)
        store.update(taskID: task.id, kind: .waiting, title: "Asked you before changing it")
        store.update(taskID: task.id, kind: .completed, title: "Moved the Acme renewal call")
        let rows = store.steps(taskID: task.id)
        check("the guided path did not render five steps", rows.count == 5)
        check("the guided path did not leave exactly one step in progress",
              rows.count(where: { !$0.isCompleted }) == 1)
        let feed = store.liveSteps
        check("the live feed did not carry the whole path",
              feed.titles.count == 5 && feed.current == 5 && feed.total == 5)
        for row in rows {
            record("step", row.title)
            check("a step title leaked chain-of-thought", AgentActivityProjector.isPublic(row.title))
        }
        store.finish(taskID: task.id, title: "Done")
        check("the finished path left a step in progress", store.inProgressStepCount == 0)
        store.resetForSelfTest()

        // MARK: 8 — Every card on the path obeys the naming rules (§8.3)

        for (label, text) in visible where !text.isEmpty {
            let tokens = UIStringsLint.forbiddenTokens(in: text)
            check("\(label) says \(tokens.joined(separator: ", ")): \(text)", tokens.isEmpty)
        }

        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Bool {
        for failure in failures { print("GUIDED_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty
              ? "GUIDED_OK: calendar → names → proposal → approval → done → one follow-up, all in consumer words"
              : "GUIDED_FAILED: \(failures.count) rule(s) wrong")
        return failures.isEmpty
    }
}
