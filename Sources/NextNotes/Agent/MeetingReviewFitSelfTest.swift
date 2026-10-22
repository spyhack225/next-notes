import Foundation

/// Same actual review actor, fitter and provider callback on synthetic transcript data.
/// Does not review an owner's meeting, run a tool, or pretend a scripted tokenizer is native.
enum MeetingReviewFitSelfTest {
    static func failures() async -> [String] {
        guard SelfTest.isRunning else { return ["review fit: diagnostic required"] }
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ value: Bool) {
            checks += 1
            if !value { failures.append("review fit: " + name) }
        }
        let meeting = Meeting(title: "Owned pricing fixture", titleSource: .user,
            start: Date(timeIntervalSince1970: 1_800_000_000), status: .done)
        let firstAsk = "Can you send me the pricing sheet by Friday?"
        let secondAsk = "You will share the roadmap with the team."
        let tail = "We ended with a quiet goodbye."
        let filler = Array(repeating: "Owned discussion continues about carefully measured practice.", count: 5).joined(separator: " ")
        var segments: [TranscriptSegment] = []
        for index in 0..<150 {
            let text: String
            if index == 48 { text = firstAsk }
            else if index == 100 { text = secondAsk }
            else if index == 149 { text = tail }
            else { text = filler }
            segments.append(TranscriptSegment(start: Double(index * 10), end: Double(index * 10 + 8),
                text: text, source: .mic))
        }
        var anchored = MeetingContext.empty(meetingID: meeting.id, title: meeting.title, participants: [])
        anchored.candidateActions = [MeetingCandidateAction(action: "send", object: "pricing sheet", source: .system,
            evidence: firstAsk, evidenceStart: 480)]
        anchored.actionItems = [MeetingContextItem(text: "share the roadmap with the team", source: .mic)]
        var mismatched = anchored; mismatched.meetingID = UUID()
        let whole = segments.plainText(speakerNames: meeting.speakerNames)
        for mode in ["anchored", "whole", "unanchored", "mismatched"] {
            let window = mode == "whole" ? 32_768 : 4_096
            let provider = MeetingReviewFitProvider(contextTokens: window)
            let observed = MeetingReviewFitReports()
            do {
                let result = try await MeetingAgent().proposals(for: meeting, segments: segments, notes: nil,
                    context: mode == "unanchored" ? nil : mode == "mismatched" ? mismatched : anchored,
                    provider: provider, policy: .dryRun, toolsOverride: [], report: { observed.append($0) })
                let calls = await provider.calls
                let counted = await provider.counted
                let reports = observed.values
                check("C \(mode) actual one planning pass without actions", result.isEmpty && calls.count == 1
                    && calls.first?.maxTokens == 900 && reports.count == 1)
                guard let call = calls.first, let report = reports.first,
                      let range = call.user.range(of: "Transcript:\n") else {
                    failures.append("review fit: actual review callback missing"); continue
                }
                let transcript = String(call.user[range.upperBound...])
                let transcriptTokenCount = max(1, whole.count / 4)
                let charactersPerToken = Double(whole.count) / Double(transcriptTokenCount)
                let characterBudget = max(0, Int(Double(report.budget) * charactersPerToken))
                check("C \(mode) actual request and immutable rules", call.user.contains("Meeting: " + meeting.title)
                    && call.system.contains(AgentPrompts.rules) && transcript.contains(tail))
                check("C \(mode) exact measured reservations", report.window == window
                    && report.outputTokens == 900 && report.headroom == 256 && report.lookups == 0
                    && report.toolCount == 0 && report.reserved == report.systemTokens + 900 + 256
                    && report.budget == window - report.reserved && report.fits
                    && report.systemTokens == counted.first.map { max(1, $0.count / 4) })
                check("F \(mode) count exact received system even empty catalogue", counted.first == call.system)
                if mode == "anchored" {
                    check("F earlier candidate ask reaches actual model", transcript.contains(firstAsk))
                    check("F located action item reaches actual model", transcript.contains(secondAsk))
                    check("C selected speech stays chronological and bounded", transcript.count <= characterBudget
                        && !transcript.contains("Candidate actions"))
                    if let a = transcript.range(of: firstAsk), let b = transcript.range(of: secondAsk), let z = transcript.range(of: tail) {
                        check("F actual earlier asks precede unchanged tail", a.lowerBound < b.lowerBound && b.lowerBound < z.lowerBound)
                    } else { check("F actual earlier asks precede unchanged tail", false) }
                } else if mode == "whole" {
                    check("C fitting transcript remains exactly whole", transcript == whole && !transcript.contains("\n…\n"))
                } else {
                    let characters = characterBudget
                    check("C \(mode) unchanged no-anchor tail contract", transcript == String(whole.suffix(characters))
                        && !transcript.contains(firstAsk))
                }
                print("MEETING_REVIEW_FIT_TRACE mode=\(mode) window=\(window) system=\(report.systemTokens) reserved=\(report.reserved) budget=\(report.budget) calls=\(calls.count) characters=\(transcript.count)")
            } catch {
                failures.append("review fit: \(mode) prerequisite \(type(of: error))")
            }
        }
        let times = MeetingTranscriptWindows.anchors(in: segments, context: anchored, meetingID: meeting.id)
        check("C candidate plus actual located action item anchors", times == [1_000, 480])
        check("C mismatched meeting cannot select speech", MeetingTranscriptWindows.anchors(in: segments,
            context: mismatched, meetingID: meeting.id).isEmpty)
        var malformed = anchored
        malformed.candidateActions += [MeetingCandidateAction(action: "send", source: .system, evidenceStart: .infinity),
            MeetingCandidateAction(action: "send", source: .system, evidenceStart: -1)]
        malformed.actionItems += [MeetingContextItem(text: "unrelated impossible canary", source: .mic)]
        check("C invalid or unrelated anchors add no fabricated location", MeetingTranscriptWindows.anchors(in: segments,
            context: malformed, meetingID: meeting.id) == times)
        let short = [TranscriptSegment(start: 0, end: 1, text: firstAsk, source: .mic),
            TranscriptSegment(start: 50, end: 51, text: filler + filler, source: .mic),
            TranscriptSegment(start: 100, end: 101, text: secondAsk, source: .mic),
            TranscriptSegment(start: 150, end: 151, text: tail, source: .mic)]
        let selected = MeetingTranscriptWindows.build(segments: short, anchors: [0, 100], speakerNames: [:],
            budgetCharacters: 250, radius: 0)
        check("F disjoint real windows preserve both asks and tail", selected.contains(firstAsk)
            && selected.contains(secondAsk) && selected.contains(tail) && !selected.contains(filler))
        check("C windows fit full rendered separators", selected.count <= 250)
        let newest = MeetingTranscriptWindows.build(segments: short, anchors: [0, 100], speakerNames: [:],
            budgetCharacters: 80, radius: 0)
        check("F newest ask wins scarce transcript space", newest.contains(secondAsk) && !newest.contains(firstAsk))
        let command = TranscriptSegment(start: 70, end: 71, text: "Private command canary", source: .mic, kind: .agentCommand)
        let all = MeetingTranscriptWindows.build(segments: short + [command], anchors: [70], speakerNames: ["You": "Owned speaker"],
            budgetCharacters: 10_000)
        check("C original plain-text format and command exclusion", all == (short + [command]).sorted { $0.start < $1.start }.plainText(speakerNames: ["You": "Owned speaker"])
            && !all.contains(command.text) && all.contains("Owned speaker:"))
        check("C zero room gives no speech", MeetingTranscriptWindows.build(segments: short, anchors: [0],
            speakerNames: [:], budgetCharacters: 0).isEmpty)
        print("MEETING_REVIEW_FIT_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }
}

private final class MeetingReviewFitReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [MeetingAgent.FitReport] = []
    func append(_ report: MeetingAgent.FitReport) { lock.withLock { reports.append(report) } }
    var values: [MeetingAgent.FitReport] { lock.withLock { reports } }
}

private actor MeetingReviewFitProvider: LLMProvider {
    nonisolated let id = LLMProviderID.localServer
    nonisolated let displayModelName = "Owned review reader"
    nonisolated let contextTokens: Int
    struct Call: Sendable { let system: String; let user: String; let maxTokens: Int }
    private(set) var calls: [Call] = []
    private(set) var counted: [String] = []
    init(contextTokens: Int) { self.contextTokens = contextTokens }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { counted.append(text); return max(1, text.count / 4) }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        calls.append(Call(system: system, user: user, maxTokens: maxTokens))
        return LLMCompletion(text: "No follow-up was proposed.", generatedTokens: 6, duration: 0)
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
