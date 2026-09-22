import Foundation

/// Durable calibration history. `WakeWordCalibrator.attempts` is in-memory and dies
/// with the process, so a phrase that "often fails" left no record of when it was
/// tested, at which sensitivity, or what each attempt measured. This store appends one
/// JSON line per finished (or abandoned) run, beside the existing wake model files.
///
/// Each attempt carries `peakLevel` and `elapsed` (stored on `WakeWordAttempt` since
/// P0-1), so a persisted miss still tells silence (`peakLevel` ~ 0) apart from an
/// unheard phrase, and a hit still shows its promptness. `heardAs` is the generous
/// listener's variant attribution — the same string the Settings row explains with —
/// so the file answers *which pronunciation* each attempt matched.
///
/// Under `--selftest-*` the file lives in a per-process temp directory, matching the
/// `MetricsStore` split: a self-test never appends to the user's history.
enum WakeWordCalibrationStore {
    struct Run: Codable, Sendable {
        var at: Date
        var phrase: String
        var sensitivity: Double
        /// False when the run was stopped before all attempts finished.
        var completed: Bool
        var attempts: [WakeWordAttempt]
    }

    static var fileURL: URL {
        let base = SelfTest.isRunning
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : AppIdentity.applicationSupportDirectory
        return base.appendingPathComponent("WakeWord/calibration-history.jsonl")
    }

    static func append(_ run: Run) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(run) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: fileURL)
        }
    }

    static func load() -> [Run] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Run.self, from: Data(line))
        }
    }
}
