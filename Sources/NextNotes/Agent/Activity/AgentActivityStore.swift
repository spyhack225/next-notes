import Foundation
import Observation

@MainActor
@Observable
final class AgentActivityStore {
    static let shared = AgentActivityStore()

    private(set) var activities: [AgentActivity] = []

    private init() {}

    func begin(task: AgentTask, title: String) {
        append(AgentActivity(taskID: task.id, kind: .thinking, title: title))
    }

    func update(taskID: String, kind: AgentActivityKind, title: String, detail: String = "") {
        append(AgentActivity(taskID: taskID, kind: kind, title: title, detail: detail))
    }

    func finish(taskID: String, title: String) {
        append(AgentActivity(taskID: taskID, kind: .completed, title: title))
    }

    func append(_ activity: AgentActivity) {
        activities.insert(activity, at: 0)
        if activities.count > 80 { activities = Array(activities.prefix(80)) }
    }
}

@MainActor
@Observable
final class AgentAuditLog {
    static let shared = AgentAuditLog()

    private(set) var entries: [AgentAuditEntry] = []

    private static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("agent-audit.jsonl")
    }

    private init() {
        entries = Self.load()
    }

    func record(
        kind: AgentAuditEntry.Kind,
        title: String,
        detail: String = "",
        toolID: String? = nil,
        taskID: String? = nil,
        meetingID: UUID? = nil
    ) {
        let entry = AgentAuditEntry(
            kind: kind,
            title: title,
            detail: detail,
            toolID: toolID,
            taskID: taskID,
            meetingID: meetingID
        )
        entries.insert(entry, at: 0)
        if entries.count > 400 { entries = Array(entries.prefix(400)) }
        appendToDisk(entry)
    }

    private func appendToDisk(_ entry: AgentAuditEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line.append("\n")
        if FileManager.default.fileExists(atPath: Self.fileURL.path),
           let handle = try? FileHandle(forWritingTo: Self.fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: Self.fileURL, options: .atomic)
        }
    }

    private static func load() -> [AgentAuditEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").reversed().compactMap { line in
            try? decoder.decode(AgentAuditEntry.self, from: Data(line.utf8))
        }
    }
}
