import Foundation

/// Exercises the live meeting model-to-tool path without a model download or
/// Workspace account. No proposal is approved or executed by this probe.
enum MeetingLiveToolSelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        let meeting = Meeting(title: "Deck review", attendees: ["sam@example.com"])
        let segment = TranscriptSegment(
            start: 5, end: 8, text: "Please send Sam the deck.", source: .mic
        )
        let supported = #"<tool_call>{"name":"draft_email","arguments":{"to":"sam@example.com","subject":"Deck","body":"Here is the deck."},"rationale":"Sam requested the deck","evidence":"Please send Sam the deck."}</tool_call>"#
        do {
            let proposals = try await MeetingAgent.shared.liveProposals(
                for: meeting, recent: [segment],
                provider: FixedProvider(answer: supported)
            )
            if proposals.count != 1 || proposals[0].tool != "draft_email"
                || proposals[0].evidence != segment.text || proposals[0].source != .live {
                failures.append("grounded live speech did not become a reviewable tool proposal")
            }
            let invented = supported.replacingOccurrences(
                of: "Please send Sam the deck.", with: "Please publish the budget."
            )
            let rejected = try await MeetingAgent.shared.liveProposals(
                for: meeting, recent: [segment],
                provider: FixedProvider(answer: invented)
            )
            if !rejected.isEmpty {
                failures.append("a tool call with invented transcript evidence was accepted")
            }
        } catch {
            failures.append("live model pass failed: \(error.localizedDescription)")
        }
        for failure in failures { print("MEETING_LIVE_TOOLS_WRONG: \(failure)") }
        print(failures.isEmpty ? "MEETING_LIVE_TOOLS_OK" : "MEETING_LIVE_TOOLS_FAILED")
        return failures.isEmpty
    }

    private struct FixedProvider: LLMProvider {
        let id = LLMProviderID.appleFoundation
        let answer: String
        var contextTokens: Int { 16_000 }
        var unavailableReason: String? { get async { nil } }
        func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            LLMCompletion(text: answer, generatedTokens: answer.count / 4, duration: 0)
        }
    }
}
