import Foundation

enum AgentTaskPersistenceResult: Equatable {
    case saved, jsonFailed, mirrorFailed, loadFailed

    var diagnostic: String? {
        switch self {
        case .saved: nil
        case .jsonFailed: "Task history could not be saved. The durable copy was not changed."
        case .mirrorFailed: "Task history was saved, but its durable copy could not be updated."
        case .loadFailed: "Task history could not be read. Your saved history was kept, and new work has not started."
        }
    }
}

/// JSON remains read authority. The mirror does not grant resumable workflow authority.
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
    private var failedLoad = false

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

    func load() throws -> [AgentTask] {
        do {
            let data: Data
            do { data = try Data(contentsOf: storageURL) }
            catch CocoaError.fileReadNoSuchFile {
                failedLoad = false
                return [] // Missing history alone is a fresh installation, not corruption.
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let tasks = try decoder.decode([AgentTask].self, from: data)
            guard Set(tasks.map(\.id)).count == tasks.count,
                  tasks.allSatisfy({ task in
                      !task.id.isEmpty && task.createdAt.timeIntervalSince1970.isFinite
                      && [task.durability?.heartbeatAt, task.durability?.lastProgressAt,
                          task.durability?.attemptStartedAt].compactMap { $0 }
                          .allSatisfy { $0.timeIntervalSince1970.isFinite }
                  }) else { throw TaskStoreError.invalidRecord }
            failedLoad = false
            return tasks
        } catch {
            failedLoad = true
            throw error // Never reinterpret damaged history as an empty ledger.
        }
    }

    @discardableResult
    func save(_ tasks: [AgentTask], events: [TaskJournalEventDraft] = []) -> AgentTaskPersistenceResult {
        guard !failedLoad else { return .loadFailed }
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
