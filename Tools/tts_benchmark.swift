import AVFoundation
import Darwin
import Foundation

/// A small, dependency-free TTS probe for the current Mac.
///
/// The Apple measurement uses AVSpeechSynthesizer.write(_:toBufferCallback:), so
/// `firstAudioMs` is the time to the first non-empty generated PCM buffer. It is
/// deliberately labelled generated audio rather than audible speaker output:
/// this probe does not route audio to the speakers. The interrupt measurement
/// uses the same write path and calls stopSpeaking(at: .immediate).
@main
struct TTSBenchmark {
    struct Options {
        var text = "I found three matching files. The latest is enclosure version seventeen."
        var trials = 3
        var interruptAfterMs: Double = 250
        var timeoutSeconds: Double = 15
        var engine = "all"
        var volume: Float = 0
        var output: String?
    }

    struct Inventory: Codable {
        let macOS: String
        let architecture: String
        let chip: String
        let memoryGB: Double
        let engines: [EngineInventory]
    }

    struct EngineInventory: Codable {
        let name: String
        let available: Bool
        let installed: Bool
        let benchmarkable: Bool
        let executable: String?
        let pythonModules: [String]
        let modelPaths: [String]
        let missingDependencies: [String]
        let notes: String
    }

    struct Trial: Codable {
        let index: Int
        let firstAudioMs: Double?
        let completionMs: Double?
        let interruptRequestedMs: Double?
        let stopToIdleMs: Double?
        let callbackCount: Int
        let generatedFrames: Int
        let interrupted: Bool
        let timedOut: Bool
        let cpuUserMs: Double
        let cpuSystemMs: Double
        let peakRSSMB: Double
    }

    struct Report: Codable {
        let schema: String
        let generatedAt: String
        let machine: Inventory
        let requestedEngine: String
        let benchmarkedEngines: [String]
        let unbenchmarkedEngines: [String: String]
        let text: String
        let interruptAfterMs: Double
        let trials: [Trial]
        let measurementNotes: [String]
    }

