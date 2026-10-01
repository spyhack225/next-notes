import AppKit
import SwiftUI

/// The "agent is working" surface (P1-1) — the pane's half.
///
/// Above the composer while a task runs: a status pill with Stop, a live view of the
/// current operation reported by the run, the step
/// list with ✓ / ◐ rows that expand into the arguments that would run, the approval
/// card inline the moment one belongs to this task, and on completion a terminal result
/// card carrying the result and its artifact links. The persistent AI disclaimer is the
/// footer (P2-6).
///
/// Step titles come from `AgentActivityStore` — consumer words only, never tool ids and
/// never chain-of-thought (`AgentActivityProjector.isPublic` is the gate).
struct AgentWorkingCard: View {
    let task: AgentTask
    let stop: () -> Void
    var animatesActivity = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = AgentActivityStore.shared
    @State private var identity = AgentIdentityStore.shared
    @State private var gate = PermissionGate.shared
    @State private var reviewStore = ToolCallReviewStore.shared
    @State private var expandedStep: String?

    private var steps: [AgentStep] {
        store.steps(taskID: task.id)
    }

    /// Reads the same task-scoped step in the preview and in the fixture below.
    static func currentStep(taskID: String, in store: AgentActivityStore) -> AgentStep? {
        store.steps(taskID: taskID).last
    }

    static func currentPreview(taskID: String, in store: AgentActivityStore) -> AgentWorkPreview? {
        let step = currentStep(taskID: taskID, in: store)
        return step?.isCompleted == false ? step?.preview : nil
    }

    private var currentPreview: AgentWorkPreview? {
        Self.currentPreview(taskID: task.id, in: store)
    }

    private var currentStep: AgentStep? {
        Self.currentStep(taskID: task.id, in: store)
    }

    private var isRunning: Bool {
        task.status == .running || task.status == .queued || task.status == .waitingForPermission
    }

    /// A persisted task may name a direct tool, or a multi-step backend with no single
    /// tool. Only the catalogue can establish the former's risk; the latter gets no Retry.
    static func retryRisk(for task: AgentTask) -> AgentRisk? {
        guard let tool = task.tool else { return nil }
        return AgentToolRegistry.shared.tool(named: tool)?.risk
    }

    /// The approval card belongs here when the pending request names this task.
    private var inlineReview: ToolCallReview? {
        guard let pending = gate.pending, pending.taskID == task.id else { return nil }
        return gate.pendingReview ?? reviewStore.review(for: pending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            pill
            if isRunning {
                liveView
                stepList
                if let inlineReview {
                    ToolReviewCard(
                        review: inlineReview,
                        isCompact: true,
                        approve: {
                            gate.respond(
                                id: inlineReview.id,
                                approved: true,
                                duration: .once,
                                scope: gate.pending?.scope ?? .any
                            )
                        },
                        dismiss: { gate.respond(id: inlineReview.id, approved: false) },
                        alwaysAllow: !gate.pendingAllowsStandingGrant || gate.pending?.scope.kind == .any ? nil : {
                            gate.respond(
                                id: inlineReview.id,
                                approved: true,
                                duration: .alwaysThisAction,
                                scope: gate.pending?.scope ?? .any
                            )
                        }
                    )
                }
            } else {
                terminalCard
            }
            disclaimer
        }
        .padding(DS.Space.cardTight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: DS.Radius.card)
    }

    // MARK: - Status pill

