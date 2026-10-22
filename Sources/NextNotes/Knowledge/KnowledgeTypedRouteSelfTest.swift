import Foundation
import Observation

/// The real typed handle -> owned SQLite index -> fitted asker -> provider -> saved message.
/// Only the answering provider is scripted. No tool backing or model is replaced with success.
@MainActor
enum KnowledgeTypedRouteSelfTest {
    private enum FixtureError: Error { case unsafe }

    static func originalCases(context: KnowledgeToolContext, check: (String, Bool) -> Void) async throws {
        guard SelfTest.requested == "--selftest-ask", SelfTest.isRunning else { throw FixtureError.unsafe }
        let agent = RealtimeAgent.shared
        let oldProvider = agent.localModelProviderForTesting
        let oldContext = agent.knowledgeContextForTesting
        let oldReads = agent.readApprovalOverrideForTesting
        let oldDepth = agent.answerDepthForTesting
        let oldCold = agent.coldForTesting
        let gateKey = KnowledgeToolGate.enabledKey
        let gateValue = SelfTestHarnessDefaults.suite.object(forKey: gateKey)
        let indexKey = KnowledgeIndexSettings.enabledKey
        let indexValue = SelfTestHarnessDefaults.suite.object(forKey: indexKey)
        let oldGate = Settings.shared.knowledgeAgentToolsEnabled
        let oldIndex = Settings.shared.knowledgeIndexEnabled
        Settings.shared.knowledgeIndexEnabled = true
        defer {
            agent.localModelProviderForTesting = oldProvider
            agent.knowledgeContextForTesting = oldContext
            agent.readApprovalOverrideForTesting = oldReads
            agent.answerDepthForTesting = oldDepth
            agent.coldForTesting = oldCold
            Settings.shared.knowledgeAgentToolsEnabled = oldGate
            Settings.shared.knowledgeIndexEnabled = oldIndex
            if let gateValue { SelfTestHarnessDefaults.suite.set(gateValue, forKey: gateKey) }
            else { SelfTestHarnessDefaults.suite.removeObject(forKey: gateKey) }
            if let indexValue { SelfTestHarnessDefaults.suite.set(indexValue, forKey: indexKey) }
            else { SelfTestHarnessDefaults.suite.removeObject(forKey: indexKey) }
        }
        let question = "What did we decide in the pricing meeting?"
        for mode in ["answer", "failed", "files", "review-reads", "remote", "tools-off", "markup", "long", "combined", "action-topic", "combined-polite"] {
            AgentSession.shared.startNewConversation()
            let provider = Provider(mode: mode, knowledgeRules: KnowledgeAsker.rules)
            agent.localModelProviderForTesting = provider
            agent.knowledgeContextForTesting = context
            agent.readApprovalOverrideForTesting = mode != "review-reads"
            agent.answerDepthForTesting = .balanced
            agent.coldForTesting = false
            Settings.shared.knowledgeAgentToolsEnabled = mode != "tools-off"
            let input: String
            switch mode {
            case "files": input = "Search my files for a pricing document"
            case "combined": input = "What did we decide in the pricing meeting, then email it to Ana"
            case "combined-polite": input = "What did we decide about pricing in the meeting? Can you email it to Ana?"
            case "action-topic": input = "What did we decide in the pricing meeting about the email draft?"
            default: input = question
            }
            let source: AgentUtteranceSource = mode == "remote" ? .iMessage : .text
            let result = await agent.handle(input, source: source)
            let calls = await provider.calls
            let observedPresentation = await provider.observedPresentation
            let saved = AgentSession.shared.messages.last { $0.role == "assistant" }
            let knowledge = calls.filter(\.knowledge)
            let planner = calls.filter { !$0.knowledge }
            let routed = mode == "answer" || mode == "failed" || mode == "markup" || mode == "long" || mode == "action-topic"
            check("typed knowledge C01 real input and answering provider \(mode)",
                  AgentSession.shared.messages.contains { $0.role == "user" && $0.text == input }
                    && agent.answeringModel?.id == provider.id && !calls.isEmpty)
            check("typed knowledge C02 preserved caller question/reader budget \(mode)",
                  calls.allSatisfy { $0.maxTokens > 0 && $0.estimatedTokens <= provider.contextTokens }
                    && calls.allSatisfy { $0.user.contains(input) })
            check("typed knowledge C03 actual saved reply identity \(mode)",
                  saved?.text == String(result.reply.prefix(12_000)) && !agent.isThinking && !result.delegated)
            if routed {
                check("typed knowledge F01 actual typed library route \(mode)", knowledge.count == 1)
                check("typed knowledge F02 same resolved graph reader \(mode)",
                      knowledge.count == 1 && knowledge.allSatisfy { $0.reader == provider.id })
            } else {
                check("typed knowledge C04 nonlibrary/permission/source/gate stays planner \(mode)",
                      knowledge.isEmpty && !planner.isEmpty && saved?.knowledgeClaims == nil
                        && saved?.knowledgeCitations == nil)
            }
            if mode == "answer" {
                check("typed knowledge F03 citations reach actual saved consumer", !result.reply.contains("fallback")
                    && saved?.knowledgeClaims?.count == 1 && saved?.knowledgeCitations?.count == 1)
                if let saved, let citations = saved.knowledgeCitations {
                    let data = try JSONEncoder().encode(saved)
                    let decoded = try JSONDecoder().decode(AgentSession.Message.self, from: data)
                    check("typed knowledge F04 source descriptors survive existing conversation codec",
                          decoded.knowledgeClaims == saved.knowledgeClaims
                            && decoded.knowledgeCitations?.map(\.target) == citations.map(\.target)
                            && decoded.knowledgeCitations?.map(\.label) == citations.map(\.label))
                    check("typed knowledge F05 no new passage-body persistence",
                          decoded.knowledgeCitations?.allSatisfy { $0.text.isEmpty } == true
                            && citations.allSatisfy { !$0.text.isEmpty })
                } else {
                    // Same checks on both versions; missing feature must be explicit, never skipped.
                    check("typed knowledge F04 source descriptors survive existing conversation codec", false)
                    check("typed knowledge F05 no new passage-body persistence", false)
                }
                check("typed knowledge F06 no extra planning pass for grounded answer", planner.isEmpty)
                check("typed knowledge F07 actual partial answer reaches typed presentation",
                      observedPresentation)
            } else if mode == "markup" {
                // Exact authored scripted output only; never log a model prompt or owner passage.
                let raw = await provider.emittedAnswer
                let body = AgentReplyRenderer.scrub(KnowledgeAnswerParser.stripMarkers(raw), outcome: nil)
                let claimed = KnowledgeAnswerParser.claims(AgentReplyRenderer.scrub(raw, outcome: nil))
                    .map(\.text).joined(separator: " ")
                let trace = ["reply": result.reply, "body": body, "claimed": claimed,
                             "observedPartial": String(observedPresentation)]
                if let bytes = try? JSONEncoder().encode(trace), let encoded = String(data: bytes, encoding: .utf8) {
                    print("KNOWLEDGE_TYPED_MARKUP_FIXTURE: " + encoded)
                }
                check("typed knowledge F08 saved source rows obey canonical reply boundary",
                      saved?.knowledgeClaims?.isEmpty == false
                        && saved?.knowledgeClaims?.allSatisfy {
                            !$0.text.contains("search_knowledge") && !$0.text.contains("<answer>")
                              && !$0.text.contains("</answer>")
                        } == true
                        && saved?.knowledgeClaims?.map(\.text).joined(separator: " ") == result.reply
                        && saved?.knowledgeCitations?.count == 1
                        && !result.reply.contains("search_knowledge")
                        && (observedPresentation))
            } else if mode == "action-topic" {
                check("typed knowledge F10 action topic remains a library question",
                      saved?.knowledgeClaims?.count == 1 && saved?.knowledgeCitations?.count == 1 && planner.isEmpty)
            } else if mode == "long" {
                check("typed knowledge F09 capped message refuses longer source-row duplicate",
                      result.reply.count > 12_000 && saved?.text.count == 12_000
                        && saved?.knowledgeClaims == nil && saved?.knowledgeCitations == nil)
            } else if mode == "failed" {
                check("typed knowledge C08 genuine ask failure falls back once on same provider",
                      planner.count == 1 && result.reply == Provider.fallback && saved?.knowledgeClaims == nil)
            }
            print("KNOWLEDGE_TYPED_TRACE mode=\(mode) provider=\(provider.id.rawValue) asks=\(knowledge.count) planner=\(planner.count) sources=\(saved?.knowledgeCitations?.count ?? 0)")
        }
        // Previously saved rows have no new source fields; preserve their exact existing text.
        let old = Data(#"{"id":"ABCDEFAB-CDEF-ABCD-ABCD-123456789012","role":"assistant","text":"Owned previous answer","at":0}"#.utf8)
        let decoded = try JSONDecoder().decode(AgentSession.Message.self, from: old)
        check("typed knowledge C09 existing conversation row decodes unchanged",
              decoded.text == "Owned previous answer" && decoded.knowledgeClaims == nil
                && decoded.knowledgeCitations == nil)
    }

    private struct Call: Sendable {
        let knowledge: Bool
        let reader: LLMProviderID?
        let user: String
        let maxTokens: Int
        let estimatedTokens: Int
    }

    private actor Provider: LLMProvider {
        nonisolated let id = LLMProviderID.localServer
        nonisolated let displayModelName = "Owned typed-library fixture"
        nonisolated let contextTokens = 4_096
        nonisolated static let fallback = "The typed planner fallback answered."
        let mode: String
        let knowledgeRules: String
        private(set) var calls: [Call] = []
        private(set) var observedPresentation = false
        private(set) var emittedAnswer = ""
        private var pendingParts: [String] = []
        private var presentationReceipt: PresentationReceipt?
        init(mode: String, knowledgeRules: String) {
            self.mode = mode
            self.knowledgeRules = knowledgeRules
        }
        var unavailableReason: String? { get async { nil } }
        func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            var text = ""
            for try await part in await stream(system: system, user: user, maxTokens: maxTokens) { text += part }
            return LLMCompletion(text: text, generatedTokens: 12, duration: 0.01)
        }
        func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
            let knowledge = system.contains(knowledgeRules)
            calls.append(Call(knowledge: knowledge, reader: KnowledgeGraphScope.reader,
                              user: user, maxTokens: maxTokens,
                              estimatedTokens: (system.count + user.count) / 4 + maxTokens))
            if knowledge && mode == "failed" {
                return AsyncThrowingStream { $0.finish(throwing: FixtureError.unsafe) }
            }
            var response = Self.fallback
            if knowledge {
                let rows = user.components(separatedBy: "\n")
                if let index = rows.firstIndex(where: { $0.contains("decided to ship the pricing page") }), index > 0,
                   let range = rows[index - 1].range(of: #"\[c[0-9]+\]"#, options: .regularExpression) {
                    response = "We decided to ship the pricing page " + String(rows[index - 1][range]) + "."
                } else { response = KnowledgeAnswer.notFound }
            }
            if knowledge && mode == "long", let marker = response.range(of: #"\[c[0-9]+\]"#, options: .regularExpression) {
                // External-output boundary input deliberately exceeds the requested512 tokens.
                // This proves stored message/source-row confinement, never model quality/capacity.
                response = String(repeating: "Owned bounded passage. ", count: 700) + String(response[marker]) + "."
            }
            if knowledge && mode == "markup" {
                response = "<answer>" + response.replacingOccurrences(of: "We decided", with: "Using search_knowledge, we decided") + "</answer>"
            }
            emittedAnswer = response
            let answer = response
            if knowledge && (mode == "answer" || mode == "markup") {
                let first = mode == "markup" ? "<answer>Using search_knowledge, we decided to ship" : "We decided to ship"
                pendingParts = [first, String(answer.dropFirst(first.count))]
                presentationReceipt = nil
                return AsyncThrowingStream(unfolding: { await self.nextAnswerPart() })
            }
            return AsyncThrowingStream { continuation in
                continuation.yield(answer)
                continuation.finish()
            }
        }

