import AppKit
import Foundation

/// COMMON, OFF-SOURCE / UNCOMPILED. Actual native actors and Cocoa delegate.
/// No native fake, download, saved role lookup, generation grader, or blocked C call.
@MainActor
enum NativeOtherLlamaQuitSelfTest {
    nonisolated static var isRequested: Bool {
        SelfTest.requested == "--selftest-native-termination"
            && CommandLine.arguments.contains("--native-llama-owner-case")
    }
    // The SAME actual operation Task, retained before any native callback can quit.
    private static var ownedOperation: Task<Void, Never>?
    nonisolated static let modes = ["s1-active", "s1-closed", "embedding-active", "embedding-closed",
                                   "vocab-active", "vocab-closed", "library-closed",
                                   "trial-parent-closed", "trial-parent-return"]

    nonisolated static var isTrialParentCase: Bool {
        guard isRequested,
              let index = CommandLine.arguments.firstIndex(of: "--native-llama-owner-case"),
              CommandLine.arguments.indices.contains(index + 1) else { return false }
        return ["trial-parent-closed", "trial-parent-return"].contains(CommandLine.arguments[index + 1])
    }

    nonisolated static func validateArgumentsBeforeOwners() throws {
        let arguments = CommandLine.arguments
        guard isRequested,
              arguments.filter({ $0 == "--native-llama-owner-case" }).count == 1,
              arguments.filter({ $0 == "--native-llama-owner-model" }).count == 1,
              !arguments.contains("--native-startup-case"), !arguments.contains("--native-startup-assets"),
              !arguments.contains("--native-termination-model"),
              !arguments.contains("--native-termination-recording-mode"),
              let index = arguments.firstIndex(of: "--native-llama-owner-case"),
              arguments.indices.contains(index + 1), modes.contains(arguments[index + 1]),
              let modelIndex = arguments.firstIndex(of: "--native-llama-owner-model"),
              arguments.indices.contains(modelIndex + 1) else { throw CocoaError(.fileReadNoPermission) }
        let mode = arguments[index + 1]
        let url = try validateModel(URL(fileURLWithPath: arguments[modelIndex + 1]), expected: spec(for: mode))
        if let path = SelfTest.outputPath {
            let output = URL(fileURLWithPath: path).standardizedFileURL
            guard output.resolvingSymlinksInPath().path == output.path,
                  output.deletingLastPathComponent() == url.deletingLastPathComponent(),
                  output.lastPathComponent == "other-owner.log" else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: output.path) {
                let value = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard value.isRegularFile == true, value.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            }
        }
    }

    nonisolated static func spec(for mode: String) -> ModelSpec {
        if mode.hasPrefix("s1") { return S1MiniModels.spec }
        if mode.hasPrefix("embedding") { return EmbeddingModels.embeddingGemma }
        return NotesModels.spec
    }

    nonisolated static func validateModel(_ candidate: URL, expected: ModelSpec) throws -> URL {
        guard isRequested else { throw CocoaError(.fileReadNoPermission) }
        let root = try confinedRoot(for: candidate)
        let file = candidate.standardizedFileURL
        guard file.lastPathComponent == "fixture.gguf", file.deletingLastPathComponent() == root else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map({ Int64($0) }) == expected.expectedBytes else { throw CocoaError(.fileReadCorruptFile) }
        // Root must verify source-pinned SHA256 and copied bytes before BOTH runs.
        // A size-only fixture check is not an identity assertion.
        return file
    }

    nonisolated private static func confinedRoot(for file: URL) throws -> URL {
        let candidate = file.standardizedFileURL
        let root = candidate.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesNativeOtherOwnerTest-"
        guard candidate.isFileURL, candidate.resolvingSymlinksInPath().path == candidate.path,
              root.deletingLastPathComponent() == temporary,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil else {
            throw CocoaError(.fileReadNoPermission)
        }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        return root
    }

    nonisolated static func isConfinedManifest(_ file: URL) -> Bool {
        guard isRequested, file.lastPathComponent == "library.json",
              (try? confinedRoot(for: file)) != nil else { return false }
        guard let value = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return value.isRegularFile == true && value.isSymbolicLink != true
    }

    static func armIfRequested() async throws -> Bool {
        guard isRequested else { return false }
        try validateArgumentsBeforeOwners()
        guard let delegate = AppDelegate.current,
              let caseIndex = CommandLine.arguments.firstIndex(of: "--native-llama-owner-case"),
              let modelIndex = CommandLine.arguments.firstIndex(of: "--native-llama-owner-model") else {
            throw CocoaError(.fileReadNoPermission)
        }
        let mode = CommandLine.arguments[caseIndex + 1]
        let modelFile = try validateModel(URL(fileURLWithPath: CommandLine.arguments[modelIndex + 1]), expected: spec(for: mode))
        if isTrialParentCase {
            return try await NativeModelTrialCallerSelfTest.arm(mode: mode, modelFile: modelFile, delegate: delegate)
        }
        let active = mode.hasSuffix("active")
        let trace = OtherLlamaTerminationTrace(autoQuit: active)
        let s1: S1MiniRuntime? = mode.hasPrefix("s1") ? S1MiniRuntime() : nil
        let embedding: EmbeddingRuntime? = mode.hasPrefix("embedding") ? EmbeddingRuntime(
            modelURL: modelFile, displayName: "Synthetic embedding quit", tag: "synthetic-embedding-quit",
            gpuLayers: 0, notesModelBusy: { false }, mayLoad: { _ in true }
        ) : nil
        if let s1 { try await s1.configureTerminationFixture(modelURL: modelFile, trace: trace) }
        if let embedding { try await embedding.configureTerminationFixture(trace: trace) }
        if mode.hasPrefix("vocab") || mode == "library-closed" {
            try await LlamaBackend.shared.configureProbeTerminationFixture(trace: trace)
        }
        var library: InstalledModelLibrary?
        var originalManifest: Data?
        var originalModel: InstalledLocalModel?
        let manifest = modelFile.deletingLastPathComponent().appendingPathComponent("library.json")
        let defaults = SelfTestHarnessDefaults.shared
        if mode == "library-closed" {
            guard !FileManager.default.fileExists(atPath: manifest.path) else { throw CocoaError(.fileWriteFileExists) }
            let model = InstalledLocalModel(
                id: "synthetic-public-quit-model", displayName: "Synthetic public quit model", fileURL: modelFile,
                parameterBillions: nil, quantization: nil, bytes: spec(for: mode).expectedBytes, isBuiltIn: false
            )
            let bytes = try JSONEncoder().encode([model])
            try bytes.write(to: manifest, options: .atomic)
            let owner = InstalledModelLibrary(manifestURL: manifest, defaults: defaults, runtimeAdopter: nil,
                                               isolatesBuiltInForTerminationTesting: true)
            library = owner; originalManifest = bytes; originalModel = model
        }
        let beforePersistent = defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:]
        func preferenceEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            NSDictionary(dictionary: lhs).isEqual(to: rhs)
        }
        if mode == "library-closed" {
            guard defaults === SelfTestHarnessDefaults.shared else { throw CocoaError(.fileWriteNoPermission) }
            let calibrationKey = "nativeOtherLlamaFixtureComparator." + UUID().uuidString
            guard beforePersistent[calibrationKey] == nil else { throw CocoaError(.fileWriteFileExists) }
            // Always clean up ONLY the unique key this calibration creates.
            defer { defaults.removeObject(forKey: calibrationKey) }
            defaults.set(true, forKey: calibrationKey)
            let changed = defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:]
            let sensitive = changed[calibrationKey] != nil && !preferenceEqual(beforePersistent, changed)
            defaults.removeObject(forKey: calibrationKey)
            let restored = preferenceEqual(beforePersistent,
                defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:])
            trace.cleanupCheck(sensitive)
            trace.cleanupCheck(restored)
            SelfTest.diagnostic("OTHER_LLAMA_PREFERENCE_NEGATIVE_CALIBRATION negativeSensitive=\(sensitive) exactRestored=\(restored) controls=2")
            guard sensitive, restored else {
                trace.invalidate(); SelfTest.failed = true
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        // Override ONLY this diagnostic's cold embedding selector. The COMMON
        // production default is eager; never resolve its owner path in this fixture.
        let quitEmbedding = embedding ?? EmbeddingRuntime(
            modelURL: modelFile, displayName: "Empty isolated quit owner", tag: "empty-isolated-quit",
            gpuLayers: 0, notesModelBusy: { false }, mayLoad: { _ in true }
        )
        func check(_ label: String, _ condition: Bool, input: Bool = false) {
            // Preserve the exact phase/input Boolean. Grade/emit all PRIMARY
            // assertions once at the first proposed verdict, never after cleanup.
            trace.enqueueAssertion(label: label, accepted: condition, input: input)
        }
        func cleanupCheck(_ label: String, _ condition: Bool) {
            trace.cleanupCheck(condition)
            if !condition {
                trace.invalidate(); SelfTest.failed = true
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_CLEANUP_FAILED: \(label)")
            }
        }
        func gradeFirstProposal() {
            let observed = trace.snapshot()
            check("F01 actual owner closes before process exit", observed.closes > 0)
            check("F02 all actual native brackets have returned before process exit", observed.active == 0 && observed.starts == observed.ends)
            if !active {
                check("C03 actual late admission probe finished", observed.probeReturned, input: true)
                check("F03 closed owner refused the actual late public operation", observed.lateRefused)
                check("F04 late call entered no new native bracket", observed.lateStarts == 0)
            }
            if mode == "library-closed" {
                check("F05 closed parent keeps its exact owned manifest bytes", (try? Data(contentsOf: manifest)) == originalManifest)
                check("F06 closed parent retains unprobed compatibility metadata", library?.model(withID: originalModel!.id)?.support == nil)
                check("C04 explicit harness preferences unchanged", preferenceEqual(beforePersistent,
                    defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:]), input: true)
            }
            let assertions = trace.gradePrimaryOnce()
            for assertion in assertions where !assertion.accepted {
                SelfTest.failed = true
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_ASSERT_FAILED: \(assertion.label)")
            }
            let first = trace.snapshot()
            SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_FIRST_PROPOSAL_TRACE mode=\(mode) starts=\(observed.starts) ends=\(observed.ends) active=\(observed.active) successes=\(observed.successes) closes=\(observed.closes) operationPending=\(observed.operationPending) checks=\(first.checks) failures=\(first.failures) invalid=\(first.invalid)")
        }
        try delegate.configureOtherLlamaTerminationFixture(
            s1: s1, embedding: quitEmbedding, library: library,
            finalReply: { proposed in
                // Veto only; the delegate ANDs this with its real drain result.
                // A false product result can never be promoted by the harness.
                guard proposed else { trace.invalidate(); return false }
                if !trace.snapshot().primaryGraded { gradeFirstProposal() }
                let observed = trace.snapshot()
                let safe = observed.active == 0 && !observed.operationPending
                guard !safe else { return true }
                guard active, ownedOperation != nil else {
                    trace.invalidate(); SelfTest.failed = true
                    return false
                }
                // The existing delegate task owns the later same-handle join.
                // This synchronous callback ONLY measures/vetoes; no new Task.
                return false
            },
            safetyDrain: {
                guard active, let exactOperation = ownedOperation else {
                    cleanupCheck("K00 actual retained operation required for veto drain", false)
                    return
                }
                // This closure executes inside SAME existing delegate shutdown Task,
                // after its first proposed verdict was measured and actually vetoed.
                await exactOperation.value
                let ended = trace.snapshot()
                cleanupCheck("K01 retained SAME actual operation Task finished", !ended.operationPending)
                cleanupCheck("K02 retained operation native brackets settled", ended.active == 0 && ended.starts == ended.ends)
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_CLEANUP_JOIN_TRACE mode=\(mode) starts=\(ended.starts) ends=\(ended.ends) active=\(ended.active) operationPending=\(ended.operationPending)")
                ownedOperation = nil
                // Delegate clears its existing task, then schedules Cocoa re-quit.
            },
            reply: { reply in
                let observed = trace.snapshot()
                guard !observed.primaryGraded else { return }
                check("C01 actual Cocoa quit returns later", reply == .terminateLater, input: true)
                if active {
                    check("C02 prior actual native success and current C bracket overlap", observed.active == 1 && observed.successes > 0, input: true)
                }
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_REPLY_TRACE mode=\(mode) starts=\(observed.starts) ends=\(observed.ends) active=\(observed.active) successes=\(observed.successes) later=\(reply == .terminateLater)")
            },
            willExit: {
                let observed = trace.snapshot()
                cleanupCheck("K03 first proposal graded exactly once before safe exit", observed.primaryGraded)
                cleanupCheck("K04 safe process exit has no pending operation/native bracket", observed.active == 0 && observed.starts == observed.ends && !observed.operationPending)
                let final = trace.snapshot()
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_EXIT_TRACE mode=\(mode) starts=\(final.starts) ends=\(final.ends) active=\(final.active) successes=\(final.successes) closes=\(final.closes) lateStarts=\(final.lateStarts) lateRefused=\(final.lateRefused) checks=\(final.checks) failures=\(final.failures) cleanupChecks=\(final.cleanupChecks) cleanupFailures=\(final.cleanupFailures) invalid=\(final.invalid)")
                if final.invalid {
                    SelfTest.failed = true
                    SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_INVALID: actual input/native overlap or cleanup unavailable")
                } else {
                    SelfTest.diagnostic(final.failures == 0 && final.cleanupFailures == 0
                        ? "OTHER_LLAMA_TERMINATION_OK: \(final.checks) primary checks; \(final.cleanupChecks) cleanup controls"
                        : "OTHER_LLAMA_TERMINATION_FAILED: \(final.failures)/\(final.checks) primary; \(final.cleanupFailures)/\(final.cleanupChecks) cleanup")
                }
            }
        )
        SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_INPUT_OK: confined copied source-pinned public GGUF; actual actors")
        let preferences = CleanupPreferences(tone: .balanced, formatsLists: false, context: .general)
        let text = String(repeating: "the synthetic team agreed to review the schedule and document the next decision ", count: 24)
        if active {
            guard ownedOperation == nil else { throw CocoaError(.fileReadNoPermission) }
            trace.operationStarted()
            ownedOperation = Task {
                if let s1 { _ = try? await s1.normalize(text, preferences: preferences) }
                if let embedding { _ = try? await embedding.embed(Array(repeating: text, count: 64), purpose: .document) }
                if mode.hasPrefix("vocab") {
                    _ = await LlamaLoadProbe.probe(modelFile)
                    _ = await LlamaLoadProbe.probe(modelFile)
                }
                trace.operationEnded()
                // The observer must see a prior success and an actual second C entry.
                // A completed operation without such quit input is INVALID, not GREEN.
                if !trace.snapshot().quitScheduled {
                    trace.invalidate()
                    SelfTest.requestTermination()
                }
            }
        } else {
            check("C09 late public caller remains uncancelled", !Task.isCancelled, input: true)
            if let s1 {
                _ = try await s1.normalize(text, preferences: preferences)
                check("C05 actual S1 resident qualification", await s1.terminationResidentForTesting == true && trace.snapshot().successes > 0, input: true)
                await s1.finishTermination()
                let starts = trace.snapshot().starts
                do { _ = try await s1.normalize(text, preferences: preferences); trace.lateResult(refused: false, starts: starts) }
                catch is CancellationError { trace.lateResult(refused: true, starts: starts) }
                catch { trace.invalidate(); trace.lateResult(refused: false, starts: starts) }
                check("F07 S1 model/context released by close", await s1.terminationResidentForTesting == false)
            } else if let embedding {
                _ = try await embedding.embed([text], purpose: .document)
                check("C06 actual embedding resident qualification", await embedding.terminationResidentForTesting == true && trace.snapshot().successes > 0, input: true)
                await embedding.finishTermination()
                let starts = trace.snapshot().starts
                do { _ = try await embedding.embed([text], purpose: .document); trace.lateResult(refused: false, starts: starts) }
                catch is CancellationError { trace.lateResult(refused: true, starts: starts) }
                catch { trace.invalidate(); trace.lateResult(refused: false, starts: starts) }
                check("F08 embedding model/context released by close", await embedding.terminationResidentForTesting == false)
            } else if let library, let model = originalModel {
                let first = await LlamaLoadProbe.probe(modelFile)
                check("C07 actual native vocab qualification", first.verdict == .opens && trace.snapshot().successes > 0, input: true)
                library.beginTermination() // Parent MUST close before backend refuses work.
                await LlamaBackend.shared.beginTermination()
                let starts = trace.snapshot().starts
                let returned = await library.refreshSupportVerdictIfNeeded(model)
                trace.lateResult(refused: returned.support == nil, starts: starts)
            } else {
                let first = await LlamaLoadProbe.probe(modelFile)
                check("C08 actual native vocab qualification", first.verdict == .opens && trace.snapshot().successes > 0, input: true)
                await LlamaBackend.shared.beginTermination()
                let starts = trace.snapshot().starts
                let result = await LlamaLoadProbe.probe(modelFile)
                trace.lateResult(refused: result.verdict != .opens, starts: starts)
            }
            SelfTest.requestTermination()
        }
        return true
    }
}

