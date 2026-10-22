import Foundation

/// Same actual reviewer/writer/state store on authored, isolated data. No provider,
/// microphone, owner history, second review pass or permission exception.
@MainActor
enum MemoryReviewDecisionTotalsSelfTest {
    static func failures(root: URL) async -> [String] {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, resolved.path.hasPrefix(temp.path + "/"),
              !resolved.pathComponents.contains("Application Support") else {
            return ["decision totals: isolated diagnostic root required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append("decision totals: " + name) }
        }
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        let brother = "The user's brother is Cyril."
        let dad = "The user's dad is Mathieu."
        func job(_ user: String, untrusted: [String] = []) -> MemoryReviewJob {
            MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                userText: [user], untrustedText: untrusted, occurredAt: epoch)
        }
        func encoded(_ call: AgentToolCall) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["name": call.name, "arguments": call.arguments], options: [.sortedKeys])
            return "<tool_call>" + String(decoding: data, as: UTF8.self) + "</tool_call>"
        }
        let keep = ["The user is unavailable on Fridays.", "The user prefers offline-first tools.",
                    "The user's company builds search software.", "The user fixes bugs before features."]
        let skip = ["The user's microphone isn't working.", "The user is searching for the budget.",
                    "The app failed to sync the user's calendar."]
        do {
            // Each verdict is consumed by the real reviewer and guarded writer, not just a regex helper.
            for (index, fact) in (keep + skip).enumerated() {
                let store = NextMemory(directory: root.appendingPathComponent("skip-\(index)"), isEnabled: { true })
                let writer = MemoryReviewObservedStoreWriter(store: store)
                let call = AgentToolCall(name: "memory.remember", arguments: ["kind": "profile", "text": fact], rationale: "", evidence: nil)
                let answer = try encoded(call)
                let model = ScriptedMemoryReviewModel { _, _ in answer }
                let current = job(fact)
                let outcome = try await MemoryReviewer.review(current, model: model, writer: writer)
                let shouldKeep = index < keep.count
                check("skip \(index) actual producer decision", shouldKeep
                    ? outcome.saved.count == 1 && outcome.saved.first?.text == fact && outcome.skipped.isEmpty
                    : outcome.saved.isEmpty && outcome.skipped.count == 1)
                check("skip \(index) reaches only admitted writer", writer.names == (shouldKeep ? ["memory.remember"] : [])
                    && model.callCount == 1 && outcome.proposed == 1)
                check("skip \(index) existing source guards remain", outcome.refused.isEmpty
                    && (shouldKeep ? store.entries.first?.source == .review && store.entries.first?.sessionID == current.sessionID : store.entries.isEmpty))
            }
            let sentenceBoundaries = [
                "The user is unavailable on Fridays. Their camera is blue.",
                "The user fixes bugs before features. Their app is called Cedar.",
            ]
            for (index, text) in sentenceBoundaries.enumerated() {
                check("environment words in different sentences \(index) stay unrelated",
                    MemoryReviewSkipRules.reason(tool: "memory.remember", kind: "profile", text: text, existing: []) == nil)
            }
            check("same sentence environment failure still refused", MemoryReviewSkipRules.reason(tool: "memory.remember", kind: "profile",
                text: "The user's network is unavailable.", existing: []) != nil)
            check("present negative working still refused", MemoryReviewSkipRules.reason(tool: "memory.remember", kind: "profile",
                text: "The user can't work.", existing: []) != nil)
            check("continuous search still refused", MemoryReviewSkipRules.reason(tool: "memory.remember", kind: "profile",
                text: "The user wants to search for Cedar.", existing: []) != nil)

            var admittedOutcome: MemoryReviewOutcome?
            var admittedJob: MemoryReviewJob?
            let modes = ["untargeted", "duplicate", "targeted", "unknown", "untrusted", "forget", "invalid-kind", "disabled", "remembered-only"]
            for mode in modes {
                let enabled = MemoryReviewEnabledFlag()
                let store = NextMemory(directory: root.appendingPathComponent(mode), isEnabled: { enabled.get() })
                try store.remember(kind: .profile, text: brother, source: .manual)
                if mode == "duplicate" || mode == "remembered-only" { try store.remember(kind: .profile, text: dad, source: .manual) }
                let before = store.entries
                let user = mode == "remembered-only" ? "I prefer concise answers." : (mode == "targeted" || mode == "disabled") ? "My brother is Cyril and my dad is Mathieu." : mode == "untrusted" ? "My brother is Cyril." : "My dad is Mathieu."
                let current = job(user, untrusted: mode == "untrusted" ? ["My dad is Mathieu."] : [])
                var arguments = ["match": mode == "unknown" ? "uncle" : "brother", "text": dad]
                if mode == "invalid-kind" { arguments["kind"] = "unknown" }
                let call = AgentToolCall(name: mode == "forget" ? "memory.forget" : "memory.update", arguments: arguments, rationale: "", evidence: nil)
                let answer = try encoded(call)
                let model = ScriptedMemoryReviewModel { _, _ in
                    // Initial review admission stays real. Withdraw only the injected
                    // store choice before the actual named-target writer boundary.
                    if mode == "disabled" { enabled.disable() }
                    return answer
                }
                let writer = MemoryReviewObservedStoreWriter(store: store)
                let outcome = try await MemoryReviewer.review(current, model: model, writer: writer)
                check("\(mode) one model pass and original proposal", model.callCount == 1 && outcome.proposed == 1)
                switch mode {
                case "untargeted":
                    check("untargeted admits one remember after exact guard", writer.names == ["memory.update", "memory.remember"])
                    check("untargeted preserves named brother and saves current dad", store.entries.contains { $0.id == before[0].id && $0.text == brother }
                        && outcome.saved.count == 1 && outcome.saved.first?.text == dad && outcome.saved.first?.source == .review
                        && outcome.saved.first?.sessionID == current.sessionID && store.entries.count == 2)
                    check("untargeted no refusal or skipped write", outcome.refused.isEmpty && outcome.skipped.isEmpty)
                    admittedOutcome = outcome; admittedJob = current
                case "duplicate":
                    check("duplicate stops before a remember retry", writer.names == ["memory.update"])
                    check("duplicate reported skipped and leaves exact rows", outcome.skipped.map(\.reason) == ["already remembered"]
                        && outcome.refused.isEmpty && outcome.saved.isEmpty && store.entries == before)
                case "targeted":
                    check("named correction keeps normal single update", writer.names == ["memory.update"] && outcome.refused.isEmpty
                        && outcome.saved.count == 1 && outcome.saved.first?.supersedes == before[0].id && store.entries.count == 1)
                case "invalid-kind":
                    check("failed bounded retry uses original call attribution", writer.names == ["memory.update", "memory.remember"]
                        && outcome.refused.count == 1 && outcome.refused.first?.call.hasPrefix("memory.update:") == true
                        && outcome.refused.first?.reason == MemoryWriteError.invalidKind.localizedDescription && store.entries == before)
                default:
                    check("\(mode) other refusals never retry or mutate", writer.names == [call.name] && outcome.refused.count == 1
                        && outcome.saved.isEmpty && outcome.skipped.isEmpty && store.entries == before)
                }
            }
            // Cancellation after the actual first writer refusal cannot admit the new retry.
            let cancelledStore = NextMemory(directory: root.appendingPathComponent("cancelled"), isEnabled: { true })
            try cancelledStore.remember(kind: .profile, text: brother, source: .manual)
            let cancelledBefore = cancelledStore.entries
            let cancelledWriter = MemoryReviewObservedStoreWriter(store: cancelledStore)
            var reviewTask: Task<MemoryReviewOutcome, Error>?
            cancelledWriter.afterError = { reviewTask?.cancel() }
            let cancelledAnswer = try encoded(AgentToolCall(name: "memory.update", arguments: ["match": "brother", "text": dad], rationale: "", evidence: nil))
            let cancelledModel = ScriptedMemoryReviewModel { _, _ in cancelledAnswer }
            let cancelledJob = job("My dad is Mathieu.")
            reviewTask = Task { try await MemoryReviewer.review(cancelledJob, model: cancelledModel, writer: cancelledWriter) }
            let cancelledOutcome = try await reviewTask!.value
            cancelledWriter.afterError = nil
            check("actual cancelled writer never enters retry", cancelledWriter.names == ["memory.update"] && cancelledModel.callCount == 1)
            check("cancel after original refusal retains exact rows", cancelledOutcome.saved.isEmpty && cancelledOutcome.refused.count == 1
                && cancelledStore.entries == cancelledBefore)

            // The retry belongs to the review, never the existing direct user-conversation writer.
            let directStore = NextMemory(directory: root.appendingPathComponent("direct"), isEnabled: { true })
            try directStore.remember(kind: .profile, text: brother, source: .manual)
            let directBefore = directStore.entries
            let directProvenance = MemoryProvenance(origin: .userConversation, source: .userSaidToAgent, occurredAt: epoch,
                sessionID: UUID(), userText: ["My dad is Mathieu."], untrustedText: [])
            var directError: MemoryWriteError?
            do {
                _ = try await StoreMemoryReviewWriter(store: directStore).run(
                    AgentToolCall(name: "memory.update", arguments: ["match": "brother", "text": dad], rationale: "", evidence: nil), provenance: directProvenance)
            } catch { directError = error as? MemoryWriteError }
            check("direct writer does not gain automatic retry", directError == .provenance(MemoryGuard.untargetedUpdate)
                && directStore.entries == directBefore)

            guard let admittedOutcome, let admittedJob else { return failures + ["decision totals: actual admitted job missing"] }
            let state = MemoryReviewStateStore(directory: root.appendingPathComponent("totals"))
            let actualRun = MemoryReviewRun.make(job: admittedJob, model: "scripted", outcome: admittedOutcome, now: epoch)
            for index in 0..<205 {
                var run = actualRun
                run.id = UUID(); run.at = epoch + Double(index)
                run.proposed = 3
                run.skipped = [.init(reason: "already remembered", count: 2)]
                run.refused = [.init(reason: "did not pass the checks", count: 1)]
                state.record(run: run, sourceKey: "conversation:owned")
            }
            check("recent list stays bounded at 200", state.runs.count == 200 && state.runs.first?.at == epoch + 5)
            check("lifetime counts survive the recent trim", state.lifetime?.runs == 205 && state.lifetime?.proposed == 615
                && state.lifetime?.saved == 205 && state.lifetime?.since == epoch)
            check("lifetime accumulates exact decision multiplicities", state.lifetime?.skipped == ["already remembered": 410]
                && state.lifetime?.refused == ["did not pass the checks": 205])
            check("actual settings line shows lifetime not recent count", state.lifetimeLine?.hasPrefix("Since ") == true
                && state.lifetimeLine?.contains("looked 205 times, saved 205.") == true)
            let fresh = MemoryReviewStateStore(directory: state.directory)
            check("fresh actual reader retains totals and recent rows", fresh.lifetime == state.lifetime && fresh.lifetime?.runs == 205
                && fresh.runs == state.runs && fresh.harvested == state.harvested)
            let data = try Data(contentsOf: state.fileURL)
            let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check("optional totals written in existing file", decoded["lifetime"] is [String: Any] && decoded["runs"] is [Any])

            // Genuine old shape from the real writer, minus only the optional new field.
            let legacy = MemoryReviewStateStore(directory: root.appendingPathComponent("legacy"))
            legacy.markReviewed(through: epoch + 42, memoryOff: true)
            for index in 0..<3 {
                var run = actualRun; run.id = UUID(); run.at = epoch + Double(index); run.proposed = 2
                legacy.record(run: run, sourceKey: "dictation:owned-\(index)")
            }
            let oldRuns = legacy.runs
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy.fileURL)) as! [String: Any]
            object.removeValue(forKey: "lifetime")
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: legacy.fileURL, options: .atomic)
            let oldReader = MemoryReviewStateStore(directory: legacy.directory)
            check("old file keeps rows and watermark unchanged", oldReader.runs == oldRuns && oldReader.reviewedThrough == epoch + 42
                && oldReader.memoryOff && oldReader.harvested == legacy.harvested)
            check("old file seeds only actually retained counts", oldReader.lifetime?.runs == 3 && oldReader.lifetime?.proposed == 6
                && oldReader.lifetime?.saved == 3 && oldReader.lifetime?.since == epoch)
            let migratedBytes = try Data(contentsOf: legacy.fileURL)
            check("old optional-field migration persists once", (try JSONSerialization.jsonObject(with: migratedBytes) as? [String: Any])?["lifetime"] is [String: Any])
            let again = MemoryReviewStateStore(directory: legacy.directory)
            let repeatBytes = try Data(contentsOf: legacy.fileURL)
            check("fresh repeat does not reseed or rewrite migration", again.lifetime == oldReader.lifetime
                && again.runs == oldRuns && repeatBytes == migratedBytes)
            var next = actualRun; next.id = UUID(); next.at = epoch + 4
            oldReader.record(run: next, sourceKey: nil)
            check("seeded legacy totals continue once", oldReader.lifetime?.runs == 4 && oldReader.lifetime?.saved == 4
                && MemoryReviewStateStore(directory: legacy.directory).lifetime == oldReader.lifetime)
            let empty = MemoryReviewStateStore(directory: root.appendingPathComponent("empty"))
            check("empty history fabricates no start date or totals line", empty.lifetime == nil && empty.lifetimeLine == nil && empty.runs.isEmpty)

            // Unknown legacy reasons may contain private facts. They never become new dictionary keys.
            let privateState = MemoryReviewStateStore(directory: root.appendingPathComponent("private-reason"))
            var privateRun = actualRun
            privateRun.skipped = [.init(reason: "Private aggregate canary Cedar", count: 2)]
            privateRun.refused = [.init(reason: "Private aggregate canary Cedar", count: 3)]
            privateState.record(run: privateRun, sourceKey: nil)
            check("new totals contain bounded reasons only", privateState.lifetime?.skipped == ["did not pass the checks": 2]
                && privateState.lifetime?.refused == ["did not pass the checks": 3]
                && privateState.runs.first?.refused.first?.reason == "Private aggregate canary Cedar")
        } catch {
            // Do not print private writer payloads if a fixture prerequisite fails.
            failures.append("decision totals: actual fixture prerequisite failed (\(type(of: error)))")
        }
        print("MEMORY_REVIEW_DECISION_TOTALS_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }
}

@MainActor
private final class MemoryReviewObservedStoreWriter: MemoryReviewWriter {
    let store: NextMemory
    private(set) var names: [String] = []
    var afterError: (() -> Void)?
    init(store: NextMemory) { self.store = store }
    func run(_ call: AgentToolCall, provenance: MemoryProvenance) async throws -> AgentToolResult {
        names.append(call.name)
        do { return try await StoreMemoryReviewWriter(store: store).run(call, provenance: provenance) }
        catch { afterError?(); throw error }
    }
}

/// Existing NextMemory enabled-provider seam, changed by the SAME scripted completion.
/// No global setting is changed and no error/result is manufactured.
private final class MemoryReviewEnabledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    func get() -> Bool { lock.withLock { enabled } }
    func disable() { lock.withLock { enabled = false } }
}
