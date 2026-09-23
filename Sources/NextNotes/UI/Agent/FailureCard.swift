import SwiftUI

/// A failed action, said honestly (§8.2).
///
/// Frame-verified anatomy: line one states exactly what did and did not happen, the
/// next line says what there is to undo — by name, or "nothing to undo" — and then at
/// most two buttons offer a way forward. A failure card is never a dead-end sentence.
///
/// Retry buttons only appear for work whose risk is `<= .modify`: a send that already
/// left cannot be recalled by trying again, and offering the button would imply it
/// could.
struct FailureCard: View {
    /// One way forward. At most two are ever shown.
    struct NextAction: Identifiable {
        let id: String
        let title: String
        var isProminent = false
        let run: () -> Void
    }

    /// What did and did not happen. The failure itself, plus the "nothing was created
    /// or sent" half the error text never carries.
    let summary: String
    /// The explicit undo line. "Nothing was added anywhere, so nothing to undo." or
    /// "Undid the draft to Marie."
    let undo: String
    var actions: [NextAction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(DS.Color.warning)
                Text(summary)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(undo)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !actions.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(actions.prefix(2)) { action in
                        if action.isProminent {
                            Button(action.title, action: action.run)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title, action: action.run)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(summary) \(undo)")
    }

    /// The task-shaped builder: the summary and the undo come off the task itself, and
    /// a retry is offered only when the work is safe to repeat.
    @MainActor
    static func forTask(
        _ task: AgentTask,
        retryRisk: AgentRisk,
        retry: @escaping () -> Void,
        openResult: (() -> Void)? = nil
    ) -> FailureCard {
        var actions: [NextAction] = []
        // P1-4 / §8.2: retry is `risk <= .modify` only. A send is never re-offered.
        if retryRisk <= .modify {
            actions.append(NextAction(id: "retry", title: "Try again", isProminent: true, run: retry))
        }
        if !task.artifacts.isEmpty, let openResult {
            actions.append(NextAction(id: "open", title: "Open what I made", run: openResult))
        }
        return FailureCard(
            summary: task.failureSummary,
            undo: task.failureUndoLine,
            actions: actions
        )
    }
}
