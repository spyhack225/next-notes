import SwiftUI

/// The two switches behind the cards that appear while somebody is still talking.
///
/// This exists because everything underneath it was already finished and unreachable:
/// `FunctionCallStore.setEnabled` and `.setNoticesMeetings` had no call site anywhere in
/// the app, so the switches could not be turned off. A feature with no way in looks exactly
/// like a working one from the inside.
///
/// The download itself — `FunctionCallStore.downloadFastEngine()` and its progress — now
/// lives in Settings ▸ Models, alongside every other model this app fetches (see
/// `ModelsSettingsTab.noticingThings`). This section only says, in one sentence, whether the
/// fast engine is on this Mac yet, with a link to where that is managed.
struct FastListeningSection: View {
    @State private var store = FunctionCallStore.shared

    var body: some View {
        Section {
            Toggle("Notice things I could do while I talk", isOn: Binding(
                get: { store.isEnabled },
                set: { store.setEnabled($0) }
            ))

            if store.isEnabled {
                // The same switch the live meeting agent reads, shown here because this is
                // where somebody has just been told the feature is ready. It was off by
                // default and named differently in another tab, so the meeting half of this
                // feature was inert on every Mac while this section said "Ready".
                Toggle(FunctionCallStore.Status.meetingToggleTitle, isOn: Binding(
                    get: { store.noticesMeetings },
                    set: { store.setNoticesMeetings($0) }
                ))

                // The download and its progress moved to Settings ▸ Models, which is now the
                // one place every model this app fetches lives. This row only says the state
                // in a sentence and points there — no button that starts a multi-megabyte
                // fetch belongs on a screen about two switches.
                HStack(spacing: DS.Space.xs) {
                    Text(store.status.sentence)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    Spacer()
                    Button("Manage in Models") {
                        NavigationState.shared.selectedSettingsTab = .models
                    }
                    .buttonStyle(.link)
                    .font(DS.Font.caption)
                }
            }
        } header: {
            Text("Noticing things")
        } footer: {
            SettingsNote(text: footer)
        }
        // Status starts at `.off` and is only correct once something has looked at the disk.
        // The watcher refreshes it at launch; this covers a Settings window opened after a
        // download finished, or after the notes model was deleted.
        .task { if !SelfTest.isRunning { await store.refreshStatus() } }
    }

    private var footer: String {
        if !store.isEnabled {
            return "Next Notes will not suggest anything while you talk. You can still ask "
                + "it for things yourself at any time."
        }
        var text = "While you are talking to Next Notes, it can notice when you have asked "
            + "for something it could do — sending a mail, putting something in the diary — "
            + "and offer it on a card. It never does any of it on its own: nothing happens "
            + "until you read the card and press the button. "
        text += store.noticesMeetings
            ? "It does the same during a meeting. That spends a little of your Mac on the "
                + "busiest minutes of the day, and it only ever acts on something you asked "
                + "for out loud."
            : "During a meeting it stays quiet. Turn the second switch on if you want it to "
                + "notice there too."
        return text + " The optional download makes the noticing quicker and uses less of "
            + "your Mac; without it, the model that writes your notes does the same job more "
            + "slowly. Either way the words stay on this Mac."
    }
}
