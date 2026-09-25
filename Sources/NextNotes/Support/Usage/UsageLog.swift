import AppKit
import Foundation

/// The one persistent sink for per-pass usage and provenance (`usage.jsonl`).
///
/// Append-only JSON Lines beside `runs.jsonl`, separate from `metrics.jsonl` on purpose:
/// `metrics.jsonl` is the short engineering ring of latency spans, while this file is the
/// history a person may read (and clear) — one `UsageRecord` per model or engine pass for
/// the Agent, Meetings and Dictation. It is local only: nothing uploads it and no network
/// call is made here. The file rotates at `maxBytes` into `usage.1.jsonl`, so at most two
/// files exist; rows older than `maxAgeDays` are dropped from the rotated file only.
///
/// Every write is enqueued on one serial utility queue, so `record` never waits on disk and
/// two writers can never interleave a line. `load`, `clear` and `flush` synchronise with that
/// queue, which is what makes a read see every write enqueued before it.
final class UsageLog: @unchecked Sendable {
    /// Under the harness this is a per-process temp directory, exactly like
    /// `MetricsStore.shared`, so a self-test can never append to the owner's file.
    static let shared = UsageLog(directory: SelfTest.isRunning
        ? FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        : AppIdentity.applicationSupportDirectory)

    static let fileName = "usage.jsonl"
    static let rotatedName = "usage.1.jsonl"
    static let defaultMaxBytes = 8 * 1_024 * 1_024
    static let defaultMaxAgeDays = 90

    /// The schema version this reader knows. A row with a greater `v` is skipped, never
    /// guessed at: a newer build may have redefined a field.
    static let schemaVersion = 1

    let directory: URL
    let fileURL: URL
    let rotatedURL: URL
    let maxBytes: Int
    let maxAgeDays: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "ai.pivotstudio.nextnotes.usage", qos: .utility)
    private var terminationObserver: NSObjectProtocol?

    init(
        directory: URL,
        maxBytes: Int = UsageLog.defaultMaxBytes,
        maxAgeDays: Int = UsageLog.defaultMaxAgeDays,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.rotatedURL = directory.appendingPathComponent(Self.rotatedName)
        self.maxBytes = max(1, maxBytes)
        self.maxAgeDays = max(1, maxAgeDays)
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Age compaction is the only rewrite this store ever performs, and it happens once,
        // off the main actor, on the rotated file only.
        queue.async { [weak self] in self?.compactLocked() }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.flush() }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    /// Enqueues one row on the writer queue; returns without waiting for the disk. A row is
    /// rotated out of the way before an append that would pass `maxBytes`.
    func record(_ row: UsageRecord) {
        queue.async { [weak self] in self?.appendLocked(row) }
    }

    /// Waits for every queued write. Tests and `NSApplication.willTerminateNotification`
    /// only; nothing on the hot path calls this.
    func flush() {
        queue.sync {}
    }

    /// Both files, oldest first. Skips undecodable lines and rows with `v > schemaVersion`.
    func load(since: Date? = nil) -> [UsageRecord] {
        queue.sync {
            let decoder = Self.makeDecoder()
            var rows: [UsageRecord] = []
            for url in [rotatedURL, fileURL] {
                guard let data = try? Data(contentsOf: url) else { continue }
                for line in data.split(separator: 0x0A) where !line.isEmpty {
                    guard let row = try? decoder.decode(UsageRecord.self, from: Data(line)),
                          row.v <= Self.schemaVersion else { continue }
                    if let since, row.ts < since { continue }
                    rows.append(row)
                }
            }
            return rows
        }
    }

    /// Deletes both files. The writer recreates `usage.jsonl` on the next `record`.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
            try? FileManager.default.removeItem(at: self.rotatedURL)
        }
    }

    /// Drops rows older than `maxAgeDays` from `usage.1.jsonl`. Called once at init.
    func compact() {
        queue.async { [weak self] in self?.compactLocked() }
    }

    /// What is safe to keep in `errorMessage`: no quoted content, no e-mail addresses, URLs,
    /// file paths or long digit runs, whitespace collapsed, at most 160 characters.
    static func sanitise(_ message: String) -> String {
        var text = message
        // Quoted content first: it is the most likely place for a message body, a subject or
        // a name the sender wrapped in quotes, and removing it before the other rules keeps
        // the quote pair from hiding an address or a path from them.
        text = text.replacingOccurrences(of: #""[^"]*""#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"“[^”]*”"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"'[^']*'"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            with: "<redacted>", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?:https?|file)://\S+"#, with: "<redacted>",
                                         options: .regularExpression)
        // Absolute and home-relative paths, including a Windows drive path.
        text = text.replacingOccurrences(of: #"(?:~|/)[^\s"<]+"#, with: "<redacted>",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"[A-Za-z]:\\[^\s"<]+"#, with: "<redacted>",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\d{6,}"#, with: "<redacted>",
                                         options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 160 { text = String(text.prefix(160)) }
        return text
    }

    // MARK: - The writer queue

    private func appendLocked(_ row: UsageRecord) {
        guard let data = try? Self.makeEncoder().encode(row) else { return }
        var line = data
        line.append(0x0A)
        let size = Self.fileSize(at: fileURL)
        if size > 0, size + line.count > maxBytes {
            rotateLocked()
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }

    /// `usage.jsonl` becomes `usage.1.jsonl`, replacing whatever was there. The rotated file
    /// is the only one age compaction rewrites; the current file is never rewritten while
    /// appending.
    private func rotateLocked() {
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
    }

    private func compactLocked() {
        guard let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day, value: -maxAgeDays, to: now()) else { return }
        guard let data = try? Data(contentsOf: rotatedURL), !data.isEmpty else { return }
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()
        var kept: [Data] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let row = try? decoder.decode(UsageRecord.self, from: Data(line)),
                  row.v <= Self.schemaVersion, row.ts >= cutoff,
                  let encoded = try? encoder.encode(row) else { continue }
            kept.append(encoded)
        }
        var body = Data()
        for line in kept {
            body.append(line)
            body.append(0x0A)
        }
        try? body.write(to: rotatedURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `FileManager`, not `URL.resourceValues`: a cached `URL` answers a stale size
    /// (AGENTS.md).
    private static func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.intValue
    }
}
