import Foundation

/// `--selftest-model-unopenable` (P0-13).
///
/// Pins the guard that keeps a file this build of llama.cpp cannot open out of the agent's
/// reach: before a download, on install, and before a role is assigned. Six cases:
///
/// - **A** an unknown architecture is refused from the header, without loading any weights;
/// - **B** a supported name with nothing behind it is reported as a failed open, not as an
///   unknown architecture (the captured-log classification);
/// - **C** a real file this build can open still opens, quickly (S1-mini, when present);
/// - **D** the installed library lists an unrunnable row but never offers it as usable, and
///   a row written before the verdict existed still decodes;
/// - **E** the pre-download verdict refuses a build this app cannot run and passes one it can;
/// - **F** the generated architecture list matches the build: it has the names llama.cpp
///   opens and not the one it refuses.
///
/// The red-first run fails on A, B, D and E, because the seams reproduce today's permissive
/// behaviour: a readable header is treated as an open, `usableModels` does not filter on a
/// verdict, and nothing reads the Hub's architecture before a download.
@MainActor
enum ModelSupportSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NextNotesSelfTest-gguf-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            return ["the fixture directory could not be created: \(error.localizedDescription)"]
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        failures += await caseAUnknownArchitecture(scratch: scratch)
        failures += await caseBSupportedNameWithNothingBehindIt(scratch: scratch)
        failures += await caseCRealSupportedFile()
        failures += caseDLibraryExcludesUnrunnable(scratch: scratch)
        failures += caseEPreDownloadVerdict()
        failures += caseFGeneratedListMatchesTheBuild()
        return failures
    }

    /// The `[String]` shape is what `ModelRoleSelfTest.run()` returns, so a registration
    /// block can print the final line itself. This helper prints it instead, for a
    /// registration that only wants a Bool; exactly one of the two must be used.
    static func runSelfTest() async -> Bool {
        let failures = await run()
        for failure in failures { SelfTest.diagnostic("model-unopenable · \(failure)") }
        SelfTest.diagnostic(failures.isEmpty
            ? "MODEL_UNOPENABLE_OK: unsupported files refused before any weight load"
            : "MODEL_UNOPENABLE_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }

    // MARK: - A. An unknown architecture is refused before any weight load

    private static func caseAUnknownArchitecture(scratch: URL) async -> [String] {
        var failures: [String] = []
        let url = scratch.appendingPathComponent("unknown-architecture.gguf")
        do {
            try writeGGUF(to: url, kv: [
                ("general.architecture", .string("nn-selftest-unknown")),
                ("general.alignment", .uint32(32)),
            ])
        } catch {
            return ["case A: could not write the fixture: \(error.localizedDescription)"]
        }

        guard let metadata = GGUFMetadata.read(url) else {
            return ["case A: the reader could not read a GGUF this test just wrote"]
        }
        if metadata.architecture != "nn-selftest-unknown" {
            failures.append("case A: the reader reported "
                + "\(metadata.architecture ?? "nil") instead of nn-selftest-unknown")
        }

        let loadsBefore = LlamaLoadProbe.fullWeightLoadCount()
        let started = Date()
        let result = await LlamaLoadProbe.probe(url)
        let elapsed = Date().timeIntervalSince(started)
        let loadsAfter = LlamaLoadProbe.fullWeightLoadCount()

        if result.verdict != .unsupportedArchitecture {
            failures.append("case A: an architecture this build does not know was reported "
                + "as \(result.verdict.rawValue), not as unsupported")
        } else if result.detail != "nn-selftest-unknown" {
            failures.append("case A: the refusal did not name the architecture "
                + "(\(result.detail ?? "nil"))")
        }
        if loadsAfter != loadsBefore {
            failures.append("case A: deciding support loaded full weights "
                + "(\(loadsAfter - loadsBefore) load(s))")
        }
        if elapsed >= 0.05 {
            failures.append("case A: deciding support took "
                + "\(Int((elapsed * 1000).rounded())) ms, over the 50 ms budget")
        }
        return failures
    }

    // MARK: - B. A supported name with nothing behind it fails the open, not the header

    private static func caseBSupportedNameWithNothingBehindIt(scratch: URL) async -> [String] {
        let url = scratch.appendingPathComponent("supported-name-broken.gguf")
        do {
            try writeGGUF(to: url, kv: [("general.architecture", .string("llama"))])
        } catch {
            return ["case B: could not write the fixture: \(error.localizedDescription)"]
        }
        let result = await LlamaLoadProbe.probe(url)
        guard result.verdict != .failedToOpen else { return [] }
        return ["case B: a supported name with no model behind it was reported as "
            + "\(result.verdict.rawValue), not as a failed open"]
    }

    // MARK: - C. A real file this build can open still opens

    private static func caseCRealSupportedFile() async -> [String] {
        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic(
                "S1MINI_ABSENT: S1-mini is not downloaded, so the real-file case was skipped")
            return []
        }
        let started = Date()
        let result = await LlamaLoadProbe.probe(S1MiniModels.spec.fileURL)
        let elapsed = Date().timeIntervalSince(started)
        var failures: [String] = []
        if result.verdict != .opens {
            failures.append("case C: a real model this build can open was reported as "
                + "\(result.verdict.rawValue) (\(result.detail ?? "no detail"))")
        }
        if elapsed >= 2 {
            failures.append("case C: opening a real model took "
                + "\(String(format: "%.2f", elapsed)) s, over the 2 s budget")
        }
        return failures
    }

    // MARK: - D. The installed library excludes unrunnable rows

    private static func caseDLibraryExcludesUnrunnable(scratch: URL) -> [String] {
        var failures: [String] = []
        let unknownURL = scratch.appendingPathComponent("library-unknown.gguf")
        let opensURL = scratch.appendingPathComponent("library-opens.gguf")
        do {
            try writeGGUF(to: unknownURL, kv: [
                ("general.architecture", .string("nn-selftest-unknown")),
                ("general.alignment", .uint32(32)),
            ])
            try writeGGUF(to: opensURL, kv: [("general.architecture", .string("llama"))])
        } catch {
            return ["case D: could not write the fixtures: \(error.localizedDescription)"]
        }

        // A row written before `support` existed must still decode; that is what keeps
        // every library.json on disk from vanishing.
        let legacyJSON = Data(#"[{"id":"legacy/model.gguf","displayName":"Legacy","fileURL":"file:///tmp/legacy.gguf","bytes":123,"isBuiltIn":false}]"#.utf8)
        do {
            let legacy = try JSONDecoder().decode([InstalledLocalModel].self, from: legacyJSON)
            if legacy.count != 1 || legacy.first?.support != nil {
                failures.append("case D: a library row written before this change no longer decodes")
            }
        } catch {
            failures.append("case D: a library row written before this change no longer "
                + "decodes (\(error))")
        }

        let suiteName = "NextNotesSelfTest-model-unopenable-\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return failures + ["case D: the isolated defaults suite could not be created"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let library = InstalledModelLibrary(
            manifestURL: scratch.appendingPathComponent("library.json"), defaults: defaults)

        let unknownBytes = ModelDownloader.fileSize(at: unknownURL)
        let unknown = InstalledLocalModel(
            id: "selftest/model-unopenable/unknown.gguf",
            displayName: "Self-test unknown",
            fileURL: unknownURL,
            parameterBillions: nil,
            quantization: nil,
            bytes: unknownBytes,
            isBuiltIn: false,
            support: LlamaProbeResult(
                verdict: .unsupportedArchitecture,
                detail: "nn-selftest-unknown",
                llamaBuildTag: LlamaArchitectures.buildTag,
                fileBytes: unknownBytes)
        )
        library.add(unknown)

        let opensBytes = ModelDownloader.fileSize(at: opensURL)
        let opens = InstalledLocalModel(
            id: "selftest/model-unopenable/opens.gguf",
            displayName: "Self-test opens",
            fileURL: opensURL,
            parameterBillions: nil,
            quantization: nil,
            bytes: opensBytes,
            isBuiltIn: false,
            support: LlamaProbeResult(
                verdict: .opens,
                detail: "llama",
                llamaBuildTag: LlamaArchitectures.buildTag,
                fileBytes: opensBytes)
        )
        library.add(opens)

        if !library.models.contains(where: { $0.id == unknown.id }) {
            failures.append("case D: the unrunnable file vanished from the installed list, "
                + "so it cannot be deleted")
        }
        if library.usableModels.contains(where: { $0.id == unknown.id }) {
            failures.append("case D: a file this app cannot run is still offered as usable")
        }
        if !library.usableModels.contains(where: { $0.id == opens.id }) {
            failures.append("case D: a file the probe opened was excluded from the usable list")
        }
        return failures
    }

    // MARK: - E. The pre-download verdict

    private static func caseEPreDownloadVerdict() -> [String] {
        var failures: [String] = []
        func details(_ architecture: String) -> HuggingFaceModelDetails {
            HuggingFaceModelDetails(
                id: "selftest/\(architecture)",
                isGated: false,
                licenseID: nil,
                parameterCount: nil,
                architecture: architecture,
                trainedContextLength: nil,
                files: [])
        }

        if let refused = ModelLibraryStore.downloadSupportVerdict(for: details("k2-horizon")) {
            if refused != .architecture("k2-horizon") {
                failures.append("case E: the pre-download refusal did not name the build "
                    + "(\(refused))")
            }
        } else {
            failures.append("case E: a model built in a way this app cannot run was not "
                + "flagged before its download")
        }

        if let refused = ModelLibraryStore.downloadSupportVerdict(for: details("qwen3")) {
            failures.append("case E: a model this app can run was refused before its "
                + "download (\(refused))")
        }
        return failures
    }

    // MARK: - F. The generated list matches the build

    private static func caseFGeneratedListMatchesTheBuild() -> [String] {
        var failures: [String] = []
        for name in ["qwen3", "qwen35", "llama", "gemma3", "gemma4"]
        where !LlamaArchitectures.isSupported(name) {
            failures.append("case F: the generated list is missing \(name), which this "
                + "build can open")
        }
        if LlamaArchitectures.isSupported("k2-horizon") {
            failures.append("case F: the generated list claims k2-horizon, which this "
                + "build cannot open")
        }
        if LlamaArchitectures.buildTag.isEmpty {
            failures.append("case F: the generated file does not name the build it was "
                + "generated from")
        }
        return failures
    }

    // MARK: - Fixtures

    /// A value the fixture writer can serialize. Only the two types these fixtures need:
    /// a string (GGUF type 8) and a uint32 (GGUF type 4).
    enum GGUFValue {
        case string(String)
        case uint32(UInt32)
    }

    /// Writes the smallest legal GGUF: magic, version 3, no tensors, then the key-value
    /// pairs. `gguf_init_from_file` reads it without any tensor data behind it.
    static func writeGGUF(to url: URL, kv: [(String, GGUFValue)]) throws {
        var data = Data()
        data.append(contentsOf: Array("GGUF".utf8))
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(0).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(kv.count).littleEndian) { Array($0) })
        for (key, value) in kv {
            let keyBytes = Array(key.utf8)
            data.append(contentsOf: withUnsafeBytes(of: UInt64(keyBytes.count).littleEndian) { Array($0) })
            data.append(contentsOf: keyBytes)
            switch value {
            case .string(let text):
                data.append(contentsOf: withUnsafeBytes(of: UInt32(8).littleEndian) { Array($0) })
                let bytes = Array(text.utf8)
                data.append(contentsOf: withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { Array($0) })
                data.append(contentsOf: bytes)
            case .uint32(let number):
                data.append(contentsOf: withUnsafeBytes(of: UInt32(4).littleEndian) { Array($0) })
                data.append(contentsOf: withUnsafeBytes(of: number.littleEndian) { Array($0) })
            }
        }
        try data.write(to: url)
    }
}
