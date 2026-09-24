import Foundation

/// `--selftest-model-unopenable` (P0-13, extended by P0-02 and P0-14).
///
/// Pins the guard that keeps a file this build of llama.cpp cannot open out of the agent's
/// reach: before a download, on install, and before a role is assigned. Eight cases:
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
///   the confirmation sheet never leans toward deleting the only model that answers;
/// - **H** (P0-14) one provider per turn, resolution read-only, a failed full load
///   remembered and never re-selected, the load outcome honest (`.modelUnopenable`, not a
///   wedged runtime), and an in-turn fallback that never says "the tool planner failed".
///
/// P0-13's cases A–F and P0-02's case G are green. P0-14's case H is the red-first case:
/// resolution writes the library selection on every turn and returns a provider resolved
/// against a runtime that has not adopted it yet, the runtime throws `.modelLoadFailed`
/// for a file that cannot open (and wedges itself), and the planner reports the load
/// failure to the user instead of falling back once.
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
        failures += await providerPerTurnAndFailedLoads(scratch: scratch)
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

    // MARK: - H. One provider per turn, failed loads remembered (P0-14)

    /// Everything here is isolated: a temp manifest, a `UserDefaults` suite, a runtime this
    /// test owns, and a library whose adopter points at that runtime — the real switch path
    /// the harness used to skip. The one file that has to live in the app's Models folder is
    /// the fixture itself, because `ModelSpec.fileURL` is always `Models/` plus the file
    /// name; it is a few hundred bytes with a self-test name, and it is removed in a `defer`.
    private static func providerPerTurnAndFailedLoads(scratch: URL) async -> [String] {
        var failures: [String] = []

        let suiteName = "NextNotesSelfTest-p0-14-\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["case H: the isolated defaults suite could not be created"]
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let directory = scratch.appendingPathComponent("p0-14", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["case H: the scratch folder could not be created: \(error.localizedDescription)"]
        }

        // The fixture is a legal GGUF header naming an architecture this build refuses.
        // Its verdict is pre-seeded as `.opens` on purpose: that is the file the probe
        // missed, and it forces the first-time full-load failure the fix must remember.
        let fixtureName = "selftest-p0-14-unopenable-\(ProcessInfo.processInfo.processIdentifier).gguf"
        let fixtureURL = ModelSpec.directory.appendingPathComponent(fixtureName)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        do {
            try FileManager.default.createDirectory(
                at: ModelSpec.directory, withIntermediateDirectories: true)
            try writeGGUF(to: fixtureURL, kv: [
                ("general.architecture", .string("nn-selftest-unknown")),
                ("general.alignment", .uint32(32)),
            ])
        } catch {
            return ["case H: the fixture could not be written: \(error.localizedDescription)"]
        }
        let fixtureBytes = ModelDownloader.fileSize(at: fixtureURL)
        let fixture = InstalledLocalModel(
            id: "selftest/p0-14/unopenable.gguf",
            displayName: "Self-test unopenable",
            fileURL: fixtureURL,
            parameterBillions: nil,
            quantization: nil,
            bytes: fixtureBytes,
            isBuiltIn: false,
            support: LlamaProbeResult(
                verdict: .opens,
                detail: "nn-selftest-unknown",
                llamaBuildTag: LlamaArchitectures.buildTag,
                fileBytes: fixtureBytes))

        let runtime = NotesModelRuntime(spec: NotesModels.spec, gpuLayers: 0)
        let failureStore = ModelOpenFailureStore(defaults: defaults)
        let library = InstalledModelLibrary(
            manifestURL: directory.appendingPathComponent("library.json"),
            defaults: defaults,
            runtimeAdopter: { await runtime.select($0) })
        library.add(fixture)
        // The runtime records a failed full open the way the production sink does; the
        // store is the test's, so nothing lands in the owner's defaults.
        await runtime.setOpenFailureSinkForTesting { spec, reason in
            await MainActor.run {
                failureStore.record(
                    path: spec.fileURL.path, bytes: spec.expectedBytes, reason: reason)
            }
        }

        let store = ModelRoleStore(
            defaults: defaults,
            availability: .nothingInstalled,
            library: library,
            runtime: runtime,
            failures: failureStore)
        store.setChoiceForTesting(.installedModel(id: fixture.id), for: .agent)

        // 1. A file this build cannot open throws the unopenable error — not the generic
        //    load failure — and leaves the notes runtime retryable instead of wedged.
        await runtime.select(fixture)
        do {
            try await runtime.prepare()
            failures.append("case H 1: prepare() reported success for a file this build cannot open")
        } catch let error as LlamaError {
            if case .modelUnopenable(let name) = error {
                if name != fixture.displayName {
                    failures.append("case H 1: the unopenable error named "
                        + "“\(name)” instead of “\(fixture.displayName)”")
                }
            } else {
                failures.append("case H 1: a file this build cannot open threw "
                    + "\(error.localizedDescription), not the unopenable error")
            }
        } catch {
            failures.append("case H 1: prepare() threw \(error.localizedDescription)")
        }
        let notesState = await ModelRuntimeManager.shared.snapshot(.notes).state
        if notesState == .wedged {
            failures.append("case H 1: a file that cannot open wedged the notes runtime")
        }
        // Leave the process-wide registry as it was found.
        _ = await ModelRuntimeManager.shared.markUnloaded(.notes)

        // 2. Two resolutions in a row are the same answer, that answer is not the failed
        //    file's runtime, and neither call writes the library selection (3).
        let writesBefore = library.activeSelectionWrites
        let first = await AgentModelRouting.provider(
            for: "What can you do?", voice: false, roles: store)
        let second = await AgentModelRouting.provider(
            for: "What can you do?", voice: false, roles: store)
        if first?.id != second?.id {
            failures.append("case H 2: two resolutions in a row disagreed ("
                + "\(first?.id.rawValue ?? "nil") then \(second?.id.rawValue ?? "nil"))")
        }
        if let first, first.id == .appLLM {
            failures.append("case H 2: resolution chose the app's own runtime for a file "
                + "that failed to open")
        }
        let writesAfter = library.activeSelectionWrites
        if writesAfter != writesBefore {
            failures.append("case H 3: resolution wrote the library's active selection "
                + "(\(writesAfter - writesBefore) write(s))")
        }
        // The failed file must not be left selected in the runtime either. The old path's
        // library write reaches the runtime through the adopter asynchronously, so give it
        // a moment to land before deciding.
        var runtimeSpec = await runtime.activeSpec()
        for _ in 0..<20 where runtimeSpec.fileURL == fixtureURL {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))
            runtimeSpec = await runtime.activeSpec()
        }
        if runtimeSpec.fileURL == fixtureURL {
            failures.append("case H 2: resolution re-selected the failed file into the runtime")
        }

        // 4. A planner turn whose model cannot open falls back once and answers. It must
        //    never report the load failure as the reply.
        let agent = RealtimeAgent.shared
        let primary = P014UnopenablePlannerProvider()
        let fallback = P014AnswerProvider(id: .appleFoundation, reply: "Done.")
        let previousProvider = agent.localModelProviderForTesting
        let previousResolver = agent.plannerFallbackResolverForTesting
        let previousDeny = agent.denyUnattendedApprovalsForTesting
        agent.localModelProviderForTesting = primary
        agent.plannerFallbackResolverForTesting = { fallback }
        agent.denyUnattendedApprovalsForTesting = true
        defer {
            agent.localModelProviderForTesting = previousProvider
            agent.plannerFallbackResolverForTesting = previousResolver
            agent.denyUnattendedApprovalsForTesting = previousDeny
        }
        let plannerReply = await agent.runGeneralToolLoop("What can you do?")
        if plannerReply.contains("The tool planner failed:") {
            failures.append("case H 4: the planner reported the load failure instead of "
                + "falling back once (\(plannerReply.prefix(160)))")
        }
        if plannerReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("case H 4: the fallback produced no reply")
        }

        // 5. Prewarm asks the real routing; after the failure it is not local, so three
        //    warm-ups attempt no load at all.
        let attemptsBefore = await runtime.loadAttemptCount
        let warmups = P014PrewarmCounter()
        await runtime.setPrewarmProbeForTesting(NotesModelRuntime.PrewarmProbeForTesting(
            isModelAvailable: { true },
            isLocalRoute: { await AgentModelRouting.resolvesToLocalModel(voice: $0, roles: store) },
            onPrewarm: { await warmups.increment() }))
        for _ in 0..<3 { await runtime.prewarm().value }
        await runtime.setPrewarmProbeForTesting(nil)
        let attemptsAfter = await runtime.loadAttemptCount
        if attemptsAfter != attemptsBefore {
            failures.append("case H 5: a prewarm after the failure attempted "
                + "\(attemptsAfter - attemptsBefore) load(s)")
        }

        // 6. The sentence names what will actually answer. "Gemma" is only true when Gemma
        //    is on this Mac; on a machine without it the old sentence was simply false.
        if first == nil {
            SelfTest.diagnostic(
                "P0-14: no fallback provider on this Mac, so the notice was not exercised")
        } else if let message = ModelLoadNotice.shared.message {
            if !message.contains("can’t run on this Mac") {
                failures.append("case H 6: the notice did not say the file cannot run "
                    + "(\(message))")
            }
            if !NotesModels.isDownloaded, message.contains("Gemma") {
                failures.append("case H 6: the notice named Gemma although it is not on "
                    + "this Mac (\(message))")
            }
        } else {
            failures.append("case H 6: the fallback was taken but no notice was reported")
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

/// Counts prewarm callbacks for case H, off the main actor.
private actor P014PrewarmCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Case H's first pass opts into tools; its planner round throws the error a real
/// unopenable file produces, so the turn's fallback is what gets exercised.
private struct P014UnopenablePlannerProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        throw LlamaError.modelUnopenable("Self-test unopenable")
    }

    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("<use_tools/>")
            continuation.finish()
        }
    }

    func stream(
        system: String, user: String, maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LlamaError.modelUnopenable("Self-test unopenable"))
        }
    }
}

/// Case H's fallback: a provider of another kind that answers, so the turn continues on
/// it instead of reporting the failed load.
private struct P014AnswerProvider: LLMProvider {
    let id: LLMProviderID
    let reply: String
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        LLMCompletion(text: reply, generatedTokens: 1, duration: 0)
    }

    func stream(
        system: String, user: String, maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}
