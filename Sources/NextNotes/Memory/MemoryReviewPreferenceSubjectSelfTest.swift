import Foundation

/// Original labelled jazz scenario and related own-preference controls through
/// the same reviewer and actual guarded writer; no substitute classifier result.
@MainActor
enum MemoryReviewPreferenceSubjectSelfTest {
    static func failures(root: URL) async -> [String] {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-memory-review",
              resolved.path.hasPrefix(temp.path + "/"),
              !resolved.pathComponents.contains("Application Support") else {
            return ["preference subject: isolated diagnostic root required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ id: String, _ good: Bool) {
            checks += 1
            if !good { failures.append("preference subject: " + id) }
        }
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            guard let path = MemoryReviewSelfTest.fixtureURL() else {
                return ["preference subject: original labelled fixture missing"]
            }
            let bytes = try Data(contentsOf: path)
            let file = try JSONDecoder().decode(MemoryReviewSelfTest.FixtureFile.self, from: bytes)
            guard let original = file.cases.first(where: { $0.id == "other-person-preference" }),
                  original.turns.first?.text == "My sister Ana loves jazz, can you find a concert for her?",
                  original.expect.saves.isEmpty,
                  original.scripted.contains("The user loves jazz.") else {
                return ["preference subject: original inputs changed"]
            }
            let originalSession = UUID()
            let request = AgentSession.ReviewRequest(sessionID: originalSession, reason: .idle,
                messages: MemoryReviewSelfTest.messages(original.turns, sessionID: originalSession, start: epoch))
            guard let originalJob = MemoryReviewJob(request, reviewedThrough: nil) else {
                return ["preference subject: original actual job missing"]
            }
            let cases: [(String, String, Bool)] = [
                ("I love jazz.", "The user loves jazz.", true),
                ("I like jazz.", "The user likes jazz.", true),
                ("I prefer concise answers.", "The user prefers concise answers.", true),
                ("I really love jazz.", "The user loves jazz.", true),
                ("I like classical music. My sister Ana loves jazz.", "The user loves jazz.", false),
                ("My sister Ana loves jazz but I like classical music.", "The user loves jazz.", false),
                ("My sister Ana loves jazz but I love jazz too.", "The user loves jazz.", true),
                ("I don't love jazz.", "The user loves jazz.", false),
                ("My sister said, I love jazz.", "The user loves jazz.", false),
                ("I like classical music and my sister Ana loves jazz.", "The user loves jazz.", false),
                ("I prefer jazz and classical music.", "The user prefers jazz.", true),
            ]
            var jobs: [(MemoryReviewJob, String, Bool)] = [(originalJob, original.scripted, false)]
            for (user, fact, keep) in cases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                let data = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                jobs.append((job, "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>", keep))
            }
            // The exact original attribution error remains wrong on other trusted channels.
            for source: MemoryProvenance.TrustedSource in [.userDictated, .userSpokeInMeeting] {
                let job = MemoryReviewJob(source: source, trigger: .conversationEnded,
                    sourceKey: "owned:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [original.turns[0].text], untrustedText: [original.turns[1].text], occurredAt: epoch)
                jobs.append((job, original.scripted, false))
            }
            // Additive controls for legitimate own clauses beside reported speech.
            // Parent42 cases above remain byte-for-byte and keep their original order.
            let clauseCases: [(String, String, Bool)] = [
                ("I love jazz. My sister said she likes pop.", "The user loves jazz.", true),
                ("I like \"jazz\".", "The user likes jazz.", true),
                ("My sister said, \"I love jazz\".", "The user loves jazz.", false),
                ("\"I love jazz\".", "The user loves jazz.", false),
            ]
            for (user, fact, keep) in clauseCases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                let data = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                jobs.append((job, "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>", keep))
            }
            // Quote scope survives conjunction/sentence splits in reported material.
            let quoteCases = [
                "\"I like classical music and I love jazz.\"",
                "My sister said, \"I like pop. I love jazz.\"",
            ]
            for user in quoteCases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                jobs.append((job, original.scripted, false))
            }
            // Existing direct-intent prefixes retain their own subject and raw provenance.
            let directiveCases: [(String, String, Bool)] = [
                ("Please remember I like jazz.", "The user likes jazz.", true),
                ("Can you remember that I prefer short answers", "The user prefers short answers.", true),
                ("Could you remember I like classical music", "The user likes classical music.", true),
                ("Would you remember that I prefer concise replies", "The user prefers concise replies.", true),
                ("Remember I love jazz.", "The user loves jazz.", true),
                ("Please remember that I enjoy jazz.", "The user enjoys jazz.", true),
                ("Remember that \"I like jazz\".", "The user likes jazz.", false),
                ("Remember that the email says I like jazz.", "The user likes jazz.", false),
                ("My sister said, \"Please remember I like jazz.\"", "The user likes jazz.", false),
                ("Please remember my sister likes jazz.", "The user likes jazz.", false),
            ]
            for (user, fact, keep) in directiveCases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                let data = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                jobs.append((job, "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>", keep))
            }
            // Preserve existing trusted current declarative facts (modal E01/skip1),
            // while quoted/reported declarations remain other-source words.
            let declarationCases: [(String, String, Bool)] = [
                ("The user prefers offline-first tools.", "The user prefers offline-first tools.", true),
                ("The user likes jazz.", "The user likes jazz.", true),
                ("\"The user likes jazz.\"", "The user likes jazz.", false),
                ("My sister said, The user likes jazz.", "The user likes jazz.", false),
                ("My sister said, \"The user prefers classical music. The user likes jazz.\"", "The user likes jazz.", false),
            ]
            for (user, fact, keep) in declarationCases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                let data = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                jobs.append((job, "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>", keep))
            }
            // Exact introduced recall misses and independent clause/source controls.
            // Keep all117 historical checks above and real direct caller checks below.
            let recallCases: [(String, String, Bool)] = [
                ("Honestly I prefer short answers, two sentences at most.", "The user prefers short answers, two sentences at most.", true),
                ("Always answer me in French.", "The user prefers answers in French.", true),
                ("Honestly I prefer short answers.", "The user prefers short answers.", true),
                ("I prefer short answers, two sentences at most.", "The user prefers short answers, two sentences at most.", true),
                ("\"Honestly I prefer short answers, two sentences at most.\"", "The user prefers short answers, two sentences at most.", false),
                ("My sister said, \"Honestly I prefer short answers, two sentences at most.\"", "The user prefers short answers, two sentences at most.", false),
                ("\"Always answer me in French.\"", "The user prefers answers in French.", false),
                ("My sister said, \"Always answer me in French.\"", "The user prefers answers in French.", false),
                ("Always answer my sister in French.", "The user prefers answers in French.", false),
                ("Honestly I prefer classical music, my sister likes jazz.", "The user likes jazz.", false),
                ("I like classical music, Ana loves jazz.", "The user loves jazz.", false),
                ("I prefer classical, my sister likes jazz.", "The user likes jazz.", false),
            ]
            for (user, fact, keep) in recallCases {
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [user], untrustedText: [], occurredAt: epoch)
                let data = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                jobs.append((job, "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>", keep))
            }
            for (index, item) in jobs.enumerated() {
                let (job, answer, keep) = item
                let store = NextMemory(directory: root.appendingPathComponent("case-\(index)"), isEnabled: { true })
                let writer = ObservedWriter(store: store)
                let model = ScriptedMemoryReviewModel { _, _ in answer }
                let outcome = try await MemoryReviewer.review(job, model: model, writer: writer)
                let id = String(format: "S%02d", index)
                check(id + " real reviewer verdict", keep
                    ? outcome.saved.count == 1 && outcome.refused.isEmpty && outcome.skipped.isEmpty
                    : outcome.saved.isEmpty && outcome.refused.count == 1 && outcome.skipped.isEmpty)
                check(id + " single pass actual writer boundary", model.callCount == 1
                    && outcome.proposed == 1 && writer.names == ["memory.remember"])
                check(id + " actual stored ownership", keep
                    ? store.entries.count == 1 && store.entries.first?.text == outcome.saved.first?.text
                        && store.entries.first?.source == .review && store.entries.first?.sessionID == job.sessionID
                    : store.entries.isEmpty)
                print("MEMORY_PREFERENCE_SUBJECT_TRACE case=\(index) keep=\(keep) saved=\(outcome.saved.count) refused=\(outcome.refused.count) writerCalls=\(writer.names.count)")
            }
        } catch {
            failures.append("preference subject: actual authored reviewer/writer input failed")
        }
        let direct = await ExplicitMemorySaveSelfTest.preferenceDirectiveControls(
            store: NextMemory(directory: root.appendingPathComponent("direct-callers"), isEnabled: { true }))
        checks += direct.checks
        failures += direct.failures
        let saved = await savedPreferenceControls(root: root.appendingPathComponent("saved-preference"))
        checks += saved.checks
        failures += saved.failures
        print("MEMORY_PREFERENCE_SUBJECT_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }

    /// Existing direct guarded update boundary, with only authored temp saved facts.
    /// No generated provenance, model substitute, tool fire bypass or shared store seed.
    private static func savedPreferenceControls(root: URL) async -> (checks: Int, failures: [String]) {
        var checks = 0; var failures: [String] = []
        let short = "The user prefers short answers."
        let combined = "The user prefers short answers and metric units."
        let corrected = "The user prefers answers under two sentences."
        let modes: [(String, String, String, String, Bool)] = [
            ("own-merge", "merge those two", "The user uses metric units.", combined, true),
            ("quoted-merge", "\"merge those two\"", "The user uses metric units.", combined, false),
            ("reported-merge", "My sister said, merge those two", "The user uses metric units.", combined, false),
            ("other-saved-subject", "merge those two", "My sister uses metric units.", combined, false),
            ("quoted-saved-subject", "merge those two", "\"The user uses metric units.\"", combined, false),
            ("reported-saved-subject", "merge those two", "My sister said, The user uses metric units.", combined, false),
            ("actual-own-correction", "Actually I prefer answers under two sentences.", "The user uses metric units.", corrected, true),
            ("quoted-correction", "\"Actually I prefer answers under two sentences.\"", "The user uses metric units.", corrected, false),
            ("reported-correction", "My sister said, \"Actually I prefer answers under two sentences.\"", "The user uses metric units.", corrected, false),
            ("other-correction-subject", "Actually my sister prefers answers under two sentences.", "The user uses metric units.", corrected, false),
            ("older-merge-in-review-history", "Now read my calendar.", "The user uses metric units.", combined, false),
            ("merge-after-older-review-turn", "merge those two", "The user uses metric units.", combined, false),
        ]
        func check(_ label: String, _ condition: Bool) {
            checks += 1; if !condition { failures.append("preference subject: " + label) }
        }
        for (name, user, second, fact, keep) in modes {
            do {
                let store = NextMemory(directory: root.appendingPathComponent(name), isEnabled: { true })
                try store.remember(kind: .profile, text: short, source: .manual)
                try store.remember(kind: .profile, text: second, source: .manual)
                // Existing NextMemory.validated appends punctuation after a closing quote.
                // Pin that literal stored output, keeping the authored seed above unchanged.
                let storedSecond = name == "quoted-saved-subject" ? "\"The user uses metric units.\"." : second
                let before = store.entries; let beforeSuperseded = store.superseded
                let target = try store.entry(matching: "short answers")
                let writer = ObservedWriter(store: store)
                let sourceWords = name == "older-merge-in-review-history" ? ["merge those two", user]
                    : name == "merge-after-older-review-turn" ? ["An unrelated earlier review turn.", user] : [user]
                let provenance = MemoryProvenance(origin: .userConversation, source: .userSaidToAgent,
                    sessionID: UUID(), userText: sourceWords, untrustedText: [])
                var result: AgentToolResult?; var refusal: MemoryWriteError?
                do {
                    result = try await writer.run(AgentToolCall(name: "memory.update",
                        arguments: ["match": "short answers", "text": fact], rationale: "", evidence: nil),
                        provenance: provenance)
                } catch { refusal = error as? MemoryWriteError }
                check(name + " actual guarded update verdict", keep ? result != nil && refusal == nil : result == nil && {
                    if case .provenance = refusal { return true }; return false
                }())
                check(name + " one actual writer unchanged raw source", writer.names == ["memory.update"]
                    && provenance.userText == sourceWords && provenance.origin == .userConversation
                    && before.count == 2 && Set(before.map(\.text)) == Set([short, storedSecond]))
                check(name + " exact stored replacement or refusal", keep
                    ? store.entries.count == before.count && store.entries.contains { $0.text == fact && $0.supersedes == target.id }
                        && store.entries.contains { $0.text == storedSecond } && store.superseded.contains { $0.id == target.id }
                        && result?.reference == store.entries.first(where: { $0.text == fact })?.id.uuidString
                    : store.entries == before && store.superseded == beforeSuperseded)
                print("MEMORY_PREFERENCE_SAVED_TRACE mode=\(name) keep=\(keep) writerCalls=\(writer.names.count) retained=\(store.entries.count) updated=\(result != nil)")
            } catch { failures.append("preference subject: " + name + " authored saved-fact prerequisite failed") }
        }
        return (checks, failures)
    }

    @MainActor
    private final class ObservedWriter: MemoryReviewWriter {
        let store: NextMemory
        private(set) var names: [String] = []
        init(store: NextMemory) { self.store = store }
        func run(_ call: AgentToolCall, provenance: MemoryProvenance) async throws -> AgentToolResult {
            names.append(call.name)
            return try await StoreMemoryReviewWriter(store: store).run(call, provenance: provenance)
        }
    }
}
