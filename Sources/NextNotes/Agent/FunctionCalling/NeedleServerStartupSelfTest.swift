import Foundation

/// The meeting's overlapping warm/complete callers must settle a failed start,
/// not recursively await its already-completed Task. Uses the actual server and
/// Process/HTTP startup path, a temporary failing peer, and no model/owner store.
@MainActor
enum NeedleServerStartupSelfTest {
    static func run(log: (String) -> Void) async -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("needle-startup-\(UUID().uuidString)", isDirectory: true)
        let server = NeedleServer()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("failed-engine")
            let counter = directory.appendingPathComponent("launches")
            try """
            #!/bin/sh
            printf 'launch\\n' >> "$2"
            /bin/sleep 0.2
            printf 'fixture startup failed\\n' >&2
            exit 1

            """.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let configuration = NeedleServer.Configuration(
                executable: executable, weights: counter,
                toolsFile: directory.appendingPathComponent("unused-tools"),
                facts: "", workingDirectory: directory)
            let failed = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        do { _ = try await server.complete(input: ".", configuration: configuration); return false }
                        catch { return true }
                    }
                }
                var count = 0
                for await value in group { if value { count += 1 } }
                return count
            }
            let firstLaunches = launches(at: counter)
            // The exact meeting producer also warms repeatedly on transcript events.
            let settled = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        await server.warm(configuration: configuration)
                        return 1
                    }
                }
                var count = 0
                for await value in group { count += value }
                return count
            }
            let totalLaunches = launches(at: counter)
            let child = await server.liveProcessIdentifier()
            await server.stop()
            let passed = failed == 16 && firstLaunches == NeedleServer.maximumStartAttempts
                && settled == 16 && totalLaunches == 2 * NeedleServer.maximumStartAttempts && child == nil
            log("NEEDLE_STARTUP_\(passed ? "OK" : "FAILED"): failed=\(failed)/16 warm_settled=\(settled)/16 launches=\(firstLaunches)/\(totalLaunches) child=\(child == nil ? "none" : "unexpected")")
            return passed
        } catch {
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
            log("NEEDLE_STARTUP_FAILED: fixture setup failed")
            return false
        }
    }

    private static func launches(at url: URL) -> Int {
        (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
    }
}
