import SwiftUI

/// Lets the user give a meeting a name that is not the calendar title or "Meeting · 14:30".
///
/// The model already stored `title` as a `var`; nothing wrote it after creation. This is
/// the write path — More, a double-click on the heading, or the list's context menu.
struct RenameMeetingSheet: View {
    let meeting: Meeting
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""

    private var cleaned: String? { MeetingTitle.cleaned(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            SectionHeading(
                title: "Rename this meeting",
                eyebrow: "Meeting",
                subtitle: "The list, the notes header and search all use this name. "
                    + "A blank name is refused.",
                orb: meeting.status.orb ?? .breathing
            )

            Form {
                TextField("Name", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned == nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.sheetWidth)
        .onAppear { title = meeting.title }
    }

    private func save() {
        guard let cleaned else { return }
        onSave(cleaned)
        dismiss()
    }
}
