import AppKit
import SwiftUI

/// Correcting one past dictation.
///
/// **Why this is not inside the row.** It used to be: an editor and a Save/Cancel pair were
/// added to the row in place of the sentence, and the Save and Cancel buttons were cut in
/// half by the bottom edge of the row. A `List` on macOS is an `NSTableView`, and a row
/// whose content grows *after* it has been measured keeps the height it was measured at —
/// so the editor took the space the sentence used to have and the buttons were drawn past
/// the end of the row and clipped. There is no arrangement of a growing editor and a button
/// bar inside a list row that is safe from that, and the row has two further problems of
/// its own: the list owns Delete, ⌘A and the arrow keys for selection, and a text field
/// sitting inside a selected row spends its life arguing with them.
///
/// So the correction happens in a sheet, where the editor can grow with what is typed, stop
/// at a height that still leaves the buttons on screen, and scroll past that — and where
/// Save and Cancel are simply always visible, at any window width.
struct TranscriptEditorSheet: View {
    let original: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var editorFocused: Bool

    init(original: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.original = original
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: original)
    }

    /// The sheet's width, fixed. The window's own minimum is far wider, and a measure that
    /// changes under the pointer is worse than one chosen once: the editor's height is
    /// computed from this width, so a width that moved would make the box jump.
    static let width: CGFloat = 520
    /// Room for about four lines. Short dictations still get a box that looks like one.
    static let minEditorHeight: CGFloat = 96
    /// Where growth stops and scrolling begins. Deliberately well short of the screen: the
    /// buttons below have to stay visible for a dictation of any length, which is the whole
    /// point of this file.
    static let maxEditorHeight: CGFloat = 320

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Correct this transcript")
                    .font(DS.Font.title3)
                Text("Fix anything it misheard. The correction is kept with this recording.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $draft)
                .font(DS.Font.transcript)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(DS.Space.s)
                .frame(height: editorHeight)
                .background(DS.Color.content, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Color.separator, lineWidth: 1)
                }
                .animation(DS.Motion.standard, value: editorHeight)

            HStack(spacing: DS.Space.s) {
                // Named in words rather than as ⌘↩ and ⎋. The people this app is for do not
                // read glyphs off a keyboard, and the two shortcuts are the reason the
                // buttons can be reached without a mouse at all.
                Text("Command-Return saves. Escape cancels.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    // Not `.defaultAction`: Return belongs to the editor, where it starts a
                    // new line. ⌘-Return is the system's answer to that everywhere else.
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(DS.Space.l)
        .frame(width: Self.width)
        .onAppear { editorFocused = true }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }

    /// Grows with the text and then stops.
    ///
    /// Measured rather than left to the editor to discover for itself: a `TextEditor` that
    /// finds its own height inside a container reports it after the fact, and "after the
    /// fact" is exactly what clipped the buttons in the list row this replaced. Here the
    /// height is a pure function of the draft and a fixed width, so the layout is settled
    /// before anything is drawn.
    private var editorHeight: CGFloat { Self.editorHeight(for: draft) }

    /// Static and pure so `--selftest-commandkey` can assert the contract this file exists
    /// for: that the box grows, that it stops, and therefore that what sits under it is
    /// always still on screen.
    static func editorHeight(for text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let available = width - DS.Space.l * 2 - DS.Space.s * 2
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        ).height
        // One line of slack so the caret on a fresh final line is never the thing that
        // pushes the text out of view.
        let wanted = ceil(measured) + font.boundingRectForFont.height + DS.Space.s * 2
        return min(max(wanted, minEditorHeight), maxEditorHeight)
    }
}
