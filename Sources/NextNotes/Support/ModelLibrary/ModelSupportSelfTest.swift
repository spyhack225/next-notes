import Foundation

/// `--selftest-model-unopenable` (P0-13, extended by P0-02).
///
/// Pins the guard that keeps a file this build of llama.cpp cannot open out of the agent's
/// reach: before a download, on install, and before a role is assigned. Seven cases:
///
/// - **A** an unknown architecture is refused from the header, without loading any weights;
/// - **B** a supported name with nothing behind it is reported as a failed open, not as an
///   unknown architecture (the captured-log classification);
/// - **C** a real file this build can open still opens, quickly (S1-mini, when present);
/// - **D** the installed library lists an unrunnable row but never offers it as usable, and
///   a row written before the verdict existed still decodes;
/// - **E** the pre-download verdict refuses a build this app cannot run and passes one it can;
/// - **F** the generated architecture list matches the build: it has the names llama.cpp
///   opens and not the one it refuses;
/// - **G** (P0-02) the post-download check trials the new file *before* anything is
///   switched or deleted, only a trial that generated a token may switch or delete, and
///   the confirmation sheet never leans toward deleting the only model that answers.
///
/// P0-13's cases A–F are green. P0-02's case G is the red-first case: today's
/// post-download policy switches the active model before it checks anything and asks
/// `prepare()` — which only opens a file — so the trial's verdict is never recorded, the
/// switch happens before the check, and the confirmation sheet still leans toward
/// deleting the only model that answers.
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
        failures += await postDownloadVerify(scratch: scratch)
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

    // MARK: - G. The post-download check (P0-02)

    /// The policy's trial has to happen *before* the switch, and only a trial that
    /// generated a token may switch or delete anything.
    ///
    /// 1. a new file that opens but cannot answer leaves the previous model active and on
    ///    disk, and its failed trial is recorded on the row;
    /// 2. a new file that answers switches and deletes the old one, and its successful
    ///    trial is recorded on the row;
    /// 3. the trial runs before the switch — today the switch comes first;
    /// 4. live: S1-mini answers a token, and the P0-13 unknown-architecture fixture
    ///    cannot open;
    /// 5. the confirmation sheet never recommends deleting the only model that answers.
    ///
    /// Everything runs against scratch files and an isolated library, so no model is
    /// downloaded, no real file is deleted and the person's own library is never touched.
    /// Red-first: today's body switches first and asks `prepare()` — which only opens a
    /// file — so 2, 3 and 5 fail, the row's `lastTrial` is never written, and the live
    /// trial reports a file that opened without answering.
    private static func postDownloadVerify(scratch: URL) async -> [String] {
        var failures: [String] = []

        let suiteName = "NextNotesSelfTest-p0-02-\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["post-download: the isolated defaults suite could not be created"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        /// One independent pair of models: a previous one that is active, and a new one
        /// that has just been downloaded. Each is a real (sparse) file in its own folder
        /// with its own manifest, so a delete in one case cannot make the next one pass
        /// or fail for the wrong reason. The probe verdict is seeded, so the lazy support
        /// pass leaves these rows alone.
        func makeFixture(
            _ tag: String
        ) -> (library: InstalledModelLibrary, store: ModelLibraryStore,
              previous: InstalledLocalModel, new: InstalledLocalModel)? {
            let directory = scratch.appendingPathComponent("post-download-\(tag)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                return nil
            }
            let previousURL = directory.appendingPathComponent("previous.gguf")
            let newURL = directory.appendingPathComponent("new.gguf")
            FileManager.default.createFile(
                atPath: previousURL.path, contents: Data(repeating: 0x41, count: 4_096))
            FileManager.default.createFile(
                atPath: newURL.path, contents: Data(repeating: 0x42, count: 8_192))

            func row(_ id: String, _ name: String, _ url: URL) -> InstalledLocalModel {
                let bytes = ModelDownloader.fileSize(at: url)
                return InstalledLocalModel(
                    id: id, displayName: name, fileURL: url,
                    parameterBillions: nil, quantization: nil, bytes: bytes, isBuiltIn: false,
                    support: LlamaProbeResult(
                        verdict: .opens, detail: "llama",
                        llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: bytes))
            }

            let library = InstalledModelLibrary(
                manifestURL: directory.appendingPathComponent("library.json"), defaults: defaults)
            let previous = row("selftest/p0-02/\(tag)/previous.gguf", "Previous \(tag)", previousURL)
            let new = row("selftest/p0-02/\(tag)/new.gguf", "New \(tag)", newURL)
            library.add(previous)
            library.add(new)
            library.activeAgentModelID = previous.id
            return (library, ModelLibraryStore(library: library), previous, new)
        }

        // 1. A new file that opens but cannot answer must not switch, and must not delete.
        if let fixture = makeFixture("a") {
            fixture.store.verifyForTesting = { _ in .opensButCannotAnswer("context") }
            await fixture.store.applyPostDownloadPolicyForTesting(
                .switchDeleteOld, previousActiveID: fixture.previous.id, newModel: fixture.new)
            if !FileManager.default.fileExists(atPath: fixture.previous.fileURL.path) {
                failures.append("post-download 1: the previous model was deleted although "
                    + "the new file never answered")
            }
            if fixture.library.activeAgentModelID != fixture.previous.id {
                failures.append("post-download 1: the active model moved to the new file "
                    + "although it never answered")
            }
            if fixture.library.model(withID: fixture.new.id)?.lastTrial
                != .opensButCannotAnswer("context") {
                failures.append("post-download 1: the failed trial was not recorded on the row")
            }
        } else {
            failures.append("post-download 1: the scratch folder could not be created")
        }

        // 2. A new file that answers switches, and only then deletes the old one.
        if let fixture = makeFixture("b") {
            fixture.store.verifyForTesting = { _ in .answered(tokens: 3, seconds: 0.2) }
            await fixture.store.applyPostDownloadPolicyForTesting(
                .switchDeleteOld, previousActiveID: fixture.previous.id, newModel: fixture.new)
            if FileManager.default.fileExists(atPath: fixture.previous.fileURL.path) {
                failures.append("post-download 2: the old model was kept although the new "
                    + "one answered a trial")
            }
            if fixture.library.activeAgentModelID != fixture.new.id {
                failures.append("post-download 2: the new model answered but is not the "
                    + "active one")
            }
            if fixture.library.model(withID: fixture.new.id)?.lastTrial
                != .answered(tokens: 3, seconds: 0.2) {
                failures.append("post-download 2: the successful trial was not recorded on the row")
            }
        } else {
            failures.append("post-download 2: the scratch folder could not be created")
        }

        // 3. Ordering: the trial must run before the switch. The verify closure records
        //    what the library looked like at the moment it was asked, so a switch that
        //    happened first is visible there — and a check that never ran records nothing.
        if let fixture = makeFixture("c") {
            let library = fixture.library
            let log = PostDownloadEventLog()
            let writesBefore = library.activeSelectionWrites
            fixture.store.verifyForTesting = { _ in
                let active = await MainActor.run { library.activeAgentModelID }
                let writes = await MainActor.run { library.activeSelectionWrites }
                log.record("verify active=\(active) writes=\(writes)")
                return .answered(tokens: 3, seconds: 0.2)
            }
            await fixture.store.applyPostDownloadPolicyForTesting(
                .switchDeleteOld, previousActiveID: fixture.previous.id, newModel: fixture.new)
            let expected = "verify active=\(fixture.previous.id) writes=\(writesBefore)"
            if log.events != [expected] {
                failures.append("post-download 3: the new model was not checked before the "
                    + "switch (events: \(log.events))")
            }
            if library.activeAgentModelID != fixture.new.id {
                failures.append("post-download 3: the trial answered but the switch never happened")
            }
        } else {
            failures.append("post-download 3: the scratch folder could not be created")
        }

        // 4. Live: S1-mini answers a token, and an architecture this build cannot open is
        //    refused as `.cannotOpen`. Nothing is downloaded or written; the first half is
        //    skipped, loudly, when S1-mini is not on this Mac.
        if S1MiniModels.spec.isDownloaded {
            let s1mini = InstalledLocalModel(
                id: "selftest/p0-02/s1-mini.gguf",
                displayName: S1MiniModels.spec.displayName,
                fileURL: S1MiniModels.spec.fileURL,
                parameterBillions: 1.5,
                quantization: "Q4_K_M",
                bytes: S1MiniModels.spec.expectedBytes,
                isBuiltIn: false)
            let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
            let began = Date()
            let result = await runtime.trial(s1mini)
            let elapsed = Date().timeIntervalSince(began)
            switch result {
            case .answered(let tokens, _):
                if tokens < 1 {
                    failures.append("post-download live: S1-mini was reported as answering "
                        + "with 0 tokens")
                } else if elapsed >= 5 {
                    failures.append("post-download live: the S1-mini trial took "
                        + "\(String(format: "%.1f", elapsed)) s, over the 5 s budget")
                }
            case .opensButCannotAnswer(let reason):
                failures.append("post-download live: S1-mini opened but answered nothing "
                    + "(\(reason))")
            case .cannotOpen(let reason):
                failures.append("post-download live: S1-mini could not be opened (\(reason))")
            }
        } else {
            SelfTest.diagnostic(
                "S1MINI_ABSENT: S1-mini is not downloaded, so the live trial was skipped")
        }

        let unknownURL = scratch.appendingPathComponent("post-download-unknown.gguf")
        do {
            try writeGGUF(to: unknownURL, kv: [
                ("general.architecture", .string("nn-selftest-unknown")),
                ("general.alignment", .uint32(32)),
            ])
        } catch {
            return failures + ["post-download live: the unknown-architecture fixture could "
                + "not be written: \(error.localizedDescription)"]
        }
        let unknown = InstalledLocalModel(
            id: "selftest/p0-02/unknown.gguf",
            displayName: "Unknown architecture",
            fileURL: unknownURL,
            parameterBillions: nil,
            quantization: nil,
            bytes: ModelDownloader.fileSize(at: unknownURL),
            isBuiltIn: false)
        let unknownRuntime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let unknownResult = await unknownRuntime.trial(unknown)
        if case .cannotOpen = unknownResult {
            // Expected: this build refuses the architecture before any context exists.
        } else {
            failures.append("post-download live: an architecture this build cannot open was "
                + "reported as \(unknownResult), not as .cannotOpen")
        }

        // 5. The sheet must never steer toward deleting the only model that answers.
        let cramped: Int64 = 4_300_000_000
        let newFile: Int64 = 2_500_000_000
        if ModelLibraryStore.recommendsDeletingOld(
            freeBytes: cramped, fileBytes: newFile, otherAnsweringModels: 0) {
            failures.append("post-download 5: the sheet would lean toward deleting the only "
                + "model that answers")
        }
        if !ModelLibraryStore.recommendsDeletingOld(
            freeBytes: cramped, fileBytes: newFile, otherAnsweringModels: 1) {
            failures.append("post-download 5: a Mac with another answering model was not "
                + "warned that space is short")
        }
        if ModelLibraryStore.recommendsDeletingOld(
            freeBytes: 40_000_000_000, fileBytes: newFile, otherAnsweringModels: 1) {
            failures.append("post-download 5: a Mac with plenty of free space was told to "
                + "delete a model")
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

/// Records the order the post-download steps happened in, from closures that run off the
/// main actor. A lock rather than an actor, so a record lands synchronously and the order
/// is the order things actually happened in.
private final class PostDownloadEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String] = []

    func record(_ event: String) { lock.withLock { value.append(event) } }

    var events: [String] { lock.withLock { value } }
}
