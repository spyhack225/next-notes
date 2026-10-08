import Foundation

/// Actual ModelCompleter.refine/parse/apply contract checks with a single scripted
/// provider call. No owner transcript, network, model load, setting or task-store writes.
/// Same fixture compiles against the original producer and the proposed repair.
@MainActor
enum MeetingActionInputContractSelfTest {
    static func run(privateFixture: URL? = nil, write: (String) -> Void = { print($0) }) async -> Bool {
        guard SelfTest.isRunning else { return false }
        var failures: [String] = []
        var checks = 0
        func check(_ label: String, _ ok: Bool) {
            checks += 1
            if !ok { failures.append(label) }
        }
        let context = MeetingContext.empty(meetingID: UUID(), title: "Input contract", participants: [])
        func snapshot(_ segments: [TranscriptSegment]) -> MeetingContextReconciler.Snapshot {
            .init(context: context, recentTranscript: "", recentSegments: segments, now: 100)
        }
        func run(_ segments: [TranscriptSegment], _ provider: ScriptedProvider) async -> MeetingContextReconciler.Suggestion {
            await MeetingContextReconciler.ModelCompleter(
                enabled: { true }, resolveProvider: { provider }
            ).refine(snapshot(segments))
        }
        let hidden = "I can deliver the draft after the review."
        var long = [TranscriptSegment(start: 1, end: 2, text: hidden, source: .mic)]
        for index in 1...16 {
            long.append(TranscriptSegment(start: Double(index * 3), end: Double(index * 3 + 1),
                text: "Context \(index): " + String(repeating: "details ", count: 38), source: .system))
        }
        let prompt = MeetingContextReconciler.ModelCompleter.prompt(context: context, now: 100, segments: long)
        let body = prompt.components(separatedBy: "(source is app metadata, not model output):\n").last ?? ""
        check("first retained row keeps full metadata", body.hasPrefix("- [segment 0, "))
        check("existing transcript body budget retained", body.count <= MeetingContextReconciler.windowCharacterCap)
        let hiddenProvider = ScriptedProvider { _, grammar in
            payload(index: 0, quote: hidden, sourceOwned: grammar != nil)
        }
        let unseen = await run(long, hiddenProvider)
        check("parser evidence domain equals visible prompt", unseen.proposedCandidates.allSatisfy {
            $0.evidence.map { prompt.contains($0) } ?? false
        })
        check("hidden-domain probe exactly one provider call", await hiddenProvider.callCount() == 1)

        let oversize = [TranscriptSegment(start: 90, end: 91,
            text: String(repeating: "Oversized speech. ", count: 260), source: .system)]
        let oversizeProvider = ScriptedProvider { _, _ in "{\"topics\":[],\"unresolved\":[],\"actions\":[]}" }
        _ = await run(oversize, oversizeProvider)
        check("oversized newest utterance performs no optional model call", await oversizeProvider.callCount() == 0)
        let noInput = ScriptedProvider { _, _ in "{}" }
        _ = await run([], noInput)
        check("empty input performs no model call", await noInput.callCount() == 0)

        let implicit = "I can take those questions to the customer when I visit."
        let visible = [TranscriptSegment(start: 90, end: 91, text: implicit, source: .system)]
        let validProvider = ScriptedProvider { _, grammar in payload(index: 0, quote: implicit, sourceOwned: grammar != nil) }
        let valid = await run(visible, validProvider)
        let applied = MeetingContextReconciler.apply(valid, to: context, recentSegments: visible)
        check("real refine and apply preserve implicit future candidate", applied.candidateActions.count == 1)
        check("far track cannot acquire microphone authority", applied.candidateActions.first?.source == .system)
        check("source-owned evidence reaches actual action item", applied.actionItems.first?.text == implicit)
        check("meaning confidence remains inferred", applied.candidateActions.first?.confidence == MeetingContextReconciler.inferredConfidence)
        let grammarCalls = await validProvider.grammarCalls()
        let budgets = await validProvider.budgets()
        check("same existing model call receives grammar and 400 token budget", grammarCalls == 1 && budgets == [400])

        // A grammar-aware scripted provider obeys the supplied shape during that one
        // call. This is adapter/producer proof, not native sampler or semantic proof.
        let incompleteProvider = ScriptedProvider { _, grammar in
            grammar == nil ? "{\"topics\":[\"Complete topic\"],\"unresolved\":[],\"actions\":[]" :
                "{\"topics\":[\"Complete topic\"],\"unresolved\":[],\"actions\":[]}"
        }
        let completed = await run(visible, incompleteProvider)
        check("same-call grammar contract yields consumed complete schema", completed.topics.first?.text == "Complete topic")
        check("shape recovery adds no second pass", await incompleteProvider.callCount() == 1)
        let wrapped = ScriptedProvider { _, grammar in
            "Preface\n" + payload(index: 0, quote: implicit, sourceOwned: grammar != nil) + "\nTrailing text"
        }
        check("unsupported provider malformed shape is refused without repair", !(await run(visible, wrapped)).hasRefinements)
        let cut = ScriptedProvider(finishedByLimit: true) { _, grammar in
            payload(index: 0, quote: implicit, sourceOwned: grammar != nil)
        }
        check("length-finished valid partial result is refused", !(await run(visible, cut)).hasRefinements)
        check("length refusal adds no second pass", await cut.callCount() == 1)

        func parse(_ raw: String) -> MeetingContextReconciler.Suggestion? {
            MeetingContextReconciler.ModelCompleter.parse(raw, existing: context, segments: visible)
        }
        let new = parse(payload(index: 0, quote: implicit, sourceOwned: true))
        check("primary source index derives exact original full speech", new?.proposedCandidates.first?.evidence == implicit)
        check("legacy missing evidence remains refused", parse("{\"actions\":[{\"segment\":0,\"action\":\"follow up\"}]}") == nil)
        check("legacy invented quote remains refused", parse(payload(index: 0, quote: "invented quote", sourceOwned: false)) == nil)
        check("legacy exact quote compatibility retained", parse(payload(index: 0, quote: implicit, sourceOwned: false))?.proposedCandidates.count == 1)
        check("out of range primary source refused", parse(payload(index: 44, quote: implicit, sourceOwned: true)) == nil)
        check("ambiguous double citation refused", parse("{\"actions\":[{\"sourceSegment\":0,\"segment\":0,\"action\":\"follow up\",\"evidence\":\"\(implicit)\"}]}") == nil)
        if let privateFixture {
            // Explicit copied-input seam only; raw owner payloads never enter this file.
            let path = privateFixture.resolvingSymlinksInPath().path
            let allowedRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath().path
            guard path.hasPrefix(allowedRoot + "/NextNotesMeetingActionIntentReplay-"),
                  privateFixture.lastPathComponent == "fragmented-future-provenance.json",
                  let data = try? Data(contentsOf: privateFixture),
                  let fixture = try? JSONDecoder().decode(PrivateFixture.self, from: data),
                  let primary = fixture.segments.first(where: { abs($0.start - fixture.expectedStart) < 0.01 }),
                  let original = try? JSONSerialization.jsonObject(with: Data(fixture.originalRaw.utf8)) as? [String: Any],
                  let originalActions = original["actions"] as? [[String: Any]],
                  let originalAction = originalActions.first,
                  let action = originalAction["action"] as? String
            else { write("MEETING_ACTION_INPUT_CONTRACT_FAILED: invalid private copied fixture"); return false }
            let object = originalAction["object"] as? String
            let recipient = originalAction["recipient"] as? String
            let old = MeetingContextReconciler.ModelCompleter.parse(
                fixture.originalRaw, existing: context, segments: fixture.segments)
            check("actual spliced quote remains strictly refused", old?.proposedCandidates.isEmpty ?? true)
            let actualProvider = ScriptedProvider { user, grammar in
                guard grammar != nil else { return fixture.originalRaw }
                let line = user.components(separatedBy: "\n").first { $0.hasSuffix(": " + primary.text) }
                let index = line.flatMap { Int($0.dropFirst("- [segment ".count).prefix { $0 != "," }) } ?? -1
                return "{\"topics\":[],\"unresolved\":[],\"actions\":[{\"sourceSegment\":\(index),\"action\":\(jsonString(action)),\"object\":\(object.map(jsonString) ?? "null"),\"recipient\":\(recipient.map(jsonString) ?? "null")}]}"
            }
            let actual = await MeetingContextReconciler.ModelCompleter(
                enabled: { true }, resolveProvider: { actualProvider }).refine(
                    .init(context: context, recentTranscript: "", recentSegments: fixture.segments, now: fixture.now))
            let actualApplied = MeetingContextReconciler.apply(actual, to: context, recentSegments: fixture.segments)
            check("actual fragmented source contract retains full primary speech", actualApplied.candidateActions.first?.evidence == primary.text)
            check("actual fragmented primary retains source and clock", actualApplied.candidateActions.first?.source == primary.source
                && actualApplied.candidateActions.first?.evidenceStart == primary.start)
            check("actual primary does not inherit antecedent recipient names", actualApplied.candidateActions.first?.recipient == nil)
            check("actual fragmented fixture one call only", await actualProvider.callCount() == 1)
            write("MEETING_ACTION_INPUT_PRIVATE_SCOPE currentNativeInputReconstructed=true historicalSnapshot=false scriptedSourceContract=true semanticProof=false")
        }
        for label in failures { write("FAIL: \(label)") }
        write("MEETING_ACTION_INPUT_CONTRACT_RESULT checks=\(checks) failed=\(failures.count) scripted=true nativeSemantic=false")
        write(failures.isEmpty ? "MEETING_ACTION_INPUT_CONTRACT_OK" : "MEETING_ACTION_INPUT_CONTRACT_FAILED")
        return failures.isEmpty
    }
    private struct PrivateFixture: Decodable, Sendable {
        var segments: [TranscriptSegment]
        var now: TimeInterval
        var originalRaw: String
        var expectedStart: TimeInterval
    }
    private nonisolated static func jsonString(_ string: String) -> String {
        let array = String(data: try! JSONSerialization.data(withJSONObject: [string]), encoding: .utf8)!
        return String(array.dropFirst().dropLast())
    }
    private nonisolated static func payload(index: Int, quote: String, sourceOwned: Bool) -> String {
        // GBNF's object key order is fixed; construct its intended JSON shape explicitly.
        let escaped = String(data: try! JSONSerialization.data(withJSONObject: [quote]), encoding: .utf8)!
        let quoted = String(escaped.dropFirst().dropLast())
        if sourceOwned {
            return "{\"topics\":[],\"unresolved\":[],\"actions\":[{\"sourceSegment\":\(index),\"action\":\"follow up\",\"object\":null,\"recipient\":null}]}"
        }
        return "{\"topics\":[],\"unresolved\":[],\"actions\":[{\"segment\":\(index),\"action\":\"follow up\",\"object\":null,\"recipient\":null,\"evidence\":\(quoted)}]}"
    }
    private actor ScriptedProvider: LLMProvider {
        nonisolated let id = LLMProviderID.localServer
        nonisolated let displayModelName = "Meeting action contract fixture"
        nonisolated let contextTokens = 4096
        var unavailableReason: String? { nil }
        let response: @Sendable (String, GBNFGrammar?) -> String
        let finishedByLimit: Bool
        private var calls = 0
        private var constrained = 0
        private var limits: [Int] = []
        init(finishedByLimit: Bool = false, response: @escaping @Sendable (String, GBNFGrammar?) -> String) {
            self.finishedByLimit = finishedByLimit
            self.response = response
        }
        func countTokens(_ text: String) async throws -> Int { text.count / 4 }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            reply(user: user, maxTokens: maxTokens, grammar: nil)
        }
        func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
            reply(user: user, maxTokens: maxTokens, grammar: grammar)
        }
        private func reply(user: String, maxTokens: Int, grammar: GBNFGrammar?) -> LLMCompletion {
            calls += 1; limits.append(maxTokens)
            if grammar != nil { constrained += 1 }
            return .init(text: response(user, grammar), generatedTokens: 24, duration: 0.01, finishedByLimit: finishedByLimit)
        }
        func callCount() -> Int { calls }
        func grammarCalls() -> Int { constrained }
        func budgets() -> [Int] { limits }
    }
}
