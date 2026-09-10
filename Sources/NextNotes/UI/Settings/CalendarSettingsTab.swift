import SwiftUI

/// Where meetings are read from.
///
/// Two providers, deliberately independent: Apple Calendar needs a TCC grant and nothing
/// else, Google needs an OAuth client the user creates themselves. Either can be on
/// without the other, and with both on the same meeting is shown once — `CalendarService`
/// collapses the duplicate.
struct CalendarSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var calendar = CalendarService.shared
    @State private var isConnecting = false
    @State private var isImportingClient = false
    @State private var importFailure: String?

    /// A client the Workspace CLI already has that Calendar isn't using yet. Its presence is
    /// the whole reason for the "use it" button: on a machine where the agent is already set
    /// up, there is nothing left for the user to fetch.
    private var adoptableClient: GoogleClientConfig? {
        guard let installed = GoogleClientConfig.installed,
              installed.clientID != settings.googleClientID
        else { return nil }
        return installed
    }

    var body: some View {
        Form {
            appleSection
            googleSection
            statusSection
        }
        .formStyle(.grouped)
        .task { await calendar.refreshGoogleCalendars() }
        .fileImporter(isPresented: $isImportingClient, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    settings.apply(try GoogleClientConfig.adopt(from: url))
                    importFailure = nil
                } catch {
                    importFailure = error.localizedDescription
                }
            case .failure(let error):
                importFailure = error.localizedDescription
            }
        }
    }

    // MARK: - Apple

    private var appleSection: some View {
        Section {
            Toggle("Read Apple Calendar", isOn: $settings.calendarEventKitEnabled)
                .onChange(of: settings.calendarEventKitEnabled) { _, _ in
                    Task { await calendar.refresh() }
                }

            LabeledContent("Access") {
                HStack(spacing: DS.Space.s) {
                    StatusChip(text: state(.eventKit).displayName, color: chipColor(state(.eventKit)))
                    if !state(.eventKit).isAuthorized {
                        Button("Grant…") {
                            Task {
                                let granted = await calendar.authorizeEventKit()
                                if granted == .denied { Permissions.openCalendarSettings() }
                            }
                        }
                    }
                }
            }
            .disabled(!settings.calendarEventKitEnabled)
        } header: {
            Text(CalendarProviderID.eventKit.displayName)
        } footer: {
            footnote("Every calendar in the Calendar app, including the Google and Exchange "
                     + "accounts it already syncs. macOS asks once.")
        }
    }

    // MARK: - Google

    private var googleSection: some View {
        Section {
            Toggle("Read Google Calendar", isOn: $settings.calendarGoogleEnabled)
                .onChange(of: settings.calendarGoogleEnabled) { _, _ in
                    Task { await calendar.refresh() }
                }

            // The file is what Google hands over, so importing it is the shortest honest
            // path — the two fields below stay for reading back what was imported and for
            // the user who would rather paste.
            LabeledContent("OAuth client") {
                HStack(spacing: DS.Space.s) {
                    if let adoptableClient {
                        Button("Use the Workspace client") { settings.apply(adoptableClient) }
                    }
                    Button("Import JSON\u{2026}") { isImportingClient = true }
                }
            }
            .disabled(!settings.calendarGoogleEnabled)

            LabeledContent("Client ID") {
                TextField("123…apps.googleusercontent.com", text: $settings.googleClientID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: DS.Size.settingsFieldWidth)
            }
            .disabled(!settings.calendarGoogleEnabled)

            LabeledContent("Client secret") {
                TextField("GOCSPX-…", text: $settings.googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: DS.Size.settingsFieldWidth)
            }
            .disabled(!settings.calendarGoogleEnabled)

            if let importFailure {
                Text(importFailure)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Account") {
                HStack(spacing: DS.Space.s) {
                    StatusChip(text: state(.google).displayName, color: chipColor(state(.google)))
                    if state(.google).isAuthorized {
                        Button("Disconnect") {
                            Task { await calendar.disconnectGoogle() }
                        }
                    } else {
                        Button("Connect…") {
                            Task {
                                isConnecting = true
                                await calendar.connectGoogle()
                                isConnecting = false
                            }
                        }
                        .disabled(isConnecting || settings.googleClientID.isEmpty)
                    }
                    if isConnecting {
                        // `connecting` — a constellation wiring itself, packets running the
                        // edges — while the browser round trip is out. It is the one orb
                        // that depicts two parties being joined, which is the whole of what
                        // this button does.
                        ThinkingOrb(state: .connecting, label: "Connecting")
                    }
                }
            }
            .disabled(!settings.calendarGoogleEnabled)

            if let detail = state(.google).detail {
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state(.google).isAuthorized, !calendar.googleCalendars.isEmpty {
                calendarChecklist
            }
        } header: {
            Text(CalendarProviderID.google.displayName)
        } footer: {
            footnote("Google only issues calendar access to an OAuth client you own. Create "
                     + "one of type “Desktop app” in Google Cloud, enable the Calendar API, "
                     + "and import the JSON it downloads — Connect then opens your browser. "
                     + "It is the same client the Workspace agent uses, so importing it on "
                     + "either screen sets up both. A desktop client's secret isn't "
                     + "confidential (it ships inside every copy of an app that has one), "
                     + "but Google's token endpoint asks for it. Next Notes asks for "
                     + "read-only access and stores the refresh token in your Keychain.")
        }
    }

    /// Which calendars to read. Nothing ticked means "whatever Google itself shows", which
    /// is what a new account wants and what the provider falls back to.
    private var calendarChecklist: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Calendars")
                .font(DS.Font.sectionLabel)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    ForEach(calendar.googleCalendars) { entry in
                        Toggle(entry.displayName, isOn: binding(for: entry))
                            .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: DS.Size.calendarListHeight)

            SettingsNote(text: settings.googleCalendarIDs.isEmpty
                         ? "None ticked — the calendars selected in Google are used."
                         : "\(settings.googleCalendarIDs.count) calendar(s) read.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Upcoming") {
                HStack(spacing: DS.Space.s) {
                    Text("\(calendar.upcoming.count) in the next day")
                        .foregroundStyle(DS.Color.textSecondary)
                    Button("Refresh") { Task { await calendar.refresh() } }
                        .disabled(calendar.isRefreshing)
                    if calendar.isRefreshing {
                        // `searching` — reading a diary it did not write, to find the
                        // meetings worth recording. A spinner says only "wait"; this says
                        // which of the app's long jobs is the one you are waiting on, and a
                        // calendar pass over several accounts is long enough to ask.
                        ThinkingOrb(state: .searching, label: "Reading calendars")
                    }
                }
            }
            if let error = calendar.lastError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Status")
        } footer: {
            footnote(calendar.lastRefresh.map {
                "Last read \($0.formatted(date: .omitted, time: .standard)). Calendars are "
                + "re-read every few minutes and after the Mac wakes."
            } ?? "Calendars are re-read every few minutes and after the Mac wakes.")
        }
    }

    // MARK: - Helpers

    private func state(_ id: CalendarProviderID) -> CalendarAuthorizationState {
        calendar.providerStates[id] ?? .needsAuthorization
    }

    /// Status colours are text colours, never the meter palette.
    private func chipColor(_ state: CalendarAuthorizationState) -> Color {
        switch state {
        case .authorized: DS.Color.success
        case .denied, .failed: DS.Color.warning
        case .disabled, .needsAuthorization: DS.Color.info
        }
    }

    private func binding(for entry: GoogleCalendarListEntry) -> Binding<Bool> {
        Binding(
            get: { settings.googleCalendarIDs.contains(entry.id) },
            set: { isOn in
                var ids = settings.googleCalendarIDs
                if isOn {
                    if !ids.contains(entry.id) { ids.append(entry.id) }
                } else {
                    ids.removeAll { $0 == entry.id }
                }
                settings.googleCalendarIDs = ids
                Task { await calendar.refresh() }
            }
        )
    }

    private func footnote(_ text: String) -> some View {
        SettingsNote(text: text)
    }
}
