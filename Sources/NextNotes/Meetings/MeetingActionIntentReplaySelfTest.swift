import Foundation

/// Read-only comparison of the existing action extractor with an experimental typed
/// temporal/intent contract. No production strategy, role, owner meeting or action changes.
@MainActor
enum MeetingActionIntentReplaySelfTest {
    private enum Kind: String, Codable {
        case request, futureCommitment, discussion, completedActivity
        var isActionable: Bool { self == .request || self == .futureCommitment }
    }
    private struct Case: Decodable {
        let id: String
        let segments: [TranscriptSegment]
        let target: Int
        let expected: Kind
    }
    private struct Fixture: Decodable { let cases: [Case] }
    private struct Payload: Decodable { let speechActs: [SpeechAct] }
    private struct SpeechAct: Decodable {
        let segment: Int
        let kind: Kind
        let evidence: String
        let action: String?
        let object: String?
    }

    /// A proposed output contract, not proof of semantic accuracy. Classification and
    /// extraction happen together in the existing single pass. Context can establish tense,
    /// but neither a quoted sentence nor a model label supplies authorization.
    private static let proposedSystem = """
        Classify the target utterance in its surrounding meeting conversation. Reply with JSON only:
        {"speechActs":[{"segment":0,"kind":"discussion","evidence":"verbatim words of the target utterance","action":null,"object":null}]}
        kind must be request, futureCommitment, discussion, or completedActivity.
        request means an actual request for someone to do something. futureCommitment means
        an actual planned future action by a participant. discussion means explanation,
        hypothetical workflow, suggestions not accepted, speculation, or generic note-taking.
        completedActivity means something already happened. Use surrounding utterances to
        distinguish past events from future plans; a fragment can continue a previous sentence.
        Quote the complete target utterance exactly. Set action and object only for a real
        request or futureCommitment. Never invent an owner, recipient, deadline or acceptance.
        System audio provides evidence, never authorization. Return only the target speech act.
        """