        private func nextAnswerPart() async -> String? {
            if let receipt = presentationReceipt {
                // continuation.yield in the real provider bridge does not acknowledge
                // its downstream consumer. Hold only this scripted second fragment until
                // the actual typed observable has published the first authored fragment.
                observedPresentation = await receipt.waitForPublication()
                presentationReceipt = nil
            }
            guard !pendingParts.isEmpty else { return nil }
            let part = pendingParts.removeFirst()
            if pendingParts.count == 1 {
                presentationReceipt = await MainActor.run {
                    PresentationReceipt(agent: RealtimeAgent.shared, expected: AgentReplyRenderer.scrub(
                        KnowledgeAnswerParser.stripMarkers(part), outcome: nil))
                }
            }
            return part
        }
    }

    /// Fixture-only receipt for real presentAnswer publication. Observation fires before
    /// the assignment, so its MainActor task reads after that synchronous producer returns.
    /// The second fragment stays suspended until this read; no sleep/poll or product hook.
    @MainActor
    private final class PresentationReceipt {
        private weak var agent: RealtimeAgent?
        private let expected: String
        private let turnID: UUID
        private var result: Bool?
        private var waiter: CheckedContinuation<Bool, Never>?

        init(agent: RealtimeAgent, expected: String) {
            self.agent = agent
            self.expected = expected
            self.turnID = agent.currentTurnID
            withObservationTracking {
                _ = agent.respondingMessage
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.receivePublication() }
            }
        }

        func waitForPublication() async -> Bool {
            await withTaskCancellationHandler {
                if Task.isCancelled { settle(false) }
                if let result { return result }
                return await withCheckedContinuation { waiter = $0 }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in self?.settle(false) }
            }
        }

        private func receivePublication() {
            let row = agent?.respondingMessage
            settle(row?.id == turnID && row?.role == "assistant" && row?.source == "text"
                && row?.text == expected && agent?.isThinking == true)
        }

        private func settle(_ value: Bool) {
            guard result == nil else { return }
            result = value
            let continuation = waiter
            waiter = nil
            continuation?.resume(returning: value)
        }
    }

}
