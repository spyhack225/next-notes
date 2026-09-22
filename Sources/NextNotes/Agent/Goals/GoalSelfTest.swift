import Foundation

/// G1 self-test body (runs inside `--selftest-schedule`, never standalone).
///
/// create → nudge → "done" → stop, with `endsAt` enforced. No model, no network, no
/// notification center: the nudge is an ordinary reminder schedule driven by
/// `AgentScheduler` under a fake clock, and the goal moves only on the person's words.
///
/// Wiring (returned as a dispatch snippet, never edited here):
/// `failures += await GoalSelfTest.failures(root: root)` inside `ScheduleSelfTest.run()`.
@MainActor
enum GoalSelfTest {
    final class FakeSystem: ReminderSystemRegistering {
        var registered: [UUID: Date] = [:]
        func register(_ schedule: AgentSchedule, slot: Date) async -> Bool {
            registered[schedule.id] = slot
            return true
        }
        func withdraw(scheduleID: UUID) { registered[scheduleID] = nil }
        func pendingScheduleIDs() async -> Set<UUID> { Set(registered.keys) }
        func isAuthorized() async -> Bool { true }
    }

    final class FakeDeliverer: ScheduleDelivering {
        var deliveries: [ScheduleDelivery] = []
        func deliver(_ delivery: ScheduleDelivery) async throws { deliveries.append(delivery) }
        func notifyProblem(scheduleID: UUID, title: String, body: String) {}
        func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String) {}
        func openSchedules() {}
        func speak(_ text: String) {}
    }

    final class FakeEnvironment: ScheduleEnvironment {
        var isUserPresent = false
        var isRecording = false
        var isDictating = false
        var isCallActive = false
        var isAgentBusy = false
    }

    static func failures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("goals: \(name)") }
        }
        let zone = TimeZone(identifier: "America/New_York")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
        }

        let goals = GoalStore(directory: root.appendingPathComponent("goals", isDirectory: true))
        let schedules = ScheduleStore(directory: root.appendingPathComponent("schedules", isDirectory: true))
        let system = FakeSystem()
        let deliverer = FakeDeliverer()
        let scheduler = AgentScheduler(
            store: schedules, system: system, deliverer: deliverer, environment: FakeEnvironment(),
            settings: { ScheduleSettingsSnapshot(enabled: true, quietStart: nil, quietEnd: nil, speech: .never) },
            timeZone: { zone })

        // The create flow: restate outcome + first step, yes, saved enabled with the first
        // nudge visible.
        let outcome = "Run twice a week"
        let firstStep = "Lay out shoes tonight"
        let restated = GoalStore.restatement(outcome: outcome, firstStep: firstStep)
        check("restatement lacks the outcome and first step",
              restated.contains(outcome) && restated.contains(firstStep))
        let created = date(2026, 9, 16, 8, 0)
        let firstNudge = date(2026, 9, 16, 20, 0)
        let ends = date(2026, 10, 16, 0, 0)
        let goal = goals.confirm(outcome: outcome, firstStep: firstStep, firstNudge: firstNudge,
                                 endsAt: ends, now: created, schedules: schedules)
        check("goal not saved active", goals.goal(id: goal.id)?.state == .active)
        guard let nudgeID = goal.nudgeScheduleID,
              let nudge = schedules.schedule(id: nudgeID) else {
            return failures + ["goals: the first nudge was not saved as a reminder"]
        }
        check("nudge is not an enabled reminder pointing at the goal",
              nudge.kind == .reminder && nudge.enabled && nudge.nextRunAt == firstNudge
                && nudge.prompt.contains(goal.id.uuidString))
        check("nudge does not say the first step in consumer words",
              nudge.prompt.contains(firstStep) && !nudge.prompt.lowercased().contains("cron")
                && !nudge.prompt.lowercased().contains("artifact"))

        // The nudge fires.
        await scheduler.runOnce(now: firstNudge.addingTimeInterval(5))
        check("the nudge did not deliver", deliverer.deliveries.count == 1
              && deliverer.deliveries.first?.body.contains(firstStep) == true)

        // A model finding without the person's yes moves nothing.
        check("a goal moved without the person's words",
              goals.advance(id: goal.id, userWords: "the model thinks this is going well") == nil
                && goals.goal(id: goal.id)?.state == .active)

        // "done" stops the nudges.
        check("done did not land", goals.advance(id: goal.id, userWords: "done, I did it!") == .done)
        check("nudges kept firing after done",
              schedules.schedule(id: nudgeID)?.enabled == false
                && schedules.schedule(id: nudgeID)?.nextRunAt == nil)
        let afterDone = deliverer.deliveries.count
        await scheduler.runOnce(now: date(2026, 9, 17, 20, 0).addingTimeInterval(5))
        check("a nudge fired after done", deliverer.deliveries.count == afterDone)

        // `endsAt` is enforced even when nobody says done.
        let goal2 = goals.confirm(outcome: "Read before bed", firstStep: "Put the book out",
                                  firstNudge: date(2026, 9, 17, 20, 0),
                                  endsAt: date(2026, 9, 18, 0, 0),
                                  now: date(2026, 9, 17, 8, 0), schedules: schedules)
        goals.enforceEndDates(now: date(2026, 9, 18, 0, 1), schedules: schedules)
        let goal2Done = goals.goal(id: goal2.id)?.state == .done
        let nudge2Stopped = goal2.nudgeScheduleID.map { schedules.schedule(id: $0)?.enabled == false } ?? false
        check("endsAt did not finish the goal and stop its nudges", goal2Done && nudge2Stopped)

        print("GOALS_OK goal=\(goal.id.uuidString.prefix(8)) nudges=\(deliverer.deliveries.count)")
        return failures
    }
}