/// Bounded metadata-only brackets, immediately around SAME actual C calls.
/// No native objects, model text, vectors, pause gate, or blocked C continuation.
final class OtherLlamaTerminationTrace: @unchecked Sendable {
    struct Snapshot: Sendable {
        var active = 0; var starts = 0; var ends = 0; var successes = 0; var closes = 0
        var checks = 0; var failures = 0; var invalid = false; var quitScheduled = false
        var probeReturned = false; var lateRefused = false; var lateStarts = 0
        var operationPending = false; var primaryGraded = false
        var cleanupChecks = 0; var cleanupFailures = 0
    }
    struct Assertion: Sendable {
        let label: String; let accepted: Bool; let input: Bool
    }
    private let lock = NSLock()
    private var value = Snapshot()
    private var assertions: [Assertion] = []
    private let autoQuit: Bool
    init(autoQuit: Bool) { self.autoQuit = autoQuit }
    func nativeEntered() {
        let schedule = lock.withLock {
            value.active += 1; value.starts += 1
            guard autoQuit, value.successes > 0, !value.quitScheduled else { return false }
            value.quitScheduled = true
            return true
        }
        guard schedule else { return }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                SelfTest.diagnostic("OTHER_LLAMA_TERMINATION_QUIT_REQUEST: actual native bracket after prior success")
                NSApp.terminate(nil)
            }
        }
    }
    func nativeReturned(succeeded: Bool) {
        lock.withLock { value.active -= 1; value.ends += 1; if succeeded { value.successes += 1 } }
    }
    func ownerClosed() { lock.withLock { value.closes += 1 } }
    func enqueueAssertion(label: String, accepted: Bool, input: Bool) {
        lock.withLock {
            guard !value.primaryGraded, assertions.count < 64 else { value.invalid = true; return }
            assertions.append(Assertion(label: label, accepted: accepted, input: input))
        }
    }
    func gradePrimaryOnce() -> [Assertion] {
        lock.withLock {
            guard !value.primaryGraded else { return [] }
            value.primaryGraded = true
            let measured = assertions
            for assertion in measured {
                value.checks += 1
                if !assertion.accepted {
                    value.failures += 1
                    if assertion.input { value.invalid = true }
                }
            }
            return measured
        }
    }
    func cleanupCheck(_ accepted: Bool) {
        lock.withLock { value.cleanupChecks += 1; if !accepted { value.cleanupFailures += 1 } }
    }
    func operationStarted() { lock.withLock { value.operationPending = true } }
    func operationEnded() { lock.withLock { value.operationPending = false } }
    func invalidate() { lock.withLock { value.invalid = true } }
    func lateResult(refused: Bool, starts: Int) {
        lock.withLock { value.probeReturned = true; value.lateRefused = refused; value.lateStarts = value.starts - starts }
    }
    func snapshot() -> Snapshot { lock.withLock { value } }
}
