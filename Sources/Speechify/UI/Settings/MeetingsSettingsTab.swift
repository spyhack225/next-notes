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
                Text("A calendar entry records itself when it has a conference link or at "
                     + "least one other person, isn\u{2019}t all day, and you haven\u{2019}t "
                     + "declined it. Every meeting can be answered individually in the "
                     + "Upcoming list, and that answer wins over this switch.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            }

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
                Text("Two channels are recorded: your microphone on the left, everything the "
                     + "Mac plays on the right. About 230 MB per hour — off by default because "
                     + "the transcript is what the notes are written from. A meeting that is "
                     + "going to have its speakers identified records audio either way, and "
                     + "throws it away afterwards unless it is being kept.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
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
                Text("Runs on the system track after the recording stops, and labels it "
                     + "Speaker 1, Speaker 2 and so on — rename them from the meeting itself, "
                     + "and the notes pick the real names up on the next Regenerate. Your own "
                     + "microphone is never clustered: it is already one person.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
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
                Text("Meetings always use Parakeet, whichever engine dictation is set to: it "
                     + "transcribes recorded windows far faster than realtime, which is what "
                     + "keeps a live transcript close behind the conversation.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
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
                Text(settings.notesProvider.summary
                     + " Notes are rewritten on demand from the Regenerate button in a "
                     + "meeting, so the choice here isn\u{2019}t final.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            }

            Section {
                LabeledContent("System audio") {
                    Button("Open Settings…") { Permissions.openSystemAudioSettings() }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("macOS asks once, the first time a meeting records. Without it the "
                     + "meeting still records your microphone, and the other participants "
                     + "are missing from the transcript.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .formStyle(.grouped)
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
