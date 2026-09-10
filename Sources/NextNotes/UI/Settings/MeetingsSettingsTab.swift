import SwiftUI

/// When a meeting records itself, what it keeps, and what it needs to hear both sides.
struct MeetingsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Record calendar meetings automatically", isOn: $settings.meetingsAutoRecord)

                Stepper(
                    value: $settings.meetingLeadMinutes,
                    in: Settings.leadMinutesRange
                ) {
                    LabeledContent(
                        "Get ready",
                        value: leadDescription
                    )
                }
                .disabled(!settings.meetingsAutoRecord)

                if !settings.meetingAutoRecordOverrides.isEmpty {
                    LabeledContent("Per-meeting answers") {
                        HStack(spacing: DS.Space.s) {
                            Text("\(settings.meetingAutoRecordOverrides.count) set")
                                .foregroundStyle(DS.Color.textSecondary)
                            Button("Clear") { settings.meetingAutoRecordOverrides = [:] }
                        }
                    }
                }
            } header: {
                Text("Automatic recording")
            } footer: {
                SettingsNote(text: "A calendar entry records itself when it has a conference "
                             + "link or at least one other person, isn\u{2019}t all day, and "
                             + "you haven\u{2019}t declined it. Every meeting can be answered "
                             + "individually in the Upcoming list, and that answer wins over "
                             + "this switch.")
            }

            callsSection
            callAppsSection

            Section {
                Toggle("Keep the recorded audio", isOn: $settings.meetingsKeepAudio)

                Toggle(
                    "Delete the recording once the notes are written",
                    isOn: $settings.meetingsDeleteAudioAfterNotes
                )
                .disabled(!settings.meetingsKeepAudio)
            } header: {
                Text("Recording")
            } footer: {
                SettingsNote(text: "Two channels are recorded: your microphone on the left, "
                             + "everything the Mac plays on the right. About 230 MB per hour "
                             + "— off by default because the transcript is what the notes are "
                             + "written from. A meeting that is going to have its speakers "
                             + "identified records audio either way, and throws it away "
                             + "afterwards unless it is being kept.")
            }

            Section {
                Toggle("Tell the other speakers apart", isOn: $settings.meetingsDiarize)

                if settings.meetingsDiarize {
                    ModelStatusRow(
                        title: "Speaker models",
                        detail: "Segmentation and voice embeddings, through FluidAudio.",
                        state: models.diarizerState,
                        downloadTitle: "Download",
                        action: { models.prepareDiarizer() }
                    )
                }
            } header: {
                Text("Speakers")
            } footer: {
                SettingsNote(text: "Runs on the system track after the recording stops, and "
                             + "labels it Speaker 1, Speaker 2 and so on — rename them from "
                             + "the meeting itself, and the notes pick the real names up on "
                             + "the next Regenerate. Your own microphone is never clustered: "
                             + "it is already one person.")
            }

            Section {
                ModelStatusRow(
                    title: "Parakeet",
                    detail: "Transcribes both meeting tracks on this Mac.",
                    state: models.parakeetState,
                    downloadTitle: "Download",
                    action: { models.prepareParakeet() }
                )
            } header: {
                Text("Transcription")
            } footer: {
                SettingsNote(text: "Meetings always use Parakeet, whichever engine dictation "
                             + "is set to: it transcribes recorded windows far faster than "
                             + "realtime, which is what keeps a live transcript close behind "
                             + "the conversation.")
            }

            Section {
                Toggle("Write notes when a meeting ends", isOn: $settings.notesAutoGenerate)

                Picker("Written by", selection: $settings.notesProvider) {
                    ForEach(LLMProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                if settings.notesProvider == .qwen35_4b {
                    ModelStatusRow(
                        title: NotesModels.spec.displayName,
                        detail: NotesModels.spec.displaySize,
                        state: models.notesModelState,
                        downloadTitle: "Download",
                        action: { models.prepareNotesModel() }
                    )
                }
            } header: {
                Text("Notes")
            } footer: {
                SettingsNote(text: settings.notesProvider.summary
                             + " Notes are rewritten on demand from the Regenerate button in "
                             + "a meeting, so the choice here isn\u{2019}t final.")
            }

            Section {
                LabeledContent("System audio") {
                    Button("Open Settings…") { Permissions.openSystemAudioSettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                SettingsNote(text: "macOS asks once, the first time a meeting records. "
                             + "Without it the meeting still records your microphone, and the "
                             + "other participants are missing from the transcript.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Calls

    /// The second trigger: a call nobody put on a calendar.
    private var callsSection: some View {
        Section {
            Toggle("Notice when I\u{2019}m on a call", isOn: $settings.callDetectionEnabled)

            Picker("When a call starts", selection: $settings.callDetectionAutoRecord) {
                Text("Ask before recording").tag(false)
                Text("Start recording").tag(true)
            }
            .disabled(!settings.callDetectionEnabled)
        } header: {
            Text("Calls")
        } footer: {
            SettingsNote(text: "A call is an app holding your microphone and the speakers "
                         + "at once — dictation is the microphone alone, and a video is the "
                         + "speakers alone. Noticing one needs no permission at all; "
                         + "recording it does. Asking first is the default on purpose: a "
                         + "meeting in your calendar is something you agreed to in advance, "
                         + "a call that rang out of nowhere isn\u{2019}t, and in some places "
                         + "recording one needs everybody\u{2019}s agreement.")
        }
    }

    /// One row per app that has actually held the microphone on this Mac.
    private var callAppsSection: some View {
        Section {
            if seenCallApps.isEmpty {
                // `breathing`, still: nothing has happened here *yet*, which is a stage
                // rather than a fault. Frozen because nothing is running — the list fills
                // in when some other app picks up the microphone, not on a clock of ours.
                LabeledOrb(
                    state: .breathing,
                    title: "Nothing yet",
                    detail: "An app appears here the first time it uses your microphone "
                        + "while Speechify is watching.",
                    size: DS.Size.orbBadge,
                    isAnimated: false
                )
            }

            ForEach(seenCallApps) { app in
                Picker(selection: answer(for: app)) {
                    // Not every app is offered all three. A browser holding the microphone
                    // and the speakers might be a Meet call in a tab and might be anything
                    // else at all, and nothing cheap tells them apart — so `CallPolicy`
                    // refuses to record one unasked, and offering "Always record" here
                    // would be a switch that does nothing. Google Meet installed as a
                    // Chrome app has its own bundle identifier, is not a browser as far as
                    // this rule is concerned, and keeps all three.
                    ForEach(CallPolicy.availableAnswers(forApp: app.bundleID)) { option in
                        Text(option.displayName).tag(option)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(app.name)
                        Text(app.bundleID)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                .disabled(!settings.callDetectionEnabled)
            }

            if !settings.callAppAnswers.isEmpty {
                LabeledContent("Per-app answers") {
                    HStack(spacing: DS.Space.s) {
                        Text("\(settings.callAppAnswers.count) set")
                            .foregroundStyle(DS.Color.textSecondary)
                        Button("Clear") { settings.callAppAnswers = [:] }
                    }
                }
            }
        } header: {
            Text("Apps that use your microphone")
        } footer: {
            SettingsNote(text: "This list is a record of what has happened on this Mac, not "
                         + "a catalogue of what could — so nothing has to be typed in, and an "
                         + "app you have never taken a call in never appears. An app nobody "
                         + "has answered for follows the switch above, and the control shows "
                         + "what that comes to. A browser is only ever asked about: a tab "
                         + "holding the microphone might be a meeting and might be anything. "
                         + "Speechify\u{2019}s own dictation and the system\u{2019}s speech "
                         + "services are never counted as calls.")
        }
    }

    /// One row of the app list.
    private struct CallApp: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// The apps seen holding the microphone, by the name a person would recognise.
    ///
    /// Sorted by that name rather than by when it was last seen: a list that reorders
    /// itself while the Settings window is open moves the row under the pointer.
    private var seenCallApps: [CallApp] {
        settings.callAppsSeen
            .map { CallApp(bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The row’s control, which always shows what the *next* call in that app would get.
    ///
    /// An app nobody has answered for reads back whatever the switch above does to it, and
    /// touching the control pins that answer to the app. There is deliberately no fourth
    /// "follow the switch" position — it would be a state the user has to reason about to
    /// predict — and Clear is how a row goes back to following it.
    private func answer(for app: CallApp) -> Binding<CallPolicy.AppAnswer> {
        Binding(
            get: {
                CallPolicy.effectiveAnswer(
                    forApp: app.bundleID,
                    autoRecord: settings.callDetectionAutoRecord,
                    stored: settings.callAnswer(forApp: app.bundleID)
                )
            },
            set: { settings.setCallAnswer($0, forApp: app.bundleID) }
        )
    }

    /// "1 minute before" / "at the start time" — the stepper's value read as a sentence.
    private var leadDescription: String {
        switch settings.meetingLeadMinutes {
        case 0: "At the start time"
        case 1: "1 minute before"
        default: "\(settings.meetingLeadMinutes) minutes before"
        }
    }
}
