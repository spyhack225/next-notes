import Foundation
import Observation

/// `agent-schedules.json` and its run history, `agent-schedule-runs.jsonl`.
///
/// Written atomically like `agent-tasks.json`, and separate from it on purpose — the task
/// store fails every unfinished task on launch. A write that fails (a full disk) leaves the
/// previous file whole and reports it; nothing here truncates.
///
/// Routine output is run history, not memory (lesson 4): the history file is append-only
/// JSON lines, trimmed from the front once it grows past `historyLimit` lines.
@MainActor
@Observable
final class ScheduleStore {
    /// The production store. A self-test never touches the user's files: it gets a
    /// per-process temporary directory.
    static let shared: ScheduleStore = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-schedules-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return ScheduleStore(directory: directory)
        }
        return ScheduleStore(directory: AppIdentity.applicationSupportDirectory)
    }()

    static let fileName = "agent-schedules.json"
    static let historyFileName = "agent-schedule-runs.jsonl"
    static let historyLimit = 2_000

    private(set) var schedules: [AgentSchedule] = []
    /// Bumped on every save, so views can follow run history without reading the file.
    private(set) var revision = 0

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    var historyURL: URL { directory.appendingPathComponent(Self.historyFileName) }

    init(directory: URL) {
        self.directory = directory
        schedules = load()
    }

    // MARK: - Schedules

    func schedule(id: UUID) -> AgentSchedule? {
        schedules.first { $0.id == id }
    }

    /// Inserts or replaces by id, then writes the whole file.
    @discardableResult
    func save(_ schedule: AgentSchedule) -> Bool {
        var next = schedules
        if let index = next.firstIndex(where: { $0.id == schedule.id }) {
            next[index] = schedule
        } else {
            next.append(schedule)
        }
        return write(next)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        write(schedules.filter { $0.id != id })
    }

    /// Re-reads the file. The scheduler rebuilds every decision from disk each pass, so an
    /// edit made elsewhere is seen on the next tick.
    func reload() {
        schedules = load()
    }

    private func load() -> [AgentSchedule] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try Self.decoder.decode([AgentSchedule].self, from: data)
        } catch {
            Log.app.error("agent-schedules.json is unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func write(_ next: [AgentSchedule]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(next)
            try data.write(to: fileURL, options: .atomic)
            schedules = next
            revision += 1
            return true
        } catch {
            Log.app.error("couldn't save agent-schedules.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Run history

    func appendRun(_ record: ScheduleRunRecord) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var line = try Self.lineEncoder.encode(record)
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let handle = try FileHandle(forWritingTo: historyURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: historyURL, options: .atomic)
            }
            revision += 1
            trimHistoryIfNeeded()
        } catch {
            Log.app.error("couldn't append schedule run: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Newest last. `scheduleID` nil returns every schedule's history.
    func runs(for scheduleID: UUID? = nil, limit: Int = 200) -> [ScheduleRunRecord] {
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let records = text.split(whereSeparator: \.isNewline).compactMap { line -> ScheduleRunRecord? in
            try? Self.decoder.decode(ScheduleRunRecord.self, from: Data(line.utf8))
        }
        let filtered = scheduleID.map { id in records.filter { $0.scheduleID == id } } ?? records
        return Array(filtered.suffix(limit))
    }

    private func trimHistoryIfNeeded() {
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count > Self.historyLimit + Self.historyLimit / 4 else { return }
        let kept = lines.suffix(Self.historyLimit).joined(separator: "\n") + "\n"
        try? Data(kept.utf8).write(to: historyURL, options: .atomic)
    }

    // MARK: - Coding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var lineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
