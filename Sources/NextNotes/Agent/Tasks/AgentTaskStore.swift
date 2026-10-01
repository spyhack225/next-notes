import Foundation

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

    init(fileURL: URL? = nil) {
        injectedFileURL = fileURL
    }

    /// Read-only location lets an isolated fixture verify its binding before seeding.
    var storageURL: URL { injectedFileURL ?? Self.fileURL }

    func load() -> [AgentTask] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: storageURL) else { return [] }
        return (try? decoder.decode([AgentTask].self, from: data)) ?? []
    }

    func save(_ tasks: [AgentTask]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
