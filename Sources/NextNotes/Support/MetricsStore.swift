import Foundation

/// Rolling latency spans: an in-memory ring and a JSONL file beside `runs.jsonl`.
///
/// Append-only on the hot path, same shape as `RunLog`, because recording a span
/// must stay one write. The ring is the recent window a later dashboard will
/// read; the file is what survives a relaunch. Info-level os_log is not that
/// window — those lines age out within minutes.
///
/// Not `@MainActor`. Dictation, meetings and the agent will record from whatever
/// isolation they already sit on; a lock keeps the ring and the file in step.
final class MetricsStore: @unchecked Sendable {
    static let shared = MetricsStore(directory: SelfTest.isRunning
        ? FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        : AppIdentity.applicationSupportDirectory)

    /// Enough for a day's dictation plus meetings without holding a growing array.
    static let defaultRingCapacity = 512

    static let fileName = "metrics.jsonl"

    let directory: URL
    let fileURL: URL
    private let ringCapacity: Int
    private let lock = NSLock()
    private var ring: [LatencySpan] = []
    private var linesOnDisk = 0

    init(
        directory: URL = AppIdentity.applicationSupportDirectory,
        ringCapacity: Int = MetricsStore.defaultRingCapacity
    ) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.ringCapacity = max(1, ringCapacity)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = Self.load(from: fileURL)
        ring = Array(loaded.suffix(self.ringCapacity))
        linesOnDisk = loaded.count
        if linesOnDisk > self.ringCapacity {
            rewriteLockedContents()
            linesOnDisk = ring.count
        }
    }

    func record(_ span: LatencySpan) {
        lock.lock()
        defer { lock.unlock() }
        ring.append(span)
        if ring.count > ringCapacity {
            ring.removeFirst(ring.count - ringCapacity)
        }
        appendLocked(span)
        if linesOnDisk > ringCapacity * 2 {
            rewriteLockedContents()
            linesOnDisk = ring.count
        }
    }

    /// Chronological, oldest first — the order the file is written.
    func spans(named name: LatencySpanID? = nil) -> [LatencySpan] {
        lock.lock()
        defer { lock.unlock() }
        guard let name else { return ring }
        return ring.filter { $0.name == name }
    }

    func span(id: UUID) -> LatencySpan? {
        lock.lock()
        defer { lock.unlock() }
        return ring.first { $0.id == id }
    }

    static func load(from url: URL) -> [LatencySpan] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(LatencySpan.self, from: Data(line))
        }
    }

    private func appendLocked(_ span: LatencySpan) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(span) else { return }
        line.append(0x0A)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do {
                try handle.write(contentsOf: line)
                linesOnDisk += 1
            } catch {
                return
            }
        } else {
            do {
                try line.write(to: fileURL)
                linesOnDisk += 1
            } catch {
                return
            }
        }
    }

    /// Called under `lock`, or from `init` before any other thread can see `self`.
    private func rewriteLockedContents() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = ring.compactMap { span -> String? in
            guard let data = try? encoder.encode(span) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Same probe as `LatencyTrace.runSelfTest()` — the harness can call either.
    @discardableResult
    static func runSelfTest() -> Bool {
        LatencyTrace.runSelfTest()
    }
}