    @MainActor
    static func main() {
        do {
            let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
            let inventory = makeInventory()
            if options.engine == "inventory" {
                try emit(inventory, output: options.output)
                return
            }

            let apple = inventory.engines.first(where: { $0.name == "AVSpeechSynthesizer" })!
            guard apple.available else {
                throw ProbeError.message("AVSpeechSynthesizer is unavailable on this Mac")
            }
            guard options.engine == "all" || options.engine == "apple" else {
                let candidate = options.engine == "kokoro" ? "Kokoro ONNX" : "Piper"
                let found = inventory.engines.first(where: { $0.name == candidate })!
                throw ProbeError.message(
                    "\(candidate) unavailable: \(found.missingDependencies.joined(separator: "; "))"
                )
            }

            let trials = try runApple(options)
            let alternativeNames = ["Kokoro ONNX", "Piper"]
            let unbenchmarked = Dictionary(uniqueKeysWithValues: alternativeNames.map { name in
                let engine = inventory.engines.first(where: { $0.name == name })!
                let reason = engine.installed
                    ? "runner/model detected, but this diagnostic has no \(name) adapter"
                    : "not installed: \(engine.missingDependencies.joined(separator: "; "))"
                return (name, reason)
            })
            let report = Report(
                schema: "tts-benchmark.v1",
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                machine: inventory,
                requestedEngine: options.engine,
                benchmarkedEngines: ["AVSpeechSynthesizer"],
                unbenchmarkedEngines: unbenchmarked,
                text: options.text,
                interruptAfterMs: options.interruptAfterMs,
                trials: trials,
                measurementNotes: [
                    "AVSpeechSynthesizer.write callback measures first generated PCM buffer, not speaker-audible output.",
                    "RAM is process peak RSS from getrusage; CPU is process user/system time over each trial.",
                    "Interruptibility is measured on the write path: stopSpeaking(.immediate) followed by idle polling.",
                    "Kokoro and Piper are inventory-only when dependencies/models are absent; no weights are downloaded."
                ]
            )
            try emit(report, output: options.output)
        } catch {
            fputs("TTS_BENCHMARK_FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            if case let .message(value) = self { return value }
            return "unknown error"
        }
    }

    static func parseOptions(_ args: [String]) throws -> Options {
        var value = Options()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--text":
                i += 1; guard i < args.count else { throw ProbeError.message("--text needs a value") }
                value.text = args[i]
            case "--trials":
                i += 1; guard i < args.count, let n = Int(args[i]), n > 0 else { throw ProbeError.message("--trials needs a positive integer") }
                value.trials = n
            case "--interrupt-after-ms":
                i += 1; guard i < args.count, let n = Double(args[i]), n >= 0 else { throw ProbeError.message("--interrupt-after-ms needs a non-negative number") }
                value.interruptAfterMs = n
            case "--timeout-seconds":
                i += 1; guard i < args.count, let n = Double(args[i]), n > 0 else { throw ProbeError.message("--timeout-seconds needs a positive number") }
                value.timeoutSeconds = n
            case "--engine":
                i += 1; guard i < args.count else { throw ProbeError.message("--engine needs all, apple, kokoro, piper, or inventory") }
                value.engine = args[i].lowercased()
            case "--output":
                i += 1; guard i < args.count else { throw ProbeError.message("--output needs a path") }
                value.output = args[i]
            case "--help", "-h":
                print("Usage: tts_benchmark [--engine all|apple|kokoro|piper|inventory] [--trials N] [--text TEXT] [--output PATH]")
                exit(0)
            default:
                throw ProbeError.message("unknown option \(args[i])")
            }
            i += 1
        }
        guard ["all", "apple", "kokoro", "piper", "inventory"].contains(value.engine) else {
            throw ProbeError.message("--engine must be all, apple, kokoro, piper, or inventory")
        }
        return value
    }

    static func emit<T: Encodable>(_ value: T, output: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        if let output {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
        } else {
            print(String(decoding: data, as: UTF8.self))
        }
    }

    static func makeInventory() -> Inventory {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000
        let piperExecutables = ["piper", "piper-tts"].compactMap { executablePath($0) }
        let kokoroExecutables = ["kokoro", "kokoro-onnx"].compactMap { executablePath($0) }
        let kokoroModules = pythonModules(["kokoro", "kokoro_onnx", "onnxruntime"])
        let piperModules = pythonModules(["piper", "piper_phonemize", "onnxruntime"])
        let kokoroModels = modelFiles(containing: ["kokoro"])
        let piperModels = modelFiles(containing: ["piper"])
            let kokoroMissing = missing(
                engine: "Kokoro",
            executables: kokoroExecutables,
            modules: kokoroModules,
            requiredModules: ["kokoro or kokoro_onnx", "onnxruntime"],
            models: kokoroModels,
            modelRequirement: "Kokoro ONNX model and voice files"
        )
            let piperMissing = missing(
                engine: "Piper",
            executables: piperExecutables,
            modules: piperModules,
            requiredModules: ["piper or piper-tts", "onnxruntime"],
            models: piperModels,
            modelRequirement: "Piper .onnx voice model plus .onnx.json config"
        )
        return Inventory(
            macOS: macOS,
            architecture: commandOutput("/usr/bin/uname", arguments: ["-m"]) ?? "unknown",
            chip: commandOutput("/usr/sbin/sysctl", arguments: ["-n", "machdep.cpu.brand_string"]) ?? "unknown",
            memoryGB: memoryGB,
            engines: [
                EngineInventory(
                    name: "AVSpeechSynthesizer",
                    available: AVSpeechSynthesisVoice(language: "en-US") != nil,
                    installed: true,
                    benchmarkable: true,
                    executable: "/usr/bin/swiftc / AVFoundation",
                    pythonModules: [], modelPaths: [], missingDependencies: [],
                    notes: "Apple system voice; no model download."
                ),
                EngineInventory(
                    name: "Kokoro ONNX",
                    available: false,
                    installed: kokoroMissing.isEmpty,
                    benchmarkable: false,
                    executable: kokoroExecutables.first,
                    pythonModules: kokoroModules,
                    modelPaths: kokoroModels,
                    missingDependencies: kokoroMissing,
                    notes: "Inventory includes source checkout names, but source code is not a runnable model."
                ),
                EngineInventory(
                    name: "Piper",
                    available: false,
                    installed: piperMissing.isEmpty,
                    benchmarkable: false,
                    executable: piperExecutables.first,
                    pythonModules: piperModules,
                    modelPaths: piperModels,
                    missingDependencies: piperMissing,
                    notes: "No executable/model means no Piper comparison is claimed."
                )
            ]
        )
    }

    static func missing(engine: String, executables: [String], modules: [String], requiredModules: [String], models: [String], modelRequirement: String) -> [String] {
        var result: [String] = []
        if executables.isEmpty { result.append("no \(engine.lowercased()) command found on PATH") }
        if executables.isEmpty && modules.isEmpty {
            result.append("no CLI or Python runner (\(requiredModules.joined(separator: ", "))) is installed")
        }
        if models.isEmpty { result.append("\(modelRequirement) not found in local model search paths") }
        return result
    }

    static func executablePath(_ name: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func commandOutput(_ path: String, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pythonModules(_ names: [String]) -> [String] {
        names.filter { module in
            let process = Process()
            guard let python = executablePath("python3") else { return false }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-c", "import \(module)"]
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    static func modelFiles(containing needles: [String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "\(home)/Library/Application Support/Next Notes",
            "\(home)/Library/Application Support/Kokoro",
            "\(home)/Library/Application Support/Piper",
            "\(home)/.cache/kokoro",
            "\(home)/.cache/piper",
            "\(FileManager.default.currentDirectoryPath)/Models",
            "\(FileManager.default.currentDirectoryPath)/Resources/Models"
        ]
        let files = roots.flatMap { root -> [String] in
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
            return enumerator.compactMap { item in
                let path = (root as NSString).appendingPathComponent(item as! String)
                let lower = path.lowercased()
                guard needles.contains(where: { lower.contains($0) }), lower.hasSuffix(".onnx") || lower.hasSuffix(".onnx.json") else { return nil }
                return path
            }
        }
        return Array(Set(files)).sorted()
    }

    @MainActor
    static func runApple(_ options: Options) throws -> [Trial] {
        var result: [Trial] = []
        for index in 1...options.trials {
            let probe = SpeechWriteProbe()
            let before = Usage()
            let started = DispatchTime.now().uptimeNanoseconds
            let utterance = AVSpeechUtterance(string: options.text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.volume = options.volume
            probe.startedNs = started
            probe.synthesizer.write(utterance) { [weak probe] buffer in
                probe?.accept(buffer)
            }
            let deadline = Date().addingTimeInterval(options.timeoutSeconds)
            while !probe.finished && Date() < deadline {
                if let firstAudioNs = probe.firstAudioNs,
                   !probe.interruptSent,
                   probe.interruptDeadlineMs == nil {
                    let firstAudioMs = Double(firstAudioNs - started) / 1_000_000
                    probe.interruptDeadlineMs = firstAudioMs + options.interruptAfterMs
                }
                if let interruptDeadlineMs = probe.interruptDeadlineMs,
                   !probe.interruptSent,
                   Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000 >= interruptDeadlineMs {
                    probe.interruptSent = true
                    probe.interruptRequestedNs = DispatchTime.now().uptimeNanoseconds
                    probe.synthesizer.stopSpeaking(at: .immediate)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            let after = Usage()
            let firstMs = probe.firstAudioNs.map { Double($0 - started) / 1_000_000 }
            let completionMs = probe.finishedNs.map { Double($0 - started) / 1_000_000 }
            let stopMs = probe.idleNs.flatMap { idle in
                probe.interruptRequestedNs.map { Double(idle - $0) / 1_000_000 }
            }
            result.append(Trial(
                index: index,
                firstAudioMs: firstMs,
                completionMs: completionMs,
                interruptRequestedMs: probe.interruptRequestedNs.map { Double($0 - started) / 1_000_000 },
                stopToIdleMs: stopMs,
                callbackCount: probe.callbackCount,
                generatedFrames: probe.generatedFrames,
                interrupted: probe.interruptSent && probe.idleNs != nil,
                timedOut: !probe.finished,
                cpuUserMs: max(0, after.userMs - before.userMs),
                cpuSystemMs: max(0, after.systemMs - before.systemMs),
                peakRSSMB: after.peakRSSMB
            ))
        }
        return result
    }
}

@MainActor
final class SpeechWriteProbe: NSObject, AVSpeechSynthesizerDelegate {
    let synthesizer = AVSpeechSynthesizer()
    var startedNs: UInt64 = 0
    var firstAudioNs: UInt64?
    var finishedNs: UInt64?
    var interruptRequestedNs: UInt64?
    var idleNs: UInt64?
    var interruptDeadlineMs: Double?
    var callbackCount = 0
    var generatedFrames = 0
    var interruptSent = false
    var finished = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func accept(_ buffer: AVAudioBuffer) {
        callbackCount += 1
        if let pcm = buffer as? AVAudioPCMBuffer {
            generatedFrames += Int(pcm.frameLength)
            if pcm.frameLength > 0, firstAudioNs == nil {
                firstAudioNs = DispatchTime.now().uptimeNanoseconds
            }
        }
        if interruptRequestedNs != nil, idleNs == nil, !synthesizer.isSpeaking {
            idleNs = DispatchTime.now().uptimeNanoseconds
        }
        if buffer.audioBufferList.pointee.mNumberBuffers > 0,
           buffer.audioBufferList.pointee.mBuffers.mDataByteSize == 0 {
            finished = true
            finishedNs = DispatchTime.now().uptimeNanoseconds
            if idleNs == nil { idleNs = finishedNs }
        }
    }
}

struct Usage {
    let userMs: Double
    let systemMs: Double
    let peakRSSMB: Double

    init() {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        userMs = Double(usage.ru_utime.tv_sec) * 1_000 + Double(usage.ru_utime.tv_usec) / 1_000
        systemMs = Double(usage.ru_stime.tv_sec) * 1_000 + Double(usage.ru_stime.tv_usec) / 1_000
        peakRSSMB = Double(usage.ru_maxrss) / 1_048_576
    }
}
