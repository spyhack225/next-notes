import SwiftUI

/// Goals: what the person is working toward (G1).
///
/// Consumer words: Goals, Reminders. A goal's nudges are ordinary reminders pointing at
/// the goal; this view lists the goals, their state, and the next reminder. Creating one
/// restates the outcome and first step first — "yes" saves it enabled with the first
/// nudge visible (see `GoalStore.confirm`).
struct GoalsView: View {
    @State private var goals = GoalStore.shared
    @State private var schedules = ScheduleStore.shared
    @State private var outcome = ""
    @State private var firstStep = ""
    @State private var message: String?

    var body: some View {
        AgentPaneScroll {
            AgentPaneHeader(
                title: "Goals",
                subtitle: "Things you’re working toward. Your assistant reminds you — "
                    + "only you say when one is done."
            )
            AgentSplit {
                goalsList
            } rail: {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    createSection
                    if let message {
                        Text(message).font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { goals.reload(); schedules.reload() }
    }

    /// The goals themselves, or the empty state when there are none. Cards go in the
    /// adaptive grid so a wide window shows several per row rather than one 640pt column.
    @ViewBuilder
    private var goalsList: some View {
        if goals.goals.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Text("No goals yet").font(DS.Font.headline)
                Text("Name one below, in your own words. You’ll confirm it before anything is saved.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .padding(DS.Space.cardTight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: DS.Radius.card)
        } else {
            AgentCardGrid {
                ForEach(goals.goals.sorted { $0.createdAt > $1.createdAt }) { goal in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(goal.outcome).font(DS.Font.headline)
                        Text(statusLine(goal))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        Text("First step: \(goal.firstStep)")
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.textSecondary)
                        if goal.state == .active {
                            HStack(spacing: DS.Space.s) {
                                Button("Mark done") {
                                    goals.advance(id: goal.id, userWords: "done")
                                }
                                Button("I’m stuck", role: .destructive) {
                                    goals.advance(id: goal.id, userWords: "I’m stuck")
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(DS.Font.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .agentCardSurface()
                }
            }
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("A new goal").font(DS.Font.sectionLabel)
            TextField("What do you want? (for example, Run twice a week)", text: $outcome)
                .textFieldStyle(.roundedBorder)
            TextField("First step (for example, Lay out shoes tonight)", text: $firstStep)
                .textFieldStyle(.roundedBorder)
            Button("Set this goal") {
                let trimmedOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedStep = firstStep.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedOutcome.isEmpty, !trimmedStep.isEmpty else {
                    message = "Name the goal and its first step first."
                    return
                }
                // Restate → yes happens in conversation; this button is the "yes".
                let firstNudge = Date().addingTimeInterval(24 * 3_600)
                let goal = goals.confirm(outcome: trimmedOutcome, firstStep: trimmedStep,
                                         firstNudge: firstNudge, now: Date())
                message = goal.nudgeScheduleID == nil
                    ? "Saved. Reminders are turned off, so no reminder was set."
                    : "Saved. Your first reminder is set — \(goal.nudgeText())."
                outcome = ""
                firstStep = ""
            }
            .buttonStyle(.borderedProminent)
            .disabled(outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || firstStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    /// One line of state under a goal, in the same shape as a reminder's summary: what
    /// the person is waiting on, then when the next nudge lands.
    private func statusLine(_ goal: AgentGoal) -> String {
        switch goal.state {
        case .done: return "Done"
        case .stuck: return "Waiting on you"
        case .active: break
        }
        guard let nudgeID = goal.nudgeScheduleID,
              let nudge = schedules.schedule(id: nudgeID) else {
            return "No reminder set"
        }
        var parts = [reminderLine(nudge)]
        if let last = nudge.lastRun {
            parts.append("last: \(RoutinesView.outcomeLabel(last.outcome).lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    /// "Daily reminder at 06:00" — the nudge's own cadence in consumer words, never the
    /// model's wording.
    private func reminderLine(_ nudge: AgentSchedule) -> String {
        guard nudge.enabled else { return "Reminder paused" }
        guard let when = nudge.when else {
            return nudge.nextRunAt.map {
                "Next reminder " + $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "No reminder set"
        }
        let time = when.time.formatted
        switch when.repeatRule {
        case .once:
            return "One reminder at \(time)"
        case .daily:
            return "Daily reminder at \(time)"
        case .weekdays:
            return "Weekday reminder at \(time)"
        case .weekly(let days):
            return "Weekly reminder on " + days.map(\.name).joined(separator: ", ") + " at \(time)"
        case .monthly(let day):
            return "Monthly reminder on day \(day) at \(time)"
        }
    }
}
