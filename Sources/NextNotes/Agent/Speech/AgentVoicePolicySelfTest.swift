import Foundation

/// Single maintained source census shared with shell mutation checks. This is a
/// developer source-tree diagnostic, never part of application speech routing.
@MainActor
enum AgentVoicePolicySelfTest {
    static func run() -> [String] {
        guard SelfTest.isRunning else { return ["voice policy: harness required"] }
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        guard root.path != "/" else { return ["voice policy: source tree unavailable; census not run"] }
        let script = root.appendingPathComponent("Tests/Reports/no-apple/check-sink.py")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        process.standardOutput = pipe; process.standardError = pipe
        do {
            try process.run()
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: result, as: UTF8.self)
            for line in text.split(separator: "\n") { SelfTest.diagnostic(String(line)) }
            return process.terminationStatus == 0 && text.contains("VOICE_SINK_SOURCE_OK")
                ? [] : ["voice policy: complete source census failed or unavailable"]
        } catch { return ["voice policy: complete source census unavailable"] }
    }
}
