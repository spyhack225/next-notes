import AppKit
import SwiftUI

/// Copies a string to the pasteboard and says so for a moment.
struct CopyButton: View {
    let text: String
    var title = "Copy"
    var help = "Copy to clipboard"

    @State private var didCopy = false

    var body: some View {
        Button {
            text.copyToPasteboard()
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(DS.Motion.copiedFeedback))
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : title, systemImage: didCopy ? "checkmark" : "doc.on.doc")
        }
        .help(help)
        .disabled(text.isEmpty)
        .animation(DS.Motion.standard, value: didCopy)
    }
}

extension String {
    /// One place that knows how the pasteboard is written, for the context menus and
    /// keyboard commands that copy without going through `CopyButton`.
    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(self, forType: .string)
    }
}
