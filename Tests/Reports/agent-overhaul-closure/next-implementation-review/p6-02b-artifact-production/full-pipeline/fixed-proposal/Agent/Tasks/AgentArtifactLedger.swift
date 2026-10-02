import Foundation

/// The existing single ordered artifact collection, with producer metadata retained.
enum AgentArtifactLedger {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byTask: [String: [AgentArtifact]] = [:]

    static func capture(taskID: String?, artifact: String) {
        capture(taskID: taskID, record: AgentArtifact(artifact))
    }
    private static func capture(taskID: String?, record: AgentArtifact) {
        // Legacy capture keeps its established trim; typed locations are exact producer values.
        let value = record.isLegacy ? record.value.trimmingCharacters(in: .whitespacesAndNewlines) : record.value
        guard let taskID, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var record = record; record.value = value
        lock.lock(); defer { lock.unlock() }
        byTask[taskID] = AgentArtifact.merging([record], into: byTask[taskID] ?? [])
    }
    static func capture(taskID: String?, result: AgentToolResult) {
        for record in result.artifactRecords { capture(taskID: taskID, record: record) }
    }
    static func takeRecords(taskID: String?) -> [AgentArtifact] {
        guard let taskID else { return [] }
        lock.lock(); defer { lock.unlock() }
        return byTask.removeValue(forKey: taskID) ?? []
    }
    static func peekRecords(taskID: String?) -> [AgentArtifact] {
        guard let taskID else { return [] }
        lock.lock(); defer { lock.unlock() }
        return byTask[taskID] ?? []
    }
    static func take(taskID: String?) -> [String] { takeRecords(taskID: taskID).map(\.value) }
    static func peek(taskID: String?) -> [String] { peekRecords(taskID: taskID).map(\.value) }
}
