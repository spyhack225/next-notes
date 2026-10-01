import Foundation

/// `imessage-settings.json` — the one writer of the iMessage feature's persisted state.
///
/// **One file, one writer, and the reason is `AGENTS.md`.** A second store for the same
/// fact fails silently rather than loudly: two files that disagree about which chat is
/// paired is a condition nothing detects until a message goes to the wrong place. The
/// watcher's watermark, the pairing, the local identity and the handle cache all live
/// here, in `IMessageConfiguration`.
///
/// **Atomic writes, and the reason is a crash.** A pairing that is half-written is a
/// pairing that is lost, and a lost pairing is a feature that silently stops answering.
/// `PersonDecisionLog` is the precedent: write to a temp file, then rename, so a crash
/// mid-write leaves the old file intact rather than a truncated one.
final class RemoteIdentityStore: @unchecked Sendable {
    static let fileName = "imessage-settings.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    private let lock = NSLock()
    private var stored: IMessageConfiguration

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName)),
           let decoded = try? JSONDecoder().decode(IMessageConfiguration.self, from: data) {
            stored = decoded
        } else {
            stored = IMessageConfiguration()
        }
    }

    /// The current configuration. A copy, because a caller that mutates the result
    /// must not mutate the stored one without writing it.
    var configuration: IMessageConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Merges a change and writes atomically. The merge is a closure so the caller
    /// cannot read-modify-write without the lock, and the write is atomic so a crash
    /// cannot leave a half-written file.
    func update(_ change: (inout IMessageConfiguration) -> Void) throws {
        lock.lock()
        var next = stored
        change(&next)
        guard next != stored else { return lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        let temp = fileURL.appendingPathExtension("tmp")
        try data.write(to: temp, options: .atomic)
        try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        stored = next
        lock.unlock()
    }

    /// The paired chat's GUID, or `nil` when unpaired. The one read the watcher makes.
    var pairedChatGUID: String? { configuration.pairedChatGUID }

    /// Whether the feature is paired and enabled.
    var isPaired: Bool { configuration.isPaired }

    /// IM-12 — suspends remote processing. Callable from any path, including a
    /// "stop remote access" message: stopping must always work, especially from
    /// the phone.
    func suspendRemoteAccess() throws {
        try update { $0.remoteAccessSuspended = true }
    }

    /// IM-12 — resumes remote processing. LOCAL ONLY: re-enabling needs local
    /// confirmation, so only Settings UI (IM-17) calls this — never the message
    /// path, never the turn pipeline. A remote turn must not widen its own
    /// authority, and this is the function where that rule lives.
    func resumeRemoteAccessLocally() throws {
        try update { $0.remoteAccessSuspended = false }
    }
}
