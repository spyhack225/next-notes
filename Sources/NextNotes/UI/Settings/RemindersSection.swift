import SwiftUI

/// Settings → Agent → Reminders.
///
/// The switch, quiet hours and the speech rule, and every reminder the Agent has set with
/// its sentence, next time and last result — paused, resumed or deleted from here. Routines,
/// with run history and drafts, live in Agent → Routines; *Open at login* is here and there.
struct RemindersSection: View {
    @State private var settings = Settings.shared
    @State private var store = ScheduleStore.shared
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Reminders", isOn: $settings.agentSchedulesEnabled)
                .onChange(of: settings.agentSchedulesEnabled) { AgentScheduler.shared.requestPass() }

            HStack(spacing: DS.Space.s) {
                Text("Quiet hours")
                Spacer()
                TextField("21:00", text: $settings.agentQuietHoursStart)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text("to")
                TextField("08:00", text: $settings.agentQuietHoursEnd)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }
            if ScheduleLocalTime.parse(settings.agentQuietHoursStart) == nil
                || ScheduleLocalTime.parse(settings.agentQuietHoursEnd) == nil {
                Text("Use 24-hour times such as 21:00; until then there are no quiet hours.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }

            Picker("Speak reminders and routines", selection: $settings.agentRoutineSpeech) {
                Text("When I'm at the Mac").tag("whenPresent")
                Text("Never").tag("never")
            }

            Toggle("Open Next Notes at login", isOn: $settings.agentLaunchAtLogin)
                .onChange(of: settings.agentLaunchAtLogin) { _, on in error = LaunchAtLogin.apply(on) }

            let schedules = store.schedules.filter { $0.kind == .reminder }
            if schedules.isEmpty {
                Text("No reminders yet. Ask the Agent, for example “remind me every weekday at 9 to stand up.”")
                    .foregroundStyle(DS.Color.textSecondary)
            }
            ForEach(schedules) { schedule in
                row(schedule)
            }

            if let error {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        } header: {
            Text("Reminders and routines")
        } footer: {
            SettingsNote(text: "Reminders are also handed to macOS, so they arrive while Next Notes is "
                         + "closed. Quiet hours hold a late reminder until they end. A reminder is spoken "
                         + "only when you have used the Mac in the last two minutes, nothing is recording "
                         + "and no call is active. Routines run only while Next Notes is open, and anything a "
                         + "routine would write or send waits for your approval in Agent → Routines.")
        }
    }

    @ViewBuilder
    private func row(_ schedule: AgentSchedule) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(schedule.plainEnglish)
                    .textSelection(.enabled)
                Spacer()
                if schedule.enabled {
                    Button("Pause") { perform { _ = try await AgentScheduler.shared.pause(id: schedule.id, now: Date()) } }
                } else if !(schedule.isOneShot && schedule.nextRunAt == nil && (schedule.when.map(isPast) ?? true)) {
                    Button("Resume") { perform { _ = try await AgentScheduler.shared.resume(id: schedule.id, now: Date()) } }
                }
                Button("Delete", role: .destructive) {
                    perform { try await AgentScheduler.shared.remove(id: schedule.id) }
                }
            }
            Text(detail(schedule))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private func isPast(_ when: ScheduleWhen) -> Bool {
        if case .once(let instant) = when.repeatRule { return instant <= Date() }
        return false
    }

    private func detail(_ schedule: AgentSchedule) -> String {
        var parts: [String] = []
        if !schedule.enabled {
            parts.append(schedule.isOneShot && schedule.nextRunAt == nil ? "Done" : "Paused")
        } else if let next = schedule.nextRunAt {
            parts.append("Next " + next.formatted(date: .abbreviated, time: .shortened))
        }
        if let pending = schedule.pendingDelivery {
            parts.append("held until " + pending.notBefore.formatted(date: .omitted, time: .shortened))
        }
        if let last = schedule.lastRun {
            parts.append("last: \(last.outcome.rawValue) " + last.at.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do {
                try await action()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
