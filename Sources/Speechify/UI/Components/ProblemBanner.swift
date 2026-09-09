import SwiftUI

/// A dismissible failure, shown above a section rather than in a modal: something that
/// didn't work is worth reading, not worth interrupting for.
///
/// Shared because the two failures a meeting can hand the user — one that wouldn't start,
/// and notes that wouldn't be written — read the same way and should look the same.
/// The retry is optional and comes before Dismiss, because a failure the user can do
/// something about should offer that in the same glance that told them about it — a banner
/// whose only control is "go away" makes them hunt through a menu for the second half.
struct ProblemBanner: View {
    let message: String
    var retryTitle: String = "Try again"
    var retry: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(DS.Color.warning)
            Text(message)
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let retry {
                Button(retryTitle, action: retry)
                    .buttonStyle(.link)
            }
            Button("Dismiss", action: dismiss)
                .buttonStyle(.link)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(DS.Color.groupedFill)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
