import SwiftUI

/// Settings → Agent → Catch-up.
///
/// Two plain switches and one time. "When I'm back" is the catch-up that arrives after a
/// weekend or a long time away; the morning one is ready on weekdays at the time chosen here.
/// They are the same catch-up with two ways to start it, so the section never explains the
/// difference — it says when each one happens.
///
/// There is nothing to author. The words, the three things it may read and its voice are the
/// template's own; turning a switch on creates the matching one the first time, and later
/// switches only pause and resume it, so what the person set up in Reminders stays theirs.
struct CatchUpSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var store = ScheduleStore.shared
    @State private var busy = false
    @State private var problem: String?
    @State private var chosenTime = ScheduleLocalTime(hour: 6, minute: 0)

    var body: some View {
        Section {
            Toggle(isOn: backBinding) {
                rowLabel("Catch me up when I\u{2019}m back",
                         "After a weekend or a long time away, I\u{2019}ll tell you what you missed.")
            }
            .disabled(busy)

            Toggle(isOn: morningBinding) {
                rowLabel("Catch me up on weekday mornings",
                         "A short update, ready before your day starts.")
            }
            .disabled(busy)

            LabeledContent {
                timePicker
            } label: {
                rowLabel("Time", "On weekdays.")
            }
            .disabled(busy || morning?.enabled != true)

            if !settings.agentSchedulesEnabled, (back?.enabled == true || morning?.enabled == true) {
                HStack(spacing: DS.Space.s) {
                    Text("Reminders are turned off, so no catch-ups will arrive.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                    Button("Turn on") {
                        settings.agentSchedulesEnabled = true
                        AgentScheduler.shared.requestPass()
                    }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
                }
            }
            if busy {
                SettingsNote(text: "Making your first one now. This can take a minute.", orb: .composing)
            }
            if let problem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        } header: {
            Text("Catch-up")
        } footer: {
            SettingsNote(text: "Made on your Mac from your calendar, notes and mail. I only read; "
                         + "anything I would send waits for your yes.")
        }
        .onAppear { store.reload() }
    }

    // MARK: - What is set up

    private var back: AgentSchedule? {
        store.schedules.first { $0.isCatchUp && $0.kind == .trigger && $0.trigger?.event == .returned }
    }

    private var morning: AgentSchedule? {
        store.schedules.first { $0.isCatchUp && $0.kind == .routine }
    }

    // MARK: - Switches

    private var backBinding: Binding<Bool> {
        Binding(get: { back?.enabled == true }, set: { set(.whileOut, existing: back, on: $0) })
    }

    private var morningBinding: Binding<Bool> {
        Binding(get: { morning?.enabled == true }, set: { set(.morning, existing: morning, on: $0) })
    }

    /// Pause and resume what exists; create it the first time it is switched on.
    private func set(_ moment: CatchUpTemplate.Moment, existing: AgentSchedule?, on: Bool) {
        run {
            if let existing {
                if on { _ = try await AgentScheduler.shared.resume(id: existing.id, now: Date()) }
                else { _ = try await AgentScheduler.shared.pause(id: existing.id, now: Date()) }
            } else if on {
                try await create(moment)
            }
        }
    }

    /// The same path the Agent uses to set one up, so the person's switch and "set up a
    /// catch-up" in conversation make the same thing.
    private func create(_ moment: CatchUpTemplate.Moment) async throws {
        if !settings.agentSchedulesEnabled {
            settings.agentSchedulesEnabled = true
            AgentScheduler.shared.requestPass()
        }
        var arguments = CatchUpTemplate.createArguments(moment: moment)
        if moment != .whileOut { arguments["time"] = chosenTime.formatted }
        guard let tool = ScheduleToolCatalogue.all.first(where: { $0.name == "create" }) else { return }
        _ = try await ScheduleToolExecutor.run(
            tool, arguments: arguments, availableTools: Set(CatchUpTemplate.allowedTools))
    }

    // MARK: - Time

    private var timePicker: some View {
        let date = Binding<Date>(
            get: {
                let time = morning?.when?.time ?? chosenTime
                return Calendar.current.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                let time = ScheduleLocalTime(hour: parts.hour ?? 6, minute: parts.minute ?? 0)
                chosenTime = time
                guard let schedule = morning, let when = schedule.when else { return }
                run {
                    _ = try await AgentScheduler.shared.update(
                        id: schedule.id,
                        edit: ScheduleEdit(when: ScheduleWhen(
                            repeatRule: when.repeatRule, time: time, timeZone: when.timeZone)),
                        now: Date())
                }
            }
        )
        return DatePicker("Time", selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .fixedSize()
    }

    // MARK: - Plumbing

    /// One change at a time, with a plain sentence if it did not take. The scheduler's own
    /// error text is for the log; a person is told nothing was changed.
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        problem = nil
        Task { @MainActor in
            do {
                try await work()
            } catch {
                problem = "I couldn\u{2019}t set that up just now. Nothing was changed."
            }
            store.reload()
            busy = false
        }
    }

    private func rowLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(title)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
