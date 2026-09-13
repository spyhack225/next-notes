import Foundation

/// Tasks persist as history. A queued or running task is marked failed on relaunch
/// ("Next Notes quit while this task was running") — they are not durable workflows.
@MainActor
final class AgentTaskStore {
    static let shared = AgentTaskStore()

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-tasks.json")
    }

    private init() {}

    func load() -> [AgentTask] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.fileURL) else { return [] }
        return (try? decoder.decode([AgentTask].self, from: data)) ?? []
    }

    func save(_ tasks: [AgentTask]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
