import CryptoKit
import Darwin
import Foundation

private struct Memory: Sendable {
    let rss: UInt64
    let footprint: UInt64
    static func read() -> Memory {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: basic) / MemoryLayout<integer_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout.size(ofValue: vm) / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        return Memory(rss: basicStatus == KERN_SUCCESS ? UInt64(basic.resident_size) : 0,
                      footprint: vmStatus == KERN_SUCCESS ? UInt64(vm.phys_footprint) : 0)
    }
}
private final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "sha256-probe-memory")
    private var timer: DispatchSourceTimer?
    private var peak = Memory(rss: 0, footprint: 0)
    private var count = 0
    func sample() {
        let memory = Memory.read()
        lock.lock()
        peak = Memory(rss: max(peak.rss, memory.rss), footprint: max(peak.footprint, memory.footprint))
        count += 1
        lock.unlock()
    }
    func start() {
        sample()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }
    func stop() -> (Memory, Int) {
        timer?.cancel()
        queue.sync {}
        sample()
        lock.lock()
        defer { lock.unlock() }
        return (peak, count)
    }
}
private func waitForGate(_ gate: DispatchSemaphore) { gate.wait() }
private func cpuSeconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
@main
private enum Probe {
    static func main() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.count == 3, ["before", "after", "contracts"].contains(args[1]) else {
            print("SHA256_PROBE_FAILED: require before|after|contracts and model path")
            exit(1)
        }
        let mode = args[1]
        let url = URL(fileURLWithPath: args[2])
        if mode == "contracts" {
            await contracts(largeFile: url)
            return
        }
        do {
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let baseline = Memory.read()
            let cpu = cpuSeconds()
            let began = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let sampler = Sampler()
            sampler.start()
            let hashed = try await Task.detached(priority: .utility) {
                try autoreleasepool {
                    let digest = try mode == "before" ? HashBefore.sha256(of: url) : HashAfter.sha256(of: url)
                    // This sample stays inside the caller's pool, like the native
                    // identity pass. Draining only afterward can hide a real peak.
                    sampler.sample()
                    return (digest, Memory.read())
                }
            }.value
            let stats = sampler.stop()
            let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - began) / 1_000_000_000
            let end = Memory.read()
            print("SHA256_PROBE arm=\(mode) bytes=\(bytes) digest=\(hashed.0) seconds=\(seconds) cpu_seconds=\(cpuSeconds() - cpu) baseline_rss=\(baseline.rss) baseline_footprint=\(baseline.footprint) sampled_peak_rss=\(stats.0.rss) sampled_peak_footprint=\(stats.0.footprint) in_pool_end_rss=\(hashed.1.rss) in_pool_end_footprint=\(hashed.1.footprint) after_pool_rss=\(end.rss) after_pool_footprint=\(end.footprint) samples=\(stats.1)")
        } catch {
            print("SHA256_PROBE_FAILED: \(String(describing: type(of: error)))")
            exit(1)
        }
    }
    private static func contracts(largeFile: URL) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sha256-contracts-\(UUID().uuidString)", isDirectory: true)
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ result: Bool) {
            checks += 1
            if !result { failures.append(name) }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let empty = root.appendingPathComponent("empty")
            let abc = root.appendingPathComponent("abc")
            try Data().write(to: empty)
            try Data("abc".utf8).write(to: abc)
            let expected = [empty: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", abc: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]
            for arm in ["before", "after"] {
                let hash: @Sendable (URL) throws -> String = { url in
                    try arm == "before" ? HashBefore.sha256(of: url) : HashAfter.sha256(of: url)
                }
                for (file, digest) in expected { check("\(arm) pinned digest", try hash(file) == digest) }
                for rejected in [root.appendingPathComponent("missing"), root] {
                    do { _ = try hash(rejected); check("\(arm) rejected file error", false) }
                    catch { check("\(arm) rejected file error", true) }
                }
                let gate = DispatchSemaphore(value: 0)
                let cancelled = Task.detached { waitForGate(gate); return try hash(abc) }
                cancelled.cancel()
                gate.signal()
                do { _ = try await cancelled.value; check("\(arm) initial cancellation", false) }
                catch is CancellationError { check("\(arm) initial cancellation", true) }
                catch { check("\(arm) initial cancellation wrong error", false) }
                let started = DispatchSemaphore(value: 0)
                let during = Task.detached { started.signal(); return try hash(largeFile) }
                waitForGate(started)
                try await Task.sleep(for: .milliseconds(10))
                during.cancel()
                do { _ = try await during.value; check("\(arm) chunk cancellation", false) }
                catch is CancellationError { check("\(arm) chunk cancellation", true) }
                catch { check("\(arm) chunk cancellation wrong error", false) }
            }
        } catch { failures.append("fixture setup or known digest threw") }
        for failure in failures { print("SHA256_CONTRACT_WRONG: \(failure)") }
        print(failures.isEmpty ? "SHA256_CONTRACT_OK: \(checks) checks" : "SHA256_CONTRACT_FAILED")
        if !failures.isEmpty { exit(1) }
    }
}