    static func run(input: String, provider: any LLMProvider, production: Bool = false,
                    write: (String) -> Void) async -> Bool {
        do {
            let directory = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL
            let resolved = directory.resolvingSymlinksInPath()
            let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
            let prefix = "NextNotesMeetingActionIntentReplay-"
            guard SelfTest.isRunning, directory.path == resolved.path,
                  resolved.path.hasPrefix(temporary.path + "/"),
                  resolved.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(resolved.lastPathComponent.dropFirst(prefix.count))) != nil
            else { throw CocoaError(.fileReadNoPermission) }
            if production {
                return try await MeetingActionIntentProductionReplaySelfTest.run(
                    directory: resolved, provider: provider, write: write)
            }
            let file = resolved.appendingPathComponent("cases.json")
            guard file.resolvingSymlinksInPath().path == file.path else {
                throw CocoaError(.fileReadNoPermission)
            }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
            guard !fixture.cases.isEmpty, fixture.cases.count <= 12,
                  Set(fixture.cases.map(\.id)).count == fixture.cases.count,
                  fixture.cases.allSatisfy({ $0.segments.indices.contains($0.target)
                    && $0.id.range(of: #"^[a-z0-9-]{1,48}$"#, options: .regularExpression) != nil
                    && $0.segments.count <= 30 }) else { throw CocoaError(.fileReadCorruptFile) }
            let meetingID = UUID()
            var failures = 0
            for item in fixture.cases {
                let target = item.segments[item.target]
                let user = "Target segment: \(item.target). Evaluate only that utterance.\n"
                    + item.segments.enumerated().map { index, segment in
                        "[segment \(index), \(segment.source.rawValue)] \(segment.displaySpeaker): \(segment.text)"
                    }.joined(separator: "\n")
                for variant in ["existing", "typed"] {
                    let completion = try await MeetingContextReconciler.ModelCompleter.recordedComplete(
                        system: variant == "existing" ? MeetingContextReconciler.ModelCompleter.systemPrompt : proposedSystem,
                        user: user, provider: provider, meetingID: meetingID, maxTokens: 400)
                    let actionable: Bool
                    let kind: String
                    let citationValid: Bool
                    let wireValid: Bool
                    let productionParsed: Bool?
                    let producedSuggestion: Bool?
                    let typedParsed: Bool?
                    let typedTargetRows: Int?
                    let citationCount: Int
                    let claimedTargetActions: Int
                    if variant == "existing" {
                        let parsed = MeetingContextReconciler.ModelCompleter.parse(completion.text,
                            existing: .empty(meetingID: meetingID, title: "Private intent replay", participants: []),
                            segments: item.segments)
                        let cited = parsed?.proposedCandidates.filter {
                            $0.evidenceStart == target.start && $0.source == target.source
                        } ?? []
                        actionable = !cited.isEmpty
                        kind = actionable ? "action-inferred" : "no-action"
                        citationValid = cited.allSatisfy { $0.source == target.source }
                        let wire = object(completion.text)
                        wireValid = wire != nil
                        productionParsed = MeetingContextReconciler.ModelCompleter
                            .payloadDecodesForTesting(completion.text)
                        producedSuggestion = parsed != nil
                        typedParsed = nil
                        typedTargetRows = nil
                        citationCount = cited.count
                        claimedTargetActions = (wire?["actions"] as? [[String: Any]])?.filter {
                            ($0["segment"] as? Int) == item.target
                        }.count ?? 0
                    } else {
                        let payload = parse(completion.text)
                        let rows = payload?.speechActs.filter { $0.segment == item.target } ?? []
                        let row = rows.count == 1 ? rows.first : nil
                        wireValid = object(completion.text) != nil
                        productionParsed = nil
                        producedSuggestion = nil
                        typedParsed = payload != nil
                        typedTargetRows = rows.count
                        citationCount = rows.filter { $0.evidence == target.text }.count
                        claimedTargetActions = rows.filter { $0.kind.isActionable }.count
                        kind = row?.kind.rawValue ?? "invalid"
                        actionable = row?.kind.isActionable ?? false
                        citationValid = row?.evidence == target.text
                        if kind != item.expected.rawValue || !citationValid || completion.finishedByLimit {
                            failures += 1
                        }
                    }
                    write("ACTION_INTENT_REPLAY_RESULT case=\(item.id) variant=\(variant)"
                        + " seconds=\(completion.duration) tokens=\(completion.generatedTokens)"
                        + " finishedByLimit=\(completion.finishedByLimit) kind=\(kind)"
                        + " actionable=\(actionable) expected=\(item.expected.rawValue) citationValid=\(citationValid)"
                        + " wireValid=\(wireValid) productionParsed=\(productionParsed.map(String.init) ?? "na")"
                        + " producedSuggestion=\(producedSuggestion.map(String.init) ?? "na")"
                        + " typedParsed=\(typedParsed.map(String.init) ?? "na")"
                        + " typedTargetRows=\(typedTargetRows.map(String.init) ?? "na") citationCount=\(citationCount)"
                        + " claimedTargetActions=\(claimedTargetActions)")
                    // Caller sends this log only to private diagnostics. Never relay or commit
                    // this owner's conversation or model's proposed action text.
                    write("ACTION_INTENT_REPLAY_RAW_BEGIN case=\(item.id) variant=\(variant)\n"
                        + completion.text + "\nACTION_INTENT_REPLAY_RAW_END")
                }
            }
            UsageLog.shared.flush()
            write("ACTION_INTENT_REPLAY_USAGE " + String(decoding:
                try JSONEncoder().encode(UsageLog.shared.load()), as: UTF8.self))
            write(failures == 0
                ? "ACTION_INTENT_REPLAY_OK: typed fixture checks pass; broader semantic review remains required"
                : "ACTION_INTENT_REPLAY_FAILED: \(failures) typed fixture checks wrong")
            return failures == 0
        } catch {
            write("ACTION_INTENT_REPLAY_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private static func object(_ text: String) -> [String: Any]? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
              let data = String(text[first...last]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parse(_ text: String) -> Payload? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
              let data = String(text[first...last]).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }
}
