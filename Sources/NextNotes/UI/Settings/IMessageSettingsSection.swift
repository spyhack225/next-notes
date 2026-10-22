import SwiftUI

/// Settings → Agent → Phone: the switch, the refusal line, and Stop.
///
/// The switch is intent, not consent: flipping it on opens the setup sheet, and
/// it reads as on only once the sheet connects. Flipping it off — or Stop —
/// ends it on the spot with no confirmation, because turning off is the safe
/// direction. Every sentence is `IMessageConsentCopy`; the grant row itself
/// stays in `MessagesAccessSection`, which already owns it.
struct IMessageSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var showSheet = false
    @State private var lastDecline: IMessageDeclineReason?
    @State private var isPaired = false
    @State private var canaryUnreadable = 0

    var body: some View {
        Section {
            Toggle(IMessageConsentCopy.switchTitle, isOn: switchBinding)
            Text(IMessageConsentCopy.switchDetail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if lastDecline != nil {
                Text(IMessageConsentCopy.refusal)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.imessageEnabled {
                HStack(spacing: DS.Space.s) {
                    Button("Set up again") { showSheet = true }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                    Button(IMessageConsentCopy.stopButton) { stop() }
                        .buttonStyle(.link)
                        .font(DS.Font.caption)
                    Spacer()
                    Text(isPaired ? "Connected" : "Not connected yet")
                        .font(DS.Font.caption)
                        .foregroundStyle(isPaired ? DS.Color.success : DS.Color.textSecondary)
                }
                // IM-17e — the canary's row, always present: the 24-hour count of
                // messages that could not be read, with the note only when non-zero
                // so the row and the notification cannot disagree.
                LabeledContent(IMessageCanaryCopy.settingsRow) {
                    Text("\(canaryUnreadable)")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                if canaryUnreadable > 0 {
                    Text(IMessageCanaryCopy.settingsNote)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Phone")
        }
        .sheet(isPresented: $showSheet) {
            IMessageSetupSheet(onDecline: { lastDecline = $0 })
        }
        .task { refresh() }
    }

    /// On — but only by walking the sheet: the flip opens setup and the switch
    /// itself stays off until the sheet connects. Off ends it immediately.
    private var switchBinding: Binding<Bool> {
        Binding(
            get: { settings.imessageEnabled },
            set: { on in
                if on {
                    showSheet = true
                } else {
                    stop()
                }
            }
        )
    }

    static var identityDirectory: URL {
        if SelfTest.requested == "--selftest-settings-sheet" {
            let root = SelfTest.checkedSettingsFixturePath(FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true))
            _ = SelfTest.checkedSettingsFixturePath(root.appendingPathComponent(RemoteIdentityStore.fileName))
            return root
        }
        return AppIdentity.applicationSupportDirectory
    }

    private func stop() {
        settings.imessageEnabled = false
        // Local act, like the flip that calls it: stopping must always work.
        try? RemoteIdentityStore(directory: Self.identityDirectory)
            .suspendRemoteAccess()
        refresh()
    }

    private func refresh() {
        let config = RemoteIdentityStore(directory: Self.identityDirectory)
            .configuration
        isPaired = config.isPaired
        canaryUnreadable = config.canaryUnreadable
    }
}
