import Darwin
import Foundation
import OSLog

enum Log { static let agent = Logger(subsystem: "meeting-startup-regression", category: "startup") }
enum NeedleRunner {
    static func firstLine(of text: String, fallback: String) -> String {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? fallback
    }
}

// NeedleResponse, JSONScalar and NeedleBuffers are extracted byte-for-byte from
// NeedleEngine.swift by the runner. The real NeedleServer.swift is compiled intact.
@main struct StartupRegression {
    static func footprint() -> UInt64 {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: value) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(value.phys_footprint) : 0
    }
    static func main() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let baseline = footprint()
        // Native thread watchdog remains runnable if a Swift actor spins. Test only.
        Thread.detachNewThread {
            let began = Date()
            while Date().timeIntervalSince(began) < 10 {
                let bytes = footprint()
                if bytes > baseline + 160_000_000 {
                    print("STARTUP_REGRESSION_FAILED runaway_async_frames footprint=\(bytes) baseline=\(baseline)")
                    fflush(nil); exit(2)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            print("STARTUP_REGRESSION_FAILED timeout")
            fflush(nil); exit(3)
        }
        if CommandLine.arguments.contains("--native") {
            let models = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Next Notes/Models")
            let tools = directory.appendingPathComponent("generated-tools.json")
            try! """
            [{"name":"save_note","description":"Save an explicitly requested note","parameters":{"type":"object","properties":{"text":{"type":"string","description":"The note text"}},"required":["text"]}}]
            """.write(to: tools, atomically: true, encoding: .utf8)
            let native = NeedleServer()
            let config = NeedleServer.Configuration(
                executable: models.appendingPathComponent("needle3-macos-arm64"),
                weights: models.appendingPathComponent("needle3.cact"),
                toolsFile: tools, facts: "This is a generated startup diagnostic.",
                workingDirectory: directory)
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 { group.addTask { await native.warm(configuration: config) } }
            }
            let first = await native.liveProcessIdentifier()
            guard first != nil else {
                print("NATIVE_STARTUP_FAILED no_adopted_child")
                fflush(nil); exit(1)
            }
            do {
                _ = try await native.complete(input: "The weather looks nice.", configuration: config)
            } catch {
                await native.stop()
                print("NATIVE_STARTUP_FAILED completion_error")
                fflush(nil); exit(1)
            }
            let second = await native.liveProcessIdentifier()
            let turns = await native.servedTurns
            await native.stop()
            guard first == second, turns == 1 else {
                print("NATIVE_STARTUP_FAILED child_replaced_or_wrong_turn_count")
                fflush(nil); exit(1)
            }
            print("NATIVE_STARTUP_OK 16_concurrent_warms one_child one_completion footprint=\(footprint())")
        }
        let server = NeedleServer()
        let configuration = NeedleServer.Configuration(
            executable: directory.appendingPathComponent("failed-engine"),
            weights: directory.appendingPathComponent("unused-model"),
            toolsFile: directory.appendingPathComponent("unused-tools"),
            facts: "", workingDirectory: directory)
        let failures = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do { _ = try await server.complete(input: ".", configuration: configuration); return false }
                    catch { return true }
                }
            }
            var count = 0
            for await failed in group { if failed { count += 1 } }
            return count
        }
        await server.stop()
        let launches = (try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        print("STARTUP_REGRESSION_RESULT failures=\(failures) launches=\(launches) footprint=\(footprint())")
        guard failures == 16, launches == 3 else {
            print("STARTUP_REGRESSION_FAILED expected_all_callers_fail_one_start_cohort")
            fflush(nil); exit(1)
        }
        print("STARTUP_REGRESSION_OK all_waiters_settled")
        let maintained = await NeedleServerStartupSelfTest.run(log: { print($0) })
        guard maintained else { fflush(nil); exit(1) }
        fflush(nil); exit(0)
    }
}
