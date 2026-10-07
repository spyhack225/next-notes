import Foundation

/// Read-only native quality replay on a copied transcript. No meeting store, capture,
/// graph, actions, provider preference or original notes are mutated. A smaller reader
/// window exercises the existing map/reduce producer for a controlled comparison;
/// it is an experiment, not a new production default.
@MainActor
enum MeetingNotesReplaySelfTest {
    static func run(input: String, provider: any LLMProvider, window: Int?,
                    write: (String) -> Void) async -> Bool {
        do {
            let directory = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL
            let resolved = directory.resolvingSymlinksInPath()
            // An explicit copied fixture under the OS temporary root, never an owner store.
            let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
            guard SelfTest.isRunning, directory.path == resolved.path,
                  resolved.path.hasPrefix(temporary.path + "/"),
                  resolved.lastPathComponent.hasPrefix("NextNotesMeetingNotesReplay-"),
                  UUID(uuidString: String(resolved.lastPathComponent
                    .dropFirst("NextNotesMeetingNotesReplay-".count))) != nil else {
                throw CocoaError(.fileReadNoPermission)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            func read(_ name: String) throws -> Data {
                let url = resolved.appendingPathComponent(name)
                guard url.resolvingSymlinksInPath().path == url.path else {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try Data(contentsOf: url)
            }
            let meeting = try decoder.decode(Meeting.self, from: read("meeting.json"))
            let segments = try decoder.decode([TranscriptSegment].self,
                from: read("transcript.json"))
            let selected: any LLMProvider
            if let window {
                guard window >= 4096, window <= provider.contextTokens else {
                    throw NotesError.contextTooSmall
                }
                selected = ReaderWindow(provider: provider, contextTokens: window)
            } else {
                selected = provider
            }
            let result = try await NotesGenerator(provider: selected)
                .notes(for: meeting, segments: segments, brief: .empty)
            write("NOTES_REPLAY_RESULT seconds=\(result.duration) tokens=\(result.generatedTokens)"
                + " mapReduce=\(result.usedMapReduce) chunks=\(result.chunks)"
                + " collapsed=\(result.collapsedGroups) dropped=\(result.droppedFacts)"
                + " incompleteFacts=\(result.incompleteFacts)")
            UsageLog.shared.flush()
            let usage = try JSONEncoder().encode(UsageLog.shared.load())
            write("NOTES_REPLAY_USAGE " + String(decoding: usage, as: UTF8.self))
            // Caller directs this output to its private diagnostic file. Do not publish
            // owner speech or generated content in a repository report or relay message.
            write("NOTES_REPLAY_MARKDOWN_BEGIN\n\(result.markdown)\nNOTES_REPLAY_MARKDOWN_END")
            write("NOTES_REPLAY_OK: generation completed; factual quality needs review")
            return true
        } catch {
            write("NOTES_REPLAY_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private struct ReaderWindow: LLMProvider {
        let provider: any LLMProvider
        let contextTokens: Int
        var id: LLMProviderID { provider.id }
        var displayModelName: String { provider.displayModelName }
        var unavailableReason: String? { get async { await provider.unavailableReason } }
        func countTokens(_ text: String) async throws -> Int {
            try await provider.countTokens(text)
        }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            try await provider.complete(system: system, user: user, maxTokens: maxTokens)
        }
    }
}
