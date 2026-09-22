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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.xl) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Goals").font(DS.Font.title2)
                    Text("Things you’re working toward. Your assistant reminds you — "
                         + "only you say when one is done.")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                }
                ForEach(goals.goals.sorted { $0.createdAt > $1.createdAt }) { goal in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack {
                            Text(goal.outcome).font(DS.Font.headline)
                            Spacer()
                            Text(stateLabel(goal.state))
                                .font(DS.Font.chip)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        Text("First step: \(goal.firstStep)")
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Color.textSecondary)
                        if let nudgeID = goal.nudgeScheduleID,
                           let nudge = schedules.schedule(id: nudgeID),
                           let next = nudge.nextRunAt, nudge.enabled {
                            Text("Next reminder " + next.formatted(date: .abbreviated, time: .shortened))
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        } else if goal.state == .active {
                            Text("No reminder set")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
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
                    .padding(DS.Space.cardTight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                }
                createSection
                if let message {
                    Text(message).font(DS.Font.caption).foregroundStyle(DS.Color.warning)
                }
            }
            .padding(DS.Space.page)
            .frame(maxWidth: DS.Size.agentAboutMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .onAppear { goals.reload(); schedules.reload() }
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

    private func stateLabel(_ state: AgentGoal.State) -> String {
        switch state {
        case .active: "In progress"
        case .stuck: "Stuck"
        case .done: "Done"
        }
    }
}
