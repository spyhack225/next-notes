import AppKit
import FluidAudio
import Foundation

/// OFF-SOURCE, UNCOMPILED. The existing standalone native-termination entry
/// dispatches here only when its additional exact startup-case flag is present.
/// These are preparation owners, not live ASR / caller-owned synthesis streams.
@MainActor
enum NativeStartupTerminationSelfTest {
    /// Called by the SAME standalone entry before constructing its delegate.
    /// Invalid input reports only to stdout; it may never write a supplied path.
    nonisolated static func validateArgumentsBeforeOwners() throws {
        let arguments = CommandLine.arguments
        guard arguments.filter({ $0 == "--native-startup-case" }).count == 1,
              arguments.filter({ $0 == "--native-startup-assets" }).count == 1,
              !arguments.contains("--native-termination-model"),
              !arguments.contains("--native-termination-recording-mode"),
              let caseIndex = arguments.firstIndex(of: "--native-startup-case"),
              arguments.indices.contains(caseIndex + 1),
              let assetsIndex = arguments.firstIndex(of: "--native-startup-assets"),
              arguments.indices.contains(assetsIndex + 1) else { throw CocoaError(.fileReadNoPermission) }
        let mode = arguments[caseIndex + 1]
        guard ["parakeet-load", "pocket-load", "parakeet-closed", "pocket-closed",
               "asr-queue-active", "asr-queue-queued", "asr-queue-closed",
               "final-pass-active", "final-pass-cancel", "final-pass-closed",
               "diarizer-active", "diarizer-cancel", "diarizer-closed", "diarizer-stall",
               "diarizer-stall-cancel", "diarizer-stall-quit"].contains(mode) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = try (NativeDiarizationQuitSelfTest.modes.contains(mode)
            ? NativeDiarizationQuitSelfTest.validateAssets(URL(fileURLWithPath: arguments[assetsIndex + 1]))
            : validateAssets(URL(fileURLWithPath: arguments[assetsIndex + 1]), pocket: mode.hasPrefix("pocket")))
        if let path = SelfTest.outputPath {
            let output = URL(fileURLWithPath: path).standardizedFileURL
            guard output.resolvingSymlinksInPath().path == output.path,
                  output.deletingLastPathComponent().path == root.path,
                  output.lastPathComponent == "startup.log" else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: output.path) {
                let value = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard value.isRegularFile == true, value.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            }
        }
    }

    static func armIfRequested() async throws -> Bool {
        if try await NativeDiarizationQuitSelfTest.armIfRequested() { return true }
        if try await NativeFinalTranscriptQuitSelfTest.armIfRequested() { return true }
        if try await ASRQueueTerminationSelfTest.armIfRequested() { return true }
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--native-startup-case") else { return false }
        guard SelfTest.requested == "--selftest-native-termination",
              arguments.indices.contains(index + 1),
              let assetsIndex = arguments.firstIndex(of: "--native-startup-assets"),
              arguments.indices.contains(assetsIndex + 1),
              let delegate = AppDelegate.current else { throw CocoaError(.fileReadNoPermission) }
        let mode = arguments[index + 1]
        guard ["parakeet-load", "pocket-load", "parakeet-closed", "pocket-closed"].contains(mode) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let root = try validateAssets(URL(fileURLWithPath: arguments[assetsIndex + 1]),
                                      pocket: mode.hasPrefix("pocket"))
        // Per-process fixture policy, before any FluidAudio model owner is touched.
        // Complete local copies are required; no missing asset may trigger download.
        ModelHub.offlineMode = true
        let closedCase = mode.hasSuffix("closed")
        let trace = StartupTerminationTrace(autoQuit: !closedCase)
        let parakeet: ParakeetModels? = mode.hasPrefix("parakeet")
            ? try ParakeetModels(terminationFixtureRoot: root, trace: trace) : nil
        let pocket: PocketAgentVoice? = mode.hasPrefix("pocket")
            ? try PocketAgentVoice(terminationFixtureRoot: root, trace: trace) : nil
        func check(_ label: String, _ condition: Bool) {
            trace.check(condition)
            if !condition {
                SelfTest.failed = true
                SelfTest.diagnostic("STARTUP_TERMINATION_ASSERT_FAILED: \(label)")
            }
        }
        try delegate.configureStartupTerminationFixture(
            parakeet: parakeet, pocket: pocket,
            reply: { reply in
                let observed = trace.snapshot()
                check("C01 Cocoa quit returns later", reply == .terminateLater)
                if !closedCase {
                    // Lack of actual overlap invalidates the comparison. A call-entry
                    // bracket does not prove that a particular CoreML kernel is running.
                    let qualified = observed.ownedTaskPending && observed.activeLoads == 1
                        && (pocket != nil || observed.compilingCallbacks > 0)
                    check("C02 actual owned preparation is pending at Cocoa quit", qualified)
                    if !qualified { trace.invalidate() }
                }
                SelfTest.diagnostic("STARTUP_TERMINATION_REPLY_TRACE mode=\(mode) pending=\(observed.ownedTaskPending) loads=\(observed.activeLoads) compileCallbacks=\(observed.compilingCallbacks) later=\(reply == .terminateLater)")
            },
            willExit: {
                let observed = trace.snapshot()
                if closedCase {
                    check("F01 closed owner admits no new load", observed.loadStarts == 0)
                    check("F02 closed owner admits no warmup or readiness publication", observed.warmStarts == 0 && observed.readyPublications == 0)
                    check("C03 closed admission probe returned", observed.probeReturned)
                } else {
                    check("F03 quit joins the actual existing preparation handle", !observed.ownedTaskPending && observed.ownedTaskEnds == 1)
                    check("F04 quit drains its actual load boundary", observed.activeLoads == 0 && observed.loadStarts == observed.loadEnds)
                    check("F05 closed preparation publishes no new readiness or warmup", observed.readyPublications == 0 && observed.warmStarts == 0)
                }
                if let pocket {
                    check("F07 Pocket cleanup leaves preparation inactive", !pocket.isPreparing)
                    check("F06 closing Pocket announces no load failure", pocket.errorMessage == nil)
                }
                check("C05 offline mode remains enforced", ModelHub.offlineMode)
                let final = trace.snapshot()
                SelfTest.diagnostic("STARTUP_TERMINATION_EXIT_TRACE mode=\(mode) starts=\(final.loadStarts) ends=\(final.loadEnds) active=\(final.activeLoads) pending=\(final.ownedTaskPending) taskEnds=\(final.ownedTaskEnds) warms=\(final.warmStarts) ready=\(final.readyPublications) compileCallbacks=\(final.compilingCallbacks) checks=\(final.checks) failures=\(final.failures) invalid=\(final.invalid)")
                if final.invalid {
                    SelfTest.failed = true
                    SelfTest.diagnostic("STARTUP_TERMINATION_INVALID: actual preparation overlap unavailable")
                } else {
                    SelfTest.diagnostic(final.failures == 0
                        ? "STARTUP_TERMINATION_OK: \(final.checks) checks"
                        : "STARTUP_TERMINATION_FAILED: \(final.failures)/\(final.checks)")
                }
            }
        )
        SelfTest.diagnostic("STARTUP_TERMINATION_INPUT_OK: confined copied public assets; offline model loading")
        if closedCase {
            // Separate from the load-overlap case: this await cannot accidentally
            // join the old active load and hide a missing quit drain there.
            if let parakeet {
                await parakeet.beginTermination()
                do { _ = try await parakeet.manager() } catch { /* typed refusal is checked by zero entry */ }
            }
            if let pocket {
                pocket.beginTermination()
                await pocket.prepare()
            }
            trace.recordProbeReturned()
            SelfTest.requestTermination()
        } else {
            if let parakeet {
                Task {
                    do { _ = try await parakeet.manager() }
                    catch { /* owner trace records real load return; no diagnostic payload */ }
                }
            }
            if let pocket { Task { @MainActor in await pocket.prepare() } }
            // Existing owner callback schedules the actual Cocoa quit; no timer,
            // sleep, fake loader, blocking interceptor, or second quit.
        }
        return true
    }

    /// Validate confinement before any supplied asset metadata. Never enumerate
    /// a caller's parent, an owner cache, or an arbitrary source directory.
    nonisolated static func validateAssets(_ candidate: URL, pocket: Bool) throws -> URL {
        let fm = FileManager.default
        let root = candidate.standardizedFileURL
        let temporary = fm.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesStartupTerminationTest-"
        guard SelfTest.requested == "--selftest-native-termination",
              root.isFileURL,
              root.resolvingSymlinksInPath().path == root.path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        var enumerationFailure = false
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                                             options: [], errorHandler: { _, _ in enumerationFailure = true; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        while let item = enumerator.nextObject() as? URL {
            guard item.standardizedFileURL.resolvingSymlinksInPath().path == item.standardizedFileURL.path,
                  item.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let value = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard value.isSymbolicLink != true,
                  value.isDirectory == true || value.isRegularFile == true else { throw CocoaError(.fileReadNoPermission) }
        }
        guard !enumerationFailure else { throw CocoaError(.fileReadNoPermission) }
        let base = root.appendingPathComponent(pocket ? "Models/" + Repo.pocketTts.folderName + "/" + PocketTtsLanguage.english.repoSubdirectory : "parakeet-tdt-0.6b-v3")
        let bundles = pocket
            ? ["cond_prefill.mlmodelc", "flowlm_stepv2.mlmodelc", "flow_decoder_fused.mlmodelc", "mimi_decoder.mlmodelc"]
            : ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc"]
        for bundle in bundles {
            let file = base.appendingPathComponent(bundle)
            let value = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard value.isDirectory == true, value.isSymbolicLink != true,
                  let contents = fm.enumerator(at: file, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]),
                  contents.allObjects.compactMap({ $0 as? URL }).contains(where: {
                      let v = try? $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                      return v?.isRegularFile == true && (v?.fileSize ?? 0) > 0
                  }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        let files = pocket
            ? ["constants_bin/bos_emb.bin", "constants_bin/text_embed_table.bin", "constants_bin/tokenizer.model",
               "constants_bin/bos_before_voice.bin", "constants_bin/alba.safetensors"]
            : ["parakeet_vocab.json"]
        for file in files {
            let value = try base.appendingPathComponent(file).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard value.isRegularFile == true, (value.fileSize ?? 0) > 0 else { throw CocoaError(.fileReadCorruptFile) }
        }
        if pocket {
            guard !fm.fileExists(atPath: base.appendingPathComponent("flowlm_step.mlmodelc").path) else {
                throw CocoaError(.fileReadNoPermission) // no fixture-side library cleanup of an extra variant
            }
        }
        return root
    }
}

/// Metadata only. Counts real existing owner calls / task bodies; never blocks
/// the native path and never retains model output, text, path, or frame samples.
final class StartupTerminationTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Snapshot()
    private let autoQuit: Bool
    init(autoQuit: Bool) { self.autoQuit = autoQuit }
    struct Snapshot: Sendable {
        var loadStarts = 0
        var loadEnds = 0
        var activeLoads = 0
        var compilingCallbacks = 0
        var ownedTaskPending = false
        var ownedTaskEnds = 0
        var warmStarts = 0
        var readyPublications = 0
        var probeReturned = false
        var checks = 0
        var failures = 0
        var invalid = false
        var quitScheduled = false
    }
    func assigned() { lock.withLock { value.ownedTaskPending = true } }
    func taskEnded() { lock.withLock { value.ownedTaskPending = false; value.ownedTaskEnds += 1 } }
    func loadEntered(pocket: Bool) {
        let request = lock.withLock { () -> Bool in
            value.loadStarts += 1; value.activeLoads += 1
            guard autoQuit, pocket, !value.quitScheduled else { return false }
            value.quitScheduled = true; return true
        }
        if request { requestQuit() }
    }
    func loadReturned() { lock.withLock { value.loadEnds += 1; value.activeLoads -= 1 } }
    func progress(_ progress: DownloadProgress) {
        guard case .compiling(let name) = progress.phase, !name.isEmpty else { return }
        let request = lock.withLock { () -> Bool in
            value.compilingCallbacks += 1
            guard autoQuit, !value.quitScheduled else { return false }
            value.quitScheduled = true; return true
        }
        if request { requestQuit() }
    }
    func warmEntered() { lock.withLock { value.warmStarts += 1 } }
    func readyPublished() { lock.withLock { value.readyPublications += 1 } }
    func recordProbeReturned() { lock.withLock { value.probeReturned = true } }
    func check(_ accepted: Bool) { lock.withLock { value.checks += 1; if !accepted { value.failures += 1 } } }
    func invalidate() { lock.withLock { value.invalid = true } }
    func snapshot() -> Snapshot { lock.withLock { value } }
    private func requestQuit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                SelfTest.diagnostic("STARTUP_TERMINATION_QUIT_REQUEST: actual preparation boundary")
                NSApp.terminate(nil)
            }
        }
    }
}