    private var pill: some View {
        HStack(spacing: DS.Space.s) {
            if isRunning {
                // The character, doing what this run's current step is doing. It replaces
                // the plain status dot rather than joining it: a working card is the one
                // place a run is explained, and two marks saying "running" is one too many.
                AgentAvatarView(
                    config: identity.avatar,
                    state: currentPreview?.isYielded == true ? .waiting : steps.last?.avatar ?? .thinking,
                    size: DS.Size.agentAvatar,
                    frozenAt: animatesActivity ? nil : AgentAvatarChoreography.stillFrame
                )
            } else {
                Circle()
                    .fill(DS.Color.textSecondary)
                    .frame(width: DS.Size.orbBadge * 0.35, height: DS.Size.orbBadge * 0.35)
            }
            Text(isRunning ? "\(currentPreview?.isYielded == true ? "Paused" : "Working") · \(task.objective)" : task.status.humanState)
                .font(DS.Font.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let total = stepCounter {
                Text(total)
                    .font(DS.Font.counterSmall)
                    .monospacedDigit()
                    .foregroundStyle(DS.Color.textSecondary)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            if isRunning {
                Button("Stop", action: stop)
                    .controlSize(.small)
            }
        }
    }

    private var stepCounter: String? {
        guard !steps.isEmpty else { return nil }
        let completed = steps.count(where: \.isCompleted)
        return "\(min(completed + 1, steps.count))/\(steps.count)"
    }

    // MARK: - Live view

    /// Context arrives from the backing with the task and step captured at tool entry.
    /// The UI never polls the shared vision image slot or guesses from model output.
    private var liveView: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(currentPreview?.isYielded == true ? "You have the Mac" : "Current step")
                    .font(DS.Font.sectionLabel)
                    .foregroundStyle(DS.Color.textSecondary)
                if currentPreview?.isYielded == true {
                    Text("Paused while you’re using your Mac.")
                        .font(DS.Font.callout)
                    Text("Tell me what to do next when you’re ready.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                } else if let step = currentStep {
                    Text(step.title)
                        .font(DS.Font.callout)
                    if let preview = currentPreview {
                        if let data = preview.thumbnail, let image = NSImage(data: data) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: DS.Size.messagePreviewHeight)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                .accessibilityHidden(true)
                        }
                        Text(preview.summary)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Getting started…")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: DS.Size.messagePreviewHeight / 2, alignment: .leading)
            .animation(reduceMotion ? nil : DS.Motion.standard, value: currentPreview)
        }
    }

    // MARK: - Steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, number: index + 1)
            }
        }
    }

    private func stepRow(_ step: AgentStep, number: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                // ✓ done, ◐ in progress. One step is ever in progress: the newest
                // unfinished one.
                Image(systemName: step.isCompleted ? "checkmark.circle" : "circle.bottomhalf.filled")
                    .foregroundStyle(step.isCompleted ? DS.Color.success : DS.Color.accent)
                    .frame(width: DS.Size.orbBadge * 0.4)
                Text(step.title)
                    .font(DS.Font.callout)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !step.detail.isEmpty {
                    Button(expandedStep == step.id ? "Hide" : "Details") {
                        expandedStep = expandedStep == step.id ? nil : step.id
                    }
                    .buttonStyle(.borderless)
                    .font(DS.Font.chip)
                }
            }
            if expandedStep == step.id, !step.detail.isEmpty {
                // The tool's own arguments, as fields — never raw ids on the top line.
                Text(step.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, DS.Size.orbBadge * 0.5)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.isCompleted ? "Done" : "Working on"): \(step.title)")
    }

    // MARK: - Terminal result

    private var terminalCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if task.status == .failed, task.failure != nil {
                FailureCard.forTask(
                    task,
                    // An ACP/multi-step task has no single tool risk. No retry is offered
                    // until the existing task record can prove it is safe to repeat.
                    retryRisk: Self.retryRisk(for: task),
                    retry: {
                        AgentTaskManager.shared.submit(
                            objective: task.objective,
                            tool: task.tool,
                            arguments: task.arguments,
                            contextReferences: task.contextReferences,
                            meetingID: task.meetingID,
                            source: task.source
                        )
                    },
                    openResult: task.artifacts.isEmpty ? nil : { openArtifacts() }
                )
            } else {
                if let result = task.result {
                    Text(result)
                        .font(DS.Font.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !task.artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("What I made")
                            .font(DS.Font.sectionLabel)
                        ForEach(task.artifacts, id: \.self) { artifact in
                            artifactLink(artifact)
                        }
                    }
                }
                // P1-6: one button for the action this result makes obvious, when the
                // result determines every argument. It is the sentence the user would
                // otherwise have had to type; pressing it submits ordinary work that
                // still goes through the permission gate.
                if let offer = followUpOffer {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(offer.sentence)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        Button(offer.title) {
                            AgentTaskManager.shared.submit(
                                objective: offer.sentence,
                                tool: offer.toolID,
                                arguments: offer.arguments,
                                source: "user"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.top, DS.Space.xxs)
                }
            }
        }
    }

    /// Built only for a finished read whose result names exactly one page. Nil is the
    /// ordinary answer.
    private var followUpOffer: FollowUpOffer? {
        guard task.status == .completed, let tool = task.tool, let result = task.result else {
            return nil
        }
        return FollowUpOfferBuilder.offer(for: tool, result: result)
    }

    @ViewBuilder
    private func artifactLink(_ artifact: String) -> some View {
        // A URL is a link; a file reference or a doc id is copyable text. Both are
        // consumer names — "Library" items, never "artifacts".
        if let url = URL(string: artifact), url.scheme == "http" || url.scheme == "https" {
            Link(artifact, destination: url)
                .font(DS.Font.caption)
        } else {
            Text(artifact)
                .font(DS.Font.caption)
                .textSelection(.enabled)
        }
    }

    private func openArtifacts() {
        for artifact in task.artifacts {
            if let url = URL(string: artifact), url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - P2-6

    private var disclaimer: some View {
        Text("Next Notes is AI and can make mistakes.")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Step-row self-test fixture

extension AgentWorkingCard {
    /// The `--selftest-island` 4-step fixture (P1-1 verify): a scripted run produces
    /// four rows and exactly one of them in progress. Pure — walks the store, no view
    /// and no screen.
    @MainActor
    static func scriptedFourStepFailures() -> [String] {
        var failures: [String] = []
        let store = AgentActivityStore.shared
        let task = AgentTask(objective: "Buying tickets", source: "selftest")
        store.begin(task: task, title: task.objective)
        store.update(taskID: task.id, kind: .executing, title: "Opened Chrome \u{2014} youtube.com")
        store.update(taskID: task.id, kind: .searching, title: "Found tonight\u{2019}s 7:30 showing")
        store.update(taskID: task.id, kind: .executing, title: "Chose two seats, middle block \u{2014} C1 and C2")
        store.update(taskID: task.id, kind: .executing, title: "Checking the price against your $40 cap\u{2026}")

        let rows = store.steps(taskID: task.id)
        if rows.count != 4 {
            failures.append("a 4-step scripted run produced \(rows.count) rows, not 4")
        }
        let inProgress = rows.count { !$0.isCompleted }
        if inProgress != 1 {
            failures.append("a 4-step scripted run had \(inProgress) steps in progress, not exactly 1")
        }
        if rows.last?.isCompleted == true {
            failures.append("the newest step of a running task is marked done")
        }
        let feed = store.liveSteps
        if feed.titles.count != 4 {
            failures.append("the live step feed carried \(feed.titles.count) titles, not 4")
        }
        if feed.current != 4 {
            failures.append("the live step feed pointed at step \(feed.current), not the 4th")
        }
        if feed.total != 4 {
            failures.append("the live step feed totalled \(feed.total), not 4")
        }
        for title in feed.titles where !AgentActivityProjector.isPublic(title) {
            failures.append("a step title was not public: \(title)")
        }

        store.finish(taskID: task.id, title: "Done")
        if store.inProgressStepCount != 0 {
            failures.append("a finished run left \(store.inProgressStepCount) steps in progress")
        }
        let other = AgentTask(objective: "A different window", source: "selftest")
        store.begin(task: other, title: other.objective)
        store.update(taskID: other.id, kind: .reading, title: "Looking at the other window")
        if Self.currentStep(taskID: task.id, in: store)?.title
            != "Checking the price against your $40 cap…" {
            failures.append("the first task's preview followed another run's newer step")
        }
        if Self.currentStep(taskID: other.id, in: store)?.title
            != "Looking at the other window" {
            failures.append("the second task's preview did not use its own step")
        }
        store.resetForSelfTest()
        return failures
    }
}
