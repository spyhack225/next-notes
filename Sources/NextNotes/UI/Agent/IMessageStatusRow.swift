import SwiftUI

/// IM-17f — the consumer pane's iMessage strings, and the row that wears them.
///
/// The activity pane answers in exactly two strings (§3.4): `iMessage ·
/// Connected` and `Last request · 2 min ago` — nothing else, because everything
/// past those lives behind `--imessage-report`. The strings are produced here,
/// as values, so the activity suite holds them without a window; the view below
/// renders them and nothing else.
enum IMessageStatus {
    /// The connected line, verbatim.
    static let connectedTitle = "iMessage · Connected"

    /// The recency line for the last accepted command, or nil when none has been
    /// accepted yet. Abbreviated units (`2 min ago`), deterministic in the
    /// argument clock so the suite holds the exact sentence.
    static func lastRequestLine(lastRequest: Date?, now: Date) -> String? {
        guard let lastRequest else { return nil }
        let seconds = max(0, now.timeIntervalSince(lastRequest))
        let age: String
        if seconds < 60 {
            age = "just now"
        } else if seconds < 3600 {
            age = "\(Int(seconds / 60)) min ago"
        } else if seconds < 86400 {
            age = "\(Int(seconds / 3600)) hr ago"
        } else {
            age = "\(Int(seconds / 86400)) day ago"
        }
        return "Last request · \(age)"
    }
}

/// The rail row: the connected title and, when a command has been accepted, its
/// recency. Renders nothing at all until paired — an unpaired feature has no
/// status to show.
struct IMessageStatusRow: View {
    @State private var paired = false
    @State private var lastRequest: Date?

    var body: some View {
        Group {
            if paired {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(IMessageStatus.connectedTitle)
                        .font(DS.Font.callout)
                    if let line = IMessageStatus.lastRequestLine(lastRequest: lastRequest, now: Date()) {
                        Text(line)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .agentCardSurface()
                .accessibilityElement(children: .combine)
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        let config = RemoteIdentityStore(directory: AppIdentity.applicationSupportDirectory)
            .configuration
        paired = config.isPaired
        lastRequest = config.lastInboundCommandAt.map { Date(timeIntervalSince1970: $0) }
    }
}
