import Foundation

enum AgentTaskPersistenceResult: Equatable {
    case saved, jsonFailed, mirrorFailed

    var diagnostic: String? {
        switch self {
        case .saved: nil
        case .jsonFailed: "Task history could not be saved. The durable copy was not changed."
        case .mirrorFailed: "Task history was saved, but its durable copy could not be updated."
        }
    }
}

/// Tasks persist as history. A queued or running task is marked failed on relaunch
/// ("Next Notes quit while this task was running") — they are not durable workflows.
@MainActor
final class AgentTaskStore {
    static let shared = AgentTaskStore()

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-tasks.json")
    }

    /// A fixture supplies its exact file before seeding. Nil retains the shared store's
    /// existing path resolution; an injected URL never falls back to the owner's file.
    private let injectedFileURL: URL?
    private let injectedMirror: TaskStore?
    private lazy var mirror = injectedMirror ?? TaskStore(root: storageURL.deletingLastPathComponent())

    init(fileURL: URL? = nil, mirror: TaskStore? = nil) {
        injectedFileURL = fileURL
        injectedMirror = mirror
    }

    /// Read-only location lets an isolated fixture verify its binding before seeding.
    var storageURL: URL { injectedFileURL ?? Self.fileURL }

    /// Only explicitly injected temporary stores may drive the real persistence seam in
    /// a harness. Shared/default stores keep P0-11's no-write guard, including their mirror.
    var allowsHarnessPersistence: Bool {
        guard injectedFileURL != nil else { return false }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        return [storageURL, mirror.fileURL].allSatisfy {
            $0.resolvingSymlinksInPath().path.hasPrefix(root)
        }
    }

    func load() -> [AgentTask] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? decoder.decode([AgentTask].self, from: data)) ?? []
    }

    @discardableResult
    func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let canonical: [AgentTask]
        do {
            let data = try encoder.encode(tasks)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // One canonical snapshot preserves JSON's existing ISO precision in both files.
            canonical = try decoder.decode([AgentTask].self, from: data)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            return .jsonFailed
        }
        do {
            try mirror.replaceSnapshot(canonical, failFast: true, events: events)
            return .saved
        } catch {
            // JSON remains readable/authoritative. There is no cross-file atomicity claim.
            return .mirrorFailed
        }
    }
}
