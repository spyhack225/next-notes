import AppKit
import Observation
import SwiftUI

/// Wall-clock stages for one Ask run, shown under the status line and logged as `ask · …`.
struct AskRunTiming: Equatable, Sendable {
    var startedAt = Date()
    /// `LLMProviders.resolve` before the first search (not model cold-start — that sits in TTFT).
    var providerSeconds: Double?
    /// Sum of hybrid retrieve (embed + BM25/cosine) across rounds. Nil until a retrieve finishes.
    var retrieveSeconds: Double?
    /// Generate start → first `.answering` paint (not SEARCH:). True TTFT, including cold load.
    var firstTokenSeconds: Double?
    /// Request start → finished / failed / cancelled.
    var totalSeconds: Double?
    /// When the finished answer was assigned on the main actor (UI render complete).
    var renderSeconds: Double?

    /// Honest display: never floor real work to `0.0s`.
    static func formatSeconds(_ seconds: Double) -> String {
        if seconds < 0.01 { return "<0.01s" }
        if seconds < 1 { return String(format: "%.2fs", seconds) }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return String(format: "%.0fs", seconds)
    }

    func summary(now: Date = Date(), running: Bool) -> String {
        var parts: [String] = []
        if let providerSeconds {
            parts.append("\(Self.formatSeconds(providerSeconds)) model")
        }
        if let retrieveSeconds {
            parts.append("\(Self.formatSeconds(retrieveSeconds)) retrieve")
        }
        if let firstTokenSeconds {
            parts.append("\(Self.formatSeconds(firstTokenSeconds)) first token")
        }
        if let totalSeconds {
            parts.append("\(Self.formatSeconds(totalSeconds)) total")
            if let renderSeconds, renderSeconds > totalSeconds + 0.05 {
                parts.append("\(Self.formatSeconds(renderSeconds)) rendered")
            }
        } else if running {
            parts.append("\(Self.formatSeconds(now.timeIntervalSince(startedAt)))…")
        }
        return parts.joined(separator: " · ")
    }
}

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
        /// Resolving the Agent model — before any search. Used to be lumped into "Searching…".
        case preparing
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
    /// Files of the user's whose *name* matched the question. Shown separately from the
    /// passages, and never as a source for a sentence: nothing read them.
    private(set) var files: [FileHit] = []
    private(set) var answer: KnowledgeAnswer?
    /// Stage timings for the run in flight or the last finished one.
    private(set) var timing: AskRunTiming?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retrieveBegan: Date?
    /// Set on `.generating`; first-token TTFT is measured from here, not request start.
    @ObservationIgnored private var generateBegan: Date?

    var isRunning: Bool { task != nil }

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel()
        asked = text
        partial = ""
        passages = []
        files = []
        answer = nil
        retrieveBegan = nil
        generateBegan = nil
        timing = AskRunTiming(startedAt: Date())
        phase = .preparing
        task = Task { @MainActor [weak self] in
            await self?.run(text)
        }
    }

    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        retrieveBegan = nil
        generateBegan = nil
        if var timing {
            timing.totalSeconds = Date().timeIntervalSince(timing.startedAt)
            self.timing = timing
        }
        phase = .cancelled
    }

    private func run(_ text: String) async {
        defer {
            task = nil
            retrieveBegan = nil
            generateBegan = nil
        }
        guard KnowledgeToolGate.mayRun, let context = KnowledgeIndexer.shared.toolContext else {
            finishTiming()
            phase = .failed("Turn on the knowledge index and let the Agent use it to ask questions.")
            return
        }
        let providerTrace = LatencyTrace.start(.askProvider)
        let providerBegan = Date()
        guard let provider = await LLMProviders.resolve(
            preferring: Settings.shared.agentModelProvider,
            modelID: Settings.shared.openRouterAgentModelID,
            contextTokens: Settings.shared.openRouterAgentContextTokens
        ) else {
            providerTrace.end(note: "unavailable")
            finishTiming()
            phase = .failed("The Agent's model is unavailable.")
            return
        }
        let providerSeconds = Date().timeIntervalSince(providerBegan)
        providerTrace.end(note: provider.id.rawValue)
        if var timing {
            timing.providerSeconds = providerSeconds
            self.timing = timing
        }
        Log.app.info("""
            ask · provider \(provider.id.rawValue, privacy: .public) · \
            \(providerSeconds, format: .fixed(precision: 3))s
            """)
        guard !Task.isCancelled else { return }
        let asker = KnowledgeAsker(context: context, model: ProviderKnowledgeAnswerModel(provider: provider))
        do {
            // The graph answers a cloud model only with its own consent (`KnowledgeGraphScope`).
            let result = try await KnowledgeGraphScope.$reader.withValue(provider.id) {
                try await asker.run(text) { [weak self] event in
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .searching(let round, let query):
                        retrieveBegan = Date()
                        phase = .searching(round: round, query: query)
                    case .retrieved(_, let found):
                        markRetrieveFinished()
                        passages += found
                    case .files(let found):
                        files = found
                    case .generating:
                        markRetrieveFinished()
                        generateBegan = Date()
                        // Passages may already be on screen; leave "Searching…" immediately.
                        phase = .answering
                    case .answering(let snapshot):
                        phase = .answering
                        partial = snapshot
                        if var timing, timing.firstTokenSeconds == nil, let began = generateBegan {
                            timing.firstTokenSeconds = Date().timeIntervalSince(began)
                            self.timing = timing
                        }
                    case .finished:
                        break
                    }
                }
            }
            guard !Task.isCancelled else { return }
            answer = result
            if var timing {
                timing.totalSeconds = Date().timeIntervalSince(timing.startedAt)
                self.timing = timing
            }
            phase = .finished
            if var timing {
                timing.renderSeconds = Date().timeIntervalSince(timing.startedAt)
                self.timing = timing
                Log.app.info("""
                    ask · ui render · \
                    \(timing.renderSeconds!, format: .fixed(precision: 3))s from start · \
                    first token \(timing.firstTokenSeconds.map { String(format: "%.3f", $0) } ?? "—", privacy: .public)s · \
                    retrieve \(timing.retrieveSeconds.map { String(format: "%.3f", $0) } ?? "—", privacy: .public)s · \
                    model \(timing.providerSeconds.map { String(format: "%.3f", $0) } ?? "—", privacy: .public)s · \
                    total \(timing.totalSeconds!, format: .fixed(precision: 3))s
                    """)
            }
        } catch is CancellationError {
            finishTiming()
            phase = .cancelled
        } catch {
            guard !Task.isCancelled else { return }
            finishTiming()
            phase = .failed(error.localizedDescription)
        }
    }

    private func finishTiming() {
        guard var timing else { return }
        if timing.totalSeconds == nil {
            timing.totalSeconds = Date().timeIntervalSince(timing.startedAt)
        }
        self.timing = timing
    }

    private func markRetrieveFinished() {
        guard let began = retrieveBegan else { return }
        retrieveBegan = nil
        guard var timing else { return }
        timing.retrieveSeconds = (timing.retrieveSeconds ?? 0) + Date().timeIntervalSince(began)
        self.timing = timing
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
                        timingLine
                        content
                        fileList
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
        case .preparing:
            Label("Getting the model ready…", systemImage: "hourglass")
                .foregroundStyle(DS.Color.textSecondary)
        case .searching(let round, let query):
            Label(round == 1 ? "Searching for \u{201c}\(query)\u{201d}…"
                  : "Searching again (\(round) of \(KnowledgeAsker.maxRounds)) for \u{201c}\(query)\u{201d}…",
                  systemImage: "magnifyingglass")
                .foregroundStyle(DS.Color.textSecondary)
        case .answering:
            Label(
                "Writing the answer from \(session.passages.count) passages…",
                systemImage: "text.quote"
            )
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
    private var timingLine: some View {
        if let timing = session.timing, session.phase != .idle {
            if session.isRunning {
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text(timing.summary(now: context.date, running: true))
                        .font(DS.Font.timestamp)
                        .foregroundStyle(DS.Color.textTertiary)
                        .accessibilityLabel("Ask timing")
                }
            } else {
                Text(timing.summary(running: false))
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textTertiary)
                    .accessibilityLabel("Ask timing")
            }
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

    /// Files whose name matched, kept well away from the citations.
    ///
    /// Deliberately not a source chip: a chip says "this sentence came from here", and
    /// nothing has read these files. The line above them says so in plain words, so nobody
    /// reads a matching file name as evidence of what is inside it.
    @ViewBuilder
    private var fileList: some View {
        if !session.files.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Files on your Mac with a matching name. Next Notes hasn’t looked inside them.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                FlowLayout(spacing: DS.Space.xs) {
                    ForEach(session.files) { file in
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                        } label: {
                            Label(file.name, systemImage: file.isDirectory ? "folder" : file.category.symbol)
                                .font(DS.Font.chip)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Show \(file.path) in Finder")
                    }
                }
            }
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
