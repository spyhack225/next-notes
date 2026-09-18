import Foundation
import Observation

/// Display name and Notion-style avatar for the Agent — what About edits and what chat /
/// island labels read.
///
/// Persisted as `agent-identity.json` under Application Support (or a temp directory under
/// self-test). Soul text stays in `PersonaStore` / `persona.md`; core memories stay in
/// `NextMemory`.
@Observable
@MainActor
final class AgentIdentityStore {
    static let shared = AgentIdentityStore()

    static let defaultName = "Next"
    static let fileName = "agent-identity.json"

    private(set) var displayName: String
    private(set) var avatar: NotionAvatarConfig

    private let fileURL: URL

    init(directory: URL? = nil) {
        let root: URL
        if let directory {
            root = directory
        } else if SelfTest.isRunning {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "NextNotesSelfTest-identity-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            root = AppIdentity.applicationSupportDirectory
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(Self.fileName)
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            displayName = Self.sanitisedName(saved.displayName)
            avatar = saved.avatar
        } else {
            displayName = Self.defaultName
            avatar = .default
        }
    }

    /// Name shown on chat bubbles, thinking rows, and the island.
    var name: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    func setDisplayName(_ value: String) {
        displayName = Self.sanitisedName(value)
        persist()
    }

    func setAvatar(_ config: NotionAvatarConfig) {
        avatar = config
        persist()
    }

    func randomiseAvatar() {
        avatar = .random()
        persist()
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var displayName: String
        var avatar: NotionAvatarConfig
    }

    private func persist() {
        let snapshot = Snapshot(displayName: displayName, avatar: avatar)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func sanitisedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultName }
        return String(trimmed.prefix(40))
    }
}
