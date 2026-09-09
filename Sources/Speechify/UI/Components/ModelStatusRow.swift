import SwiftUI

/// One local model in Settings: what it is, whether it's here, and the button that fetches it.
///
/// Every downloadable model goes through this row so the states read the same way: a
/// spinner while preparing, a checkmark when ready, a retry when something failed.
struct ModelStatusRow: View {
    let title: String
    let detail: String
    let state: LocalModelStore.State
    let downloadTitle: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: DS.Space.s) {
                statusView
                if state != .ready {
                    Button(buttonTitle, action: action)
                        .disabled(state.isBusy)
                }
            }
        } label: {
            Text(title)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch state {
        case .notDownloaded:
            Text("Not downloaded")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        case .preparing(let message):
            HStack(spacing: DS.Space.xs) {
                // `shaping` — a dotted outline morphing between figures — for a model being
                // fetched and assembled. A spinner says only "wait"; this says something is
                // being formed, which over a 2.7 GB download is the more honest claim.
                ThinkingOrb(state: .shaping, label: "Preparing")
                Text(message)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.warning)
                .lineLimit(2)
        }
    }

    private var buttonTitle: String {
        switch state {
        case .notDownloaded: downloadTitle
        case .preparing: "Preparing…"
        case .ready: "Ready"
        case .failed: "Retry"
        }
    }
}
