import Foundation

/// Actual fit -> model -> parser -> proposal admission -> stored proposal codec.
/// No tool executes. Profile lookup is instance-local and exact-flag confined.
enum MeetingEvidenceSelfTest {
    fileprivate struct Case: Sendable {
        let name: String
        let speech: String
        let quote: String
        let accepted: Bool
        var arguments = ["to": "ana@example.invalid", "subject": "Pricing", "body": "Owned fixture"]
        var brief: String? = nil
    }
    static func failures() async -> [String] {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-meeting-agent-evidence" else {
            return ["C00 exact diagnostic required"]
        }
        var problems: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { problems.append(name) }
        }
        let ask = "Can you send me the pricing sheet by Friday?"
        let long = "Please deliver the complete quarterly pricing schedule and detailed product roadmap for regional partners tomorrow."
        let cases = [
            Case(name: "literal", speech: ask, quote: "Can you send me the pricing sheet by Friday", accepted: true),
            Case(name: "comma", speech: ask, quote: "can you send me the pricing sheet, by friday", accepted: true),
            Case(name: "hyphen", speech: ask, quote: "Can you send me the pricing-sheet by Friday", accepted: true),
            Case(name: "apostrophe", speech: "Please draft Ana’s pricing update for Friday.", quote: "Please draft Ana's pricing update for Friday", accepted: true),
            Case(name: "LCS", speech: long, quote: "Please deliver the quarterly pricing schedule and detailed product roadmap for regional partners tomorrow", accepted: true),
            Case(name: "changedContent", speech: ask, quote: "Can you send me the budget file by Friday", accepted: false),
            Case(name: "addedNegation", speech: long,
                quote: "Please deliver the complete quarterly pricing schedule and detailed product roadmap for regional partners, not tomorrow.", accepted: false),
            Case(name: "short", speech: ask, quote: "pricing", accepted: false),
            Case(name: "omittedNegation", speech: "Please don't send the pricing sheet by Friday.", quote: "send the pricing sheet by Friday", accepted: false),
            Case(name: "explicitNegation", speech: "Please don't send the pricing sheet by Friday.", quote: "Please don't send the pricing sheet by Friday", accepted: true),
            Case(name: "briefOnlyQuote", speech: "We discussed a quiet weekend.", quote: ask, accepted: false, brief: ask),
            Case(name: "briefOnlyRecipient", speech: ask, quote: "Can you send me the pricing sheet by Friday", accepted: true,
                arguments: ["to": "brief-only@example.invalid", "subject": "Pricing", "body": "Owned fixture"],
                brief: "The recipient is brief-only@example.invalid.")
        ]
        guard let definition = WorkspaceTools.tool(named: "draft_email") else { return ["C00 fixture catalogue missing"] }
        let tool = AgentTool.workspace(definition)
        for item in cases {
            let meeting = Meeting(title: "Owned evidence fixture", titleSource: .user,
                start: Date(timeIntervalSince1970: 1_800_000_000), status: .done)
            let segments = [TranscriptSegment(start: 0, end: 5, text: item.speech, source: .mic)]
            let transcript = segments.plainText(speakerNames: [:])
            let profile = MeetingEvidenceProfile()
            let provider = MeetingEvidenceProvider(item: item, toolBlock: AgentPrompts.toolBlock(tools: [tool]))
            let agent = MeetingAgent(accountTagForTesting: { await profile.read() })
            do {
                let proposals = try await agent.proposals(for: meeting, segments: segments, notes: nil,
                    brief: item.brief, provider: provider, policy: .dryRun, toolsOverride: [tool])
                let calls = await provider.calls
                let profileReads = await profile.reads
                check(calls.count == 1 && calls.first?.tools == ["draft_email"] && calls.first?.maxTokens == 900,
                    "C01 \(item.name) actual single advertised write planning pass")
                check(calls.first?.hasSpeech == true && profileReads == 1,
                    "C02 \(item.name) actual transcript/profile boundary")
                check(proposals.count == (item.accepted ? 1 : 0), "F01 \(item.name) actual proposal admission")
                let proposal = proposals.first
                check(proposal.map { $0.meetingID == meeting.id && $0.tool == "draft_email"
                    && $0.source == .review && $0.accountTag == "owned-fixture-tag" } ?? true,
                    "C03 \(item.name) identity and account metadata retained")
                check(!item.accepted || proposal?.evidence.map { !$0.isEmpty && transcript.contains($0) } == true,
                    "F02 \(item.name) saved evidence must be original transcript span")
                let encoded = try JSONEncoder().encode(proposals)
                let decoded = try JSONDecoder().decode([AgentProposal].self, from: encoded)
                check(decoded.map(\.evidence) == proposals.map(\.evidence)
                    && decoded.map(\.arguments) == proposals.map(\.arguments)
                    && decoded.map(\.meetingID) == proposals.map(\.meetingID)
                    && decoded.map(\.accountTag) == proposals.map(\.accountTag),
                    "C04 \(item.name) actual stored consumer round trip")
                check(proposal?.arguments["to"] == nil, "C05 \(item.name) brief/model-only recipient never becomes grounded")
                print("MEETING_EVIDENCE_TRACE mode=\(item.name) calls=\(calls.count) admitted=\(proposals.count) profileReads=\(profileReads)")
            } catch { problems.append("C99 \(item.name) prerequisite: \(type(of: error))") }
        }
        check(MeetingEvidenceMatcher.normalize("  ANA’S   “Pricing”  ") == "ana's pricing", "F03 canonical punctuation/whitespace")
        check(MeetingEvidenceMatcher.match(quote: "Can you send me the budget file by Friday", in: ask) == nil,
            "C06 two changed content words stay refused")
        check(MeetingEvidenceMatcher.match(quote: "send the pricing sheet by Friday", in: "Please don't send the pricing sheet by Friday.") == nil,
            "F04 omitted clause negation never permits a literal substring")
        check(MeetingEvidenceMatcher.match(quote: "pricing", in: ask) == nil, "C07 normalized minimum remains twelve")
        check(MeetingEvidenceMatcher.match(
            quote: "Please deliver the complete quarterly pricing schedule and detailed product roadmap for regional partners, not tomorrow.", in: long) == nil,
            "C08 added clause negation never manufactures source evidence")
        print("MEETING_EVIDENCE_CHECKS=\(checks) problems=\(problems.count)")
        return problems
    }
}

private actor MeetingEvidenceProfile {
    private(set) var reads = 0
    func read() -> String? { reads += 1; return "owned-fixture-tag" }
}

private actor MeetingEvidenceProvider: LLMProvider {
    nonisolated let id = LLMProviderID.localServer
    nonisolated let displayModelName = "Owned evidence provider"
    nonisolated let contextTokens = 32_768
    struct Call: Sendable { let tools: [String]; let maxTokens: Int; let hasSpeech: Bool }
    private let speech: String
    private let toolBlock: String
    private let reply: String
    private(set) var calls: [Call] = []
    init(item: MeetingEvidenceSelfTest.Case, toolBlock: String) {
        speech = item.speech
        self.toolBlock = toolBlock
        let value: [String: Any] = ["name": "draft_email", "arguments": item.arguments,
            "rationale": "Owned fixture", "evidence": item.quote]
        reply = "<tool_call>" + String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) + "</tool_call>"
    }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        calls.append(Call(tools: system.hasSuffix("\n\n" + toolBlock) ? ["draft_email"] : [],
            maxTokens: maxTokens, hasSpeech: user.contains(speech)))
        return LLMCompletion(text: reply, generatedTokens: 100, duration: 0)
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
