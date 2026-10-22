import Foundation

/// Actual reviewer/model-prompt/writer and actual index->harvest consumers, with
/// authored synthetic facts only. No owner index, model inference or extra store.
@MainActor
enum MemoryReviewReaderHarvestSelfTest {
    static func failures(root: URL) async -> [String] {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, resolved.path.hasPrefix(temporary.path + "/"),
              !resolved.pathComponents.contains("Application Support") else {
            return ["reader harvest: isolated diagnostic root required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append("reader harvest: " + name) }
        }
        let seedPairs = [("colleague", "Rowan"), ("pet", "Willow"), ("club", "Coral"),
                         ("camera", "Onyx"), ("mentor", "Lumen"), ("university", "Iris"),
                         ("band", "Juniper"), ("workshop", "Indigo")]
        let newPairs = [("laboratory", "Rowan"), ("hometown", "Nila"), ("team", "Sage"),
                        ("garden", "Marina"), ("publisher", "Ember"), ("studio", "Rhea"),
                        ("editor", "Aster"), ("neighbour", "Cedar"), ("supervisor", "Vale"),
                        ("partner", "Nico")]
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        var allProposals = 0
        var echoProposals = 0
        var comparisonSeeds: [MemoryEntry] = []
        do {
            for (index, pair) in newPairs.enumerated() {
                let store = NextMemory(directory: root.appendingPathComponent("echo-\(index)"), now: { epoch })
                for seed in seedPairs {
                    try store.remember(kind: .profile, text: "The user's \(seed.0) is \(seed.1).", source: .manual)
                }
                let seeded = store.entries
                comparisonSeeds = seeded
                guard seeded.count == 8 else { return failures + ["reader harvest: eight distinct seeds not admitted"] }
                let input = "My \(pair.0) is \(pair.1)."
                let fact = "The user's \(pair.0) is \(pair.1)."
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [input], untrustedText: [], occurredAt: epoch)
                let capture = MemoryReviewPromptCapture()
                let model = ScriptedMemoryReviewModel(contextTokens: 4_096) { system, prompt in
                    let memory = MemoryReviewPromptCapture.memoryRows(prompt)
                    let proposed = memory.map { $0["text"] ?? "" } + [fact]
                    capture.record(prompt: prompt, proposed: proposed, system: system)
                    return MemoryReviewPromptCapture.toolCalls(proposed)
                }
                let outcome = try await MemoryReviewer.review(job, model: model, writer: StoreMemoryReviewWriter(store: store))
                let snapshot = capture.snapshot()
                allProposals += snapshot.proposed.count
                echoProposals += snapshot.proposed.filter { fact in seeded.contains { MemoryGuard.saysTheSameFact(fact, $0.text) } }.count
                check("echo \(index) uses one existing model pass", model.callCount == 1 && outcome.modelCalled)
                check("echo \(index) proposals equal actual model output", outcome.proposed == snapshot.proposed.count)
                if index == 0 {
                    check("actual model receives saved-facts system wording", snapshot.system.contains("anything in the facts already saved")
                        && !snapshot.system.contains("anything already in current memory"))
                }
                check("echo \(index) keeps the original saved entries", seeded.allSatisfy { old in store.entries.contains { $0.id == old.id && $0.text == old.text } })
                check("echo \(index) admits the new current-user fact", outcome.saved.count == 1 && outcome.saved.first?.text == fact
                    && outcome.saved.first?.sessionID == job.sessionID && outcome.saved.first?.source == .review)
                if index != 0 {
                    check("echo \(index) no unrelated memory reaches model", seeded.allSatisfy { !snapshot.prompt.contains($0.text) })
                } else {
                    check("echo matching job includes only its one relevant saved fact", MemoryReviewPromptCapture.memoryRows(snapshot.prompt).map { $0["text"] ?? "" } == [seeded[0].text])
                }
            }
            let share = allProposals == 0 ? 1 : Double(echoProposals) / Double(allProposals)
            print(String(format: "MEMORY_REVIEW_ECHO_SHARE %.3f (%d/%d proposals)", share, echoProposals, allProposals))
            check("echo share below unchanged 15 percent threshold", share < 0.15)
            check("actual relevant prompt has exactly one echo over ten new facts", echoProposals == 1 && allProposals == 11)

            // Exact threshold and cap are exercised through the SAME review call,
            // without using a helper-only or model-generated relevant-memory result.
            for window in [8_192, 8_193] {
                let store = NextMemory(directory: root.appendingPathComponent("window-\(window)"))
                for row in comparisonSeeds { try store.remember(kind: row.kind, text: row.text, source: .manual) }
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: ["My laboratory is Rowan."], untrustedText: [], occurredAt: epoch)
                let capture = MemoryReviewPromptCapture()
                let model = ScriptedMemoryReviewModel(contextTokens: window) { _, prompt in
                    capture.record(prompt: prompt, proposed: [])
                    return "NONE"
                }
                let before = store.entries
                let outcome = try await MemoryReviewer.review(job, model: model, writer: StoreMemoryReviewWriter(store: store))
                let rows = MemoryReviewPromptCapture.memoryRows(capture.snapshot().prompt)
                check("window \(window) exact existing reader threshold", rows.count == (window <= 8_192 ? 1 : 8))
                check("window \(window) consumes renamed data heading", capture.snapshot().prompt.contains("Facts already saved — do not repeat (data): "))
                check("window \(window) no mutation or extra model pass", before == store.entries && outcome.saved.isEmpty && model.callCount == 1)
            }
            var at = epoch
            let rankedStore = NextMemory(directory: root.appendingPathComponent("ranked"), now: { at })
            for row in comparisonSeeds {
                at += 1
                try rankedStore.remember(kind: row.kind, text: row.text, source: .manual)
            }
            let rankedJob = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                userText: ["Colleague Rowan Willow Coral Onyx Lumen Iris Juniper Indigo."], untrustedText: [], occurredAt: epoch)
            let rankedCapture = MemoryReviewPromptCapture()
            let rankedModel = ScriptedMemoryReviewModel(contextTokens: 4_096) { _, prompt in
                rankedCapture.record(prompt: prompt, proposed: []); return "NONE"
            }
            _ = try await MemoryReviewer.review(rankedJob, model: rankedModel, writer: StoreMemoryReviewWriter(store: rankedStore))
            let expected = [rankedStore.entries[0].text]
                + rankedStore.entries.dropFirst().sorted { $0.createdAt > $1.createdAt }.prefix(4).map(\.text)
            check("cap five ranks overlap before recency", MemoryReviewPromptCapture.memoryRows(rankedCapture.snapshot().prompt).map { $0["text"] ?? "" } == expected)

