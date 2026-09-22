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
            Toggle(isOn: $settings.agentSchedulesEnabled) {
                rowLabel("Reminders", "Things you ask to be reminded of, at the time you said.")
            }
            .onChange(of: settings.agentSchedulesEnabled) { AgentScheduler.shared.requestPass() }

            // Two time wheels rather than two text fields. In a grouped form a `TextField`
            // draws its title beside the field, so "21:00" appeared twice per side, and free
            // text needed a "use 24-hour times" warning that a picker cannot trigger.
            LabeledContent {
                HStack(spacing: DS.Space.s) {
                    timePicker("Quiet hours start", text: $settings.agentQuietHoursStart, fallback: (21, 0))
                    Text("to").foregroundStyle(DS.Color.textSecondary)
                    timePicker("Quiet hours end", text: $settings.agentQuietHoursEnd, fallback: (8, 0))
                }
            } label: {
                rowLabel("Quiet hours", "A late reminder waits until these are over.")
            }

            Picker(selection: $settings.agentRoutineSpeech) {
                Text("When I'm at the Mac").tag("whenPresent")
                Text("Never").tag("never")
            } label: {
                rowLabel("Say them out loud", "Only when you are here and not on a call.")
            }

            Toggle(isOn: $settings.agentLaunchAtLogin) {
                rowLabel("Open Next Notes at login", "So routines can run without you opening it.")
            }
            .onChange(of: settings.agentLaunchAtLogin) { _, on in error = LaunchAtLogin.apply(on) }

            let schedules = store.schedules.filter { $0.kind == .reminder }
            if schedules.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Image(systemName: "bell.badge")
                        .font(DS.Font.title3)
                        .foregroundStyle(DS.Color.textSecondary)
                        .frame(width: DS.Size.iconLarge)
                    rowLabel("No reminders yet",
                             "Just ask: “remind me every weekday at 9 to stand up.”")
                }
                .padding(.vertical, DS.Space.xs)
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
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingsNote(text: "Reminders still arrive when Next Notes is closed. Routines run only "
                             + "while it is open, and anything a routine would write or send waits for "
                             + "your yes.")
                Button("See your routines") { NavigationState.shared.showRoutines() }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
            }
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

    /// A time-of-day picker over the "HH:mm" string the scheduler already stores.
    private func timePicker(
        _ label: String, text: Binding<String>, fallback: (Int, Int)
    ) -> some View {
        let date = Binding<Date>(
            get: {
                let time = ScheduleLocalTime.parse(text.wrappedValue)
                return Calendar.current.date(
                    bySettingHour: time?.hour ?? fallback.0, minute: time?.minute ?? fallback.1,
                    second: 0, of: Date()) ?? Date()
            },
            set: { picked in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: picked)
                text.wrappedValue = String(format: "%02d:%02d", parts.hour ?? fallback.0, parts.minute ?? fallback.1)
            }
        )
        return DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.stepperField)
            .fixedSize()
    }

    @ViewBuilder
    private func row(_ schedule: AgentSchedule) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: schedule.enabled ? "bell.fill" : "bell.slash")
                .font(DS.Font.title3)
                .foregroundStyle(schedule.enabled ? DS.Color.accent : DS.Color.textSecondary)
                .frame(width: DS.Size.iconLarge)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(schedule.plainEnglish)
                    .textSelection(.enabled)
                Text(detail(schedule))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Spacer(minLength: DS.Space.s)
            if schedule.enabled {
                Button { perform { _ = try await AgentScheduler.shared.pause(id: schedule.id, now: Date()) } } label: {
                    Image(systemName: "pause.fill")
                }
                .help("Pause")
                .accessibilityLabel("Pause")
            } else if !(schedule.isOneShot && schedule.nextRunAt == nil && (schedule.when.map(isPast) ?? true)) {
                Button { perform { _ = try await AgentScheduler.shared.resume(id: schedule.id, now: Date()) } } label: {
                    Image(systemName: "play.fill")
                }
                .help("Resume")
                .accessibilityLabel("Resume")
            }
            Button(role: .destructive) {
                perform { try await AgentScheduler.shared.remove(id: schedule.id) }
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        .buttonStyle(.borderless)
        .padding(.vertical, DS.Space.xxs)
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
