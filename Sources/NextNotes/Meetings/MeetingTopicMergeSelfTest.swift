import Foundation

/// Producer and actual isolated context persistence regression; no native model or
/// owner-store access. Exactly the same expectations run before and after repair.
@MainActor
enum MeetingTopicMergeSelfTest {
    private struct Fixture: Sendable {
        var id: String
        var segments: [TranscriptSegment]
        var modelOutput: String
        var expectedAddition: String? = nil
    }
    private struct PrivateCases: Decodable {
        struct Row: Decodable { var id: String; var cutoff: TimeInterval; var modelOutput: String }
        var cases: [Row]
    }
    static func run(privateDirectory: URL? = nil, write: (String) -> Void = { print($0) }) async -> Bool {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            write("MEETING_TOPIC_MERGE_FAILED: isolated preferences required"); return false
        }
        var fixtures = genericFixtures()
        if let privateDirectory {
            let resolved = privateDirectory.resolvingSymlinksInPath()
            let temporary = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
            let prefix = "NextNotesMeetingActionIntentReplay-"
            guard resolved.deletingLastPathComponent().path == temporary.path,
                  resolved.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(resolved.lastPathComponent.dropFirst(prefix.count))) != nil
            else { write("MEETING_TOPIC_MERGE_FAILED: copied temporary inputs required"); return false }
            do {
                func read(_ name: String) throws -> Data {
                    let file = resolved.appendingPathComponent(name)
                    guard file.resolvingSymlinksInPath().path == file.path else { throw CocoaError(.fileReadNoPermission) }
                    return try Data(contentsOf: file)
                }
                let transcript = try JSONDecoder().decode([TranscriptSegment].self, from: read("transcript.live.json"))
                let cases = try JSONDecoder().decode(PrivateCases.self, from: read("topic-merge-cases.json"))
                guard cases.cases.count <= 12 else { throw CocoaError(.fileReadCorruptFile) }
                fixtures += cases.cases.map { item in
                    Fixture(id: item.id, segments: transcript.filter { $0.end <= item.cutoff }, modelOutput: item.modelOutput)
                }
            } catch { write("MEETING_TOPIC_MERGE_FAILED: private copied fixture unavailable"); return false }
        }
        let priorEnabled = Settings.shared.meetingLiveUnderstanding
        Settings.shared.meetingLiveUnderstanding = true
        defer { Settings.shared.meetingLiveUnderstanding = priorEnabled }
        var failures: [String] = []
        if !MeetingAttributedContextDedupSelfTest.run(write: write) {
            failures.append("attributed context dedup")
        }
        var checks = 0
        func check(_ fixture: String, _ label: String, _ passed: Bool) {
            checks += 1
            if !passed { failures.append("\(fixture): \(label)") }
        }
        for fixture in fixtures {
            let meeting = Meeting(title: "Topic preservation fixture", start: Date(), status: .recording)
            let store = MeetingStore.isolated()
            let root = store.directory(for: meeting.id).deletingLastPathComponent()
            defer { try? FileManager.default.removeItem(at: root) }
            check(fixture.id, "isolated meeting saved", store.save(meeting))
            let initial = MeetingContextExtractor.apply(fixture.segments,
                to: .empty(meetingID: meeting.id, title: meeting.title, participants: []))
            let suggestion = MeetingContextReconciler.ModelCompleter.parse(
                fixture.modelOutput, existing: initial, segments: fixture.segments) ?? .empty
            check(fixture.id, "real model schema decoded", MeetingContextReconciler.ModelCompleter.payloadDecodesForTesting(fixture.modelOutput))
            let completer = ScriptedCompleter(suggestion: suggestion)
            let contextStore = MeetingContextStore.isolatedForTesting(store: store, completer: completer, optionalAdmission: { true })
            contextStore.ingest(fixture.segments, meeting: meeting)
            guard let before = contextStore.load(meetingID: meeting.id) else {
                check(fixture.id, "actual context ingestion", false); continue
            }
            await contextStore.runReconcileForTesting()
            guard let inMemory = contextStore.current,
                  let after = contextStore.load(meetingID: meeting.id) else {
                check(fixture.id, "actual context application", false); continue
            }
            check(fixture.id, "current context matches actual saved baseline/readback", sameContext(inMemory, after))
            check(fixture.id, "actual completer invoked once", await completer.calls == 1)
            check(fixture.id, "retained topics preserve full identity and facts", retains(before.topics, in: after.topics))
            check(fixture.id, "retained unresolved preserve full identity and facts", retains(before.unresolvedItems, in: after.unresolvedItems))
            check(fixture.id, "topics and unresolved bounded", after.topics.count <= 40 && after.unresolvedItems.count <= 40)
            check(fixture.id, "punctuation-only topics absent", after.topics.allSatisfy { hasWords($0.text) })
            check(fixture.id, "punctuation-only unresolved absent", after.unresolvedItems.allSatisfy { hasWords($0.text) })
            if fixture.id == "exact-duplicate" || fixture.id == "capacity-duplicate" {
                check(fixture.id, "normalized model duplicate adds no row", after.topics == before.topics && after.unresolvedItems == before.unresolvedItems)
            }
            if fixture.id == "capacity" {
                check(fixture.id, "at capacity model cannot evict retained rows", after.topics == before.topics && after.unresolvedItems == before.unresolvedItems)
            }
            if let addition = fixture.expectedAddition {
                let item = after.topics.first { $0.text == addition }
                check(fixture.id, "meaningful enrichment remains available", item != nil)
                check(fixture.id, "enrichment retains own inferred model metadata", item?.source == .system && item?.confidence == MeetingContextReconciler.inferredConfidence)
            }
            let freshReader = MeetingContextStore.isolatedForTesting(store: store, completer: ScriptedCompleter(suggestion: .empty), optionalAdmission: { true })
            let loaded = freshReader.load(meetingID: meeting.id)
            check(fixture.id, "actual committed context reads back exactly", sameContext(after, loaded))
            check(fixture.id, "fresh reader retains topic identity", loaded.map { retains(before.topics, in: $0.topics) } ?? false)
            check(fixture.id, "fresh reader retains unresolved identity", loaded.map { retains(before.unresolvedItems, in: $0.unresolvedItems) } ?? false)
            write("MEETING_TOPIC_MERGE_CASE id=\(fixture.id) priorTopics=\(before.topics.count) afterTopics=\(after.topics.count) priorUnresolved=\(before.unresolvedItems.count) afterUnresolved=\(after.unresolvedItems.count) retainedTopics=\(retains(before.topics, in: after.topics)) retainedUnresolved=\(retains(before.unresolvedItems, in: after.unresolvedItems))")
            contextStore.reset()
            freshReader.reset()
        }
        for failure in failures { write("FAIL: \(failure)") }
        write("MEETING_TOPIC_MERGE_RESULT fixtures=\(fixtures.count) checks=\(checks) failed=\(failures.count) modelCalls=0 semanticQuality=false")
        write(failures.isEmpty ? "MEETING_TOPIC_MERGE_OK" : "MEETING_TOPIC_MERGE_FAILED")
        return failures.isEmpty
    }
    private static func genericFixtures() -> [Fixture] {
        func speech(_ count: Int) -> [TranscriptSegment] {
            (0..<count).map { index in
                TranscriptSegment(start: Double(index * 8), end: Double(index * 8 + 8),
                    text: "We are talking about sector \(index) and inspector \(index). We still need to decide site \(index).",
                    source: index.isMultiple(of: 2) ? .mic : .system)
            }
        }
        var fixtures: [Fixture] = []
        for count in [11, 13] {
            fixtures.append(Fixture(id: "placeholder-\(count)", segments: speech(count), modelOutput: payload(topics: ["…"], unresolved: ["…"])))
        }
        for count in [9, 13] {
            fixtures.append(Fixture(id: "shared-token-\(count)", segments: speech(count), modelOutput: payload(topics: ["Talking item."], unresolved: ["A decision needs talking."])))
        }
        let simple = speech(9)
        fixtures.append(Fixture(id: "empty", segments: simple, modelOutput: payload(topics: [], unresolved: [])))
        fixtures.append(Fixture(id: "exact-duplicate", segments: simple, modelOutput: payload(topics: [simple[0].text.uppercased() + "!"], unresolved: [simple[0].text.uppercased() + "!"])))
        let enrichment = simple[0].text + " The depot audit will inform that decision."
        fixtures.append(Fixture(id: "enrichment", segments: simple, modelOutput: payload(topics: [enrichment], unresolved: []), expectedAddition: enrichment))
        fixtures.append(Fixture(id: "capacity", segments: speech(40), modelOutput: payload(topics: ["A new route proposal is under review."], unresolved: ["A new depot question remains open."])))
        fixtures.append(Fixture(id: "capacity-duplicate", segments: speech(40), modelOutput: payload(topics: [speech(40)[0].text.uppercased()], unresolved: [speech(40)[0].text.uppercased()])))
        return fixtures
    }
    private static func payload(topics: [String], unresolved: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["topics": topics, "unresolved": unresolved, "actions": []])
        return String(decoding: data, as: UTF8.self)
    }
    private static func encoded<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }
    private static func retains(_ originals: [MeetingContextItem], in retained: [MeetingContextItem]) -> Bool {
        originals.allSatisfy { original in retained.first { $0.id == original.id }.map { encoded($0) == encoded(original) } ?? false }
    }
    private static func sameContext(_ expected: MeetingContext, _ actual: MeetingContext?) -> Bool {
        actual.map { encoded(expected) == encoded($0) } ?? false
    }
    private static func hasWords(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
    private actor ScriptedCompleter: MeetingContextCompleter {
        let suggestion: MeetingContextReconciler.Suggestion
        private(set) var calls = 0
        init(suggestion: MeetingContextReconciler.Suggestion) { self.suggestion = suggestion }
        func refine(_ snapshot: MeetingContextReconciler.Snapshot) async -> MeetingContextReconciler.Suggestion {
            calls += 1
            return suggestion
        }
    }
}