            let sessionID = UUID()
            let backgroundRows = [
                AgentSession.Message(role: "user", text: comparisonSeeds[0].text, at: epoch, source: "text", sessionID: sessionID),
                AgentSession.Message(role: "user", text: "My partner is Nico.", at: epoch + 2, source: "text", sessionID: sessionID),
                AgentSession.Message(role: "assistant", text: comparisonSeeds[1].text, at: epoch + 3, sessionID: sessionID),
            ]
            guard let currentJob = MemoryReviewJob(AgentSession.ReviewRequest(sessionID: sessionID, reason: .idle,
                messages: backgroundRows), reviewedThrough: epoch) else {
                return failures + ["reader harvest: actual current-user job unavailable"]
            }
            let currentCapture = MemoryReviewPromptCapture()
            let currentModel = ScriptedMemoryReviewModel(contextTokens: 4_096) { _, prompt in
                currentCapture.record(prompt: prompt, proposed: []); return "NONE"
            }
            let beforeCurrent = rankedStore.entries
            let currentResult = try await MemoryReviewer.review(currentJob, model: currentModel,
                writer: StoreMemoryReviewWriter(store: rankedStore))
            check("real job preserves earlier and untrusted data", currentJob.earlier.contains { $0.text == comparisonSeeds[0].text }
                && currentJob.untrustedText.contains(comparisonSeeds[1].text))
            check("only fresh user turns rank saved facts", MemoryReviewPromptCapture.memoryRows(currentCapture.snapshot().prompt).isEmpty)
            check("current projection leaves prior rows and authority unchanged", currentModel.callCount == 1
                && currentResult.saved.isEmpty && rankedStore.entries == beforeCurrent)

