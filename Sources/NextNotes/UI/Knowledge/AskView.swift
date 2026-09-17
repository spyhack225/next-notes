import Observation
import SwiftUI

/// One question at a time against the knowledge index: the job, its progress, its answer.
///
/// Kept outside the view so an answer that takes a minute survives switching sections, and
/// so Stop works from wherever the view is when it comes back.
@MainActor
@Observable
final class KnowledgeAskSession {
    static let shared = KnowledgeAskSession()

    enum Phase: Equatable {
        case idle
        case searching(round: Int, query: String)
        case answering
        case finished
        case cancelled
        case failed(String)
    }

    var question = ""
    private(set) var asked = ""
    private(set) var phase: Phase = .idle
    /// The answer as it streams, markers included.
    private(set) var partial = ""
    /// Every passage read so far, across rounds.
    private(set) var passages: [KnowledgeCitation] = []
    private(set) var answer: KnowledgeAnswer?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel()
        asked = text
        partial = ""
        passages = []
        answer = nil
        phase = .searching(round: 1, query: text)
        task = Task { @MainActor [weak self] in
            await self?.run(text)
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        phase = .cancelled
    }

    private func run(_ text: String) async {
        defer { task = nil }
        guard KnowledgeToolGate.mayRun, let context = KnowledgeIndexer.shared.toolContext else {
            phase = .failed("Turn on the knowledge index and let the Agent use it to ask questions.")
            return
        }
        guard let provider = await LLMProviders.resolve(
            preferring: Settings.shared.agentModelProvider,
            modelID: Settings.shared.openRouterAgentModelID,
            contextTokens: Settings.shared.openRouterAgentContextTokens
        ) else {
            phase = .failed("The Agent's model is unavailable.")
            return
        }
        guard !Task.isCancelled else { return }
        let asker = KnowledgeAsker(context: context, model: ProviderKnowledgeAnswerModel(provider: provider))
        do {
            let result = try await asker.run(text) { [weak self] event in
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .searching(let round, let query):
                    phase = .searching(round: round, query: query)
                case .retrieved(_, let found):
                    passages += found
                case .answering(let snapshot):
                    phase = .answering
                    partial = snapshot
                case .finished:
                    break
                }
            }
            guard !Task.isCancelled else { return }
            answer = result
            phase = .finished
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Ask: a question, a streaming answer, and a chip for every source each sentence cites.
///
/// A transcript chip jumps to the second in the meeting's transcript; a notes chip opens the
/// meeting. A sentence the model wrote without a valid citation is shown as unsourced
/// rather than hidden, so a wrong answer is visible as one.
struct AskView: View {
    @State private var session = KnowledgeAskSession.shared
    @State private var settings = Settings.shared
    @State private var navigation = NavigationState.shared
    @State private var showsPassages = false

    var body: some View {
        if settings.knowledgeAgentToolsEnabled {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                field
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        status
                        content
                        passageList
                    }
                    .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(DS.Space.page)
        } else {
            OrbUnavailableView(
                .searching,
                title: "Ask is off",
                message: "Let the Agent answer from the knowledge index. Answers cite the passage and "
                    + "the second of the recording each sentence came from."
            ) {
                Button("Let the Agent use the index") { settings.knowledgeAgentToolsEnabled = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var field: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask about your meetings, notes and conversations", text: $session.question)
                .textFieldStyle(.roundedBorder)
                .onSubmit { session.ask() }
                .disabled(session.isRunning)
            if session.isRunning {
                Button("Stop") { session.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Ask") { session.ask() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .idle:
            EmptyView()
        case .searching(let round, let query):
            Label(round == 1 ? "Searching for \u{201c}\(query)\u{201d}…"
                  : "Searching again (\(round) of \(KnowledgeAsker.maxRounds)) for \u{201c}\(query)\u{201d}…",
                  systemImage: "magnifyingglass")
                .foregroundStyle(DS.Color.textSecondary)
        case .answering:
            Label("Writing the answer from \(session.passages.count) passages…", systemImage: "text.quote")
                .foregroundStyle(DS.Color.textSecondary)
        case .finished:
            EmptyView()
        case .cancelled:
            Label("Stopped.", systemImage: "stop.circle")
                .foregroundStyle(DS.Color.textSecondary)
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(DS.Color.warning)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let answer = session.answer {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(session.asked)
                    .font(DS.Font.headline)
                ForEach(Array(answer.claims.enumerated()), id: \.offset) { _, claim in
                    ClaimRow(claim: claim, answer: answer, open: open)
                }
                if answer.claims.isEmpty {
                    Text(KnowledgeAnswer.notFound)
                }
                if !answer.invalidMarkers.isEmpty {
                    Text("Ignored citations to passages the model was not shown: "
                         + answer.invalidMarkers.joined(separator: ", "))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
        } else if !session.partial.isEmpty {
            Text(KnowledgeAnswerParser.stripMarkers(session.partial))
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var passageList: some View {
        if !session.passages.isEmpty {
            DisclosureGroup("Passages read (\(session.passages.count))", isExpanded: $showsPassages) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(session.passages) { passage in
                        Button { open(passage) } label: {
                            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                Text(passage.label)
                                    .font(DS.Font.chip)
                                    .foregroundStyle(DS.Color.accent)
                                Text(passage.text)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.textSecondary)
                                    .lineLimit(3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, DS.Space.xs)
            }
            .font(DS.Font.caption)
        }
    }

    private func open(_ citation: KnowledgeCitation) {
        switch citation.target {
        case .meeting(let id, let seconds):
            if let seconds { navigation.show(meeting: id, at: seconds) } else { navigation.show(meeting: id) }
        case .conversation:
            navigation.showConversation()
        case .routines:
            navigation.showRoutines()
        case .dictation:
            navigation.show(.dictation)
        case .unavailable:
            break
        }
    }
}

/// One sentence and its source chips.
private struct ClaimRow: View {
    let claim: KnowledgeClaim
    let answer: KnowledgeAnswer
    let open: (KnowledgeCitation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(claim.text)
                .textSelection(.enabled)
            FlowLayout(spacing: DS.Space.xs) {
                if claim.chunkIDs.isEmpty {
                    Label("No source", systemImage: "questionmark.circle")
                        .font(DS.Font.chip)
                        .foregroundStyle(DS.Color.warning)
                }
                ForEach(claim.chunkIDs.compactMap(answer.citation), id: \.chunkID) { citation in
                    Button { open(citation) } label: {
                        Label(citation.label, systemImage: citation.startTime == nil ? "doc.text" : "waveform")
                            .font(DS.Font.chip)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(citation.text)
                }
            }
        }
    }
}