            let short = ["My brother is Cyril.", "I live in Paris.", "Call me Serge."]
            let raw = short + ["okay", "yeah, sure", "Thanks!"]
            let indexDirectory = root.appendingPathComponent("index")
            try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
            let index = KnowledgeStore(directory: indexDirectory)
            let sourceID = UUID().uuidString
            try index.replace(kind: .dictation, sourceID: sourceID, chunks: raw.enumerated().map {
                KnowledgeChunk(ordinal: $0.offset, text: $0.element, occurredAt: Int64(epoch.timeIntervalSince1970))
            })
            let chunksBefore = try index.chunkRows(kind: .dictation, sourceID: sourceID)
            check("short source stores six unchanged real index rows", chunksBefore.map(\.text) == raw)
            check("short sentence filter preserves exactly three facts", MemoryHarvest.sentences(raw) == short)
            let jobs = MemoryHarvest.dictationJobs(store: index)
            check("actual harvest emits one source-bound job", jobs.count == 1 && jobs.first?.source == .userDictated
                && jobs.first?.sourceKey == "dictation:" + sourceID)
            check("actual harvest job contains exact three user facts", jobs.first?.turns.map(\.text) == short)
            let shortStore = NextMemory(directory: root.appendingPathComponent("short-facts"))
            let shortModel = ScriptedMemoryReviewModel { _, _ in MemoryReviewPromptCapture.toolCalls([
                "The user's brother is Cyril.", "The user lives in Paris.", "The user's name is Serge."
            ]) }
            var result: MemoryReviewOutcome?
            if let job = jobs.first {
                result = try await MemoryReviewer.review(job, model: shortModel, writer: StoreMemoryReviewWriter(store: shortStore))
            }
            check("actual harvested short facts reach one review pass", shortModel.callCount == 1 && result?.modelCalled == true)
            check("actual harvested short facts reach guarded persistent writer", result?.saved.count == 3 && shortStore.entries.count == 3
                && shortStore.entries.allSatisfy { $0.source == .review && $0.origin == .userDictated && $0.lineage != nil })
            check("harvest does not rewrite source rows", try index.chunkRows(kind: .dictation, sourceID: sourceID).map(\.text) == raw)
            check("existing per-job budget and call cap retained", MemoryHarvest.charactersPerJob == 6_000 && MemoryReviewer.maxCalls == 5)
        } catch { failures.append("reader harvest: isolated actual consumer threw " + String(describing: type(of: error))) }
        SelfTest.diagnostic("MEMORY_REVIEW_READER_HARVEST_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }
}

private final class MemoryReviewPromptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var prompt = ""
    private var proposed: [String] = []
    private var system = ""
    func record(prompt: String, proposed: [String], system: String = "") {
        lock.withLock { self.prompt = prompt; self.proposed = proposed; self.system = system }
    }
    func snapshot() -> (prompt: String, proposed: [String], system: String) { lock.withLock { (prompt, proposed, system) } }
    static func memoryRows(_ prompt: String) -> [[String: String]] {
        for prefix in ["Current memory (data): ", "Facts already saved — do not repeat (data): "] {
            guard let line = prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
                  let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
                  let rows = try? JSONDecoder().decode([[String: String]].self, from: data) else { continue }
            return rows
        }
        return []
    }
    static func toolCalls(_ facts: [String]) -> String {
        facts.map { fact in
            let value = ["name": "memory.remember", "arguments": ["kind": "profile", "text": fact]] as [String: Any]
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return "NONE" }
            return "<tool_call>" + json + "</tool_call>"
        }.joined(separator: "\n")
    }
}
