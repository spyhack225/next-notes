import AppKit
import Foundation

/// Actual closed-runtime trial result and caller admission through the native quit path.
@MainActor
enum NativeModelTrialCallerSelfTest {
    static func arm(mode: String, modelFile: URL, delegate: AppDelegate) async throws -> Bool {
        guard NativeOtherLlamaQuitSelfTest.isTrialParentCase,
              ["trial-parent-closed", "trial-parent-return"].contains(mode) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let manifest = modelFile.deletingLastPathComponent().appendingPathComponent("library.json")
        guard !FileManager.default.fileExists(atPath: manifest.path) else { throw CocoaError(.fileWriteFileExists) }
        let model = InstalledLocalModel(id: "synthetic-public-trial-parent", displayName: "Synthetic public trial parent",
            fileURL: modelFile, parameterBillions: nil, quantization: nil,
            bytes: NotesModels.spec.expectedBytes, isBuiltIn: false)
        let originalBytes = try JSONEncoder().encode([model])
        try originalBytes.write(to: manifest, options: .atomic)
        let defaults = SelfTestHarnessDefaults.shared
        let library = InstalledModelLibrary(manifestURL: manifest, defaults: defaults, runtimeAdopter: nil,
            isolatesBuiltInForTerminationTesting: true)
        let hardware = HardwareProfile(chipName: "Synthetic Apple", modelIdentifier: "SyntheticMac",
            performanceCores: 4, efficiencyCores: 4, gpuCores: nil, deviceTreeName: nil,
            memoryBytes: 16 * 1_073_741_824, freeDiskBytes: 64 * 1_073_741_824,
            macOSVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            isAppleSilicon: true, family: .unknownAppleSilicon, thermalState: .nominal, isLowPowerModeEnabled: false)
        let store = ModelLibraryStore(library: library, hardwareForTesting: hardware)
        let beforePersistent = defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:]
        let beforeActive = library.activeAgentModelID
        let beforePolicy = store.postDownloadPolicy
        let trace = OtherLlamaTerminationTrace(autoQuit: false)
        var checks = 0; var failures = 0; var invalid = false
        var returned = 0; var actualResult: ModelTrialResult?
        var firstProposal = false
        func check(_ label: String, _ accepted: Bool, input: Bool = true) {
            checks += 1
            if !accepted {
                failures += 1; SelfTest.failed = true
                if input { invalid = true }
                SelfTest.diagnostic("MODEL_TRIAL_CALLER_ASSERT_FAILED: \(label)")
            }
        }
        defer { store.terminationTrialReturnedForTesting = nil }
        check("C01 exact copied model row starts untried", library.model(withID: model.id)?.lastTrial == nil)
        check("C02 explicit confined library fixture admission", library.permitsTerminationHardwareFixture)
        check("C03 value-only hardware retained without default resolution", store.hardware == hardware)
        check("C04 no synthetic trial provider", store.verifyForTesting == nil)
        try await LlamaBackend.shared.configureProbeTerminationFixture(trace: trace)
        let qualified = await LlamaLoadProbe.probe(modelFile)
        let firstNative = trace.snapshot()
        check("C05 real public vocabulary qualification", qualified.verdict == .opens && firstNative.successes == 1)
        check("C06 actual vocabulary bracket settled", firstNative.starts == 1 && firstNative.ends == 1 && firstNative.active == 0)
        let runtime = NotesModelRuntime.shared
        await runtime.beginTermination()
        check("C07 actual Notes owner closes and drains before caller", await runtime.finishTermination())
        store.terminationTrialReturnedForTesting = { result in
            returned += 1; actualResult = result
            if mode == "trial-parent-return" { _ = store.beginTermination() }
        }
        if mode == "trial-parent-closed" {
            check("C08 closed parent has no mapped download work", store.beginTermination().isEmpty)
        } else {
            check("C08 exact post-real-return observer is installed", store.terminationTrialReturnedForTesting != nil)
        }
        check("C09 caller is not cancelled", !Task.isCancelled)
        let notesWeightLoadsBefore = LlamaLoadProbe.fullWeightLoadCount()
        await store.checkModel(model)
        store.terminationTrialReturnedForTesting = nil
        check("C10 real-return provenance and closed-entry allowance", mode == "trial-parent-return"
            ? returned == 1 && actualResult == .cannotOpen("busy")
            : returned == 0 || (returned == 1 && actualResult == .cannotOpen("busy")))
        let afterNative = trace.snapshot()
        check("C11 closed runtime trial starts no full-weight load or observed vocabulary bracket",
            LlamaLoadProbe.fullWeightLoadCount() == notesWeightLoadsBefore
            && afterNative.starts == firstNative.starts && afterNative.ends == firstNative.ends && afterNative.active == 0)
        check("C12 same source file and support descriptor retained", library.model(withID: model.id)?.fileURL == modelFile
            && library.model(withID: model.id)?.support == nil)
        check("F01 closed caller preserves exact trial metadata", library.model(withID: model.id)?.lastTrial == nil, input: false)
        check("F02 closed caller preserves exact manifest bytes", (try? Data(contentsOf: manifest)) == originalBytes, input: false)
        check("C13 library selection retained", library.activeAgentModelID == beforeActive)
        check("C14 explicit policy retained", store.postDownloadPolicy == beforePolicy)
        check("C15 harness preferences retained", NSDictionary(dictionary: beforePersistent).isEqual(to:
            defaults.persistentDomain(forName: SelfTestHarnessDefaults.suiteName) ?? [:]))
        check("C16 no follow-up download or access UI", store.downloads.isEmpty && store.pendingConfirmation == nil && store.accessRequest == nil)
        SelfTest.diagnostic("MODEL_TRIAL_CALLER_TRACE mode=\(mode) returned=\(returned) actualBusy=\(actualResult == .cannotOpen("busy")) notesWeightLoadsBefore=\(notesWeightLoadsBefore) notesWeightLoadsAfter=\(LlamaLoadProbe.fullWeightLoadCount()) nativeStarts=\(afterNative.starts) nativeEnds=\(afterNative.ends) nativeActive=\(afterNative.active) checks=\(checks) failures=\(failures) invalid=\(invalid)")
        let emptyEmbedding = EmbeddingRuntime(modelURL: modelFile, displayName: "Empty isolated trial owner",
            tag: "empty-isolated-trial-parent", gpuLayers: 0, notesModelBusy: { false }, mayLoad: { _ in true })
        try delegate.configureOtherLlamaTerminationFixture(s1: nil, embedding: emptyEmbedding, library: library,
            finalReply: { proposed in
                guard !firstProposal else { invalid = true; SelfTest.failed = true; return false }
                firstProposal = true
                return proposed // Never promote a false product drain.
            }, reply: { reply in
                check("C17 actual Cocoa quit returns later", reply == .terminateLater)
            }, willExit: {
                check("C18 first positive proposal observed", firstProposal)
                SelfTest.diagnostic(invalid ? "MODEL_TRIAL_CALLER_INVALID: \(failures)/\(checks)"
                    : failures == 0 ? "MODEL_TRIAL_CALLER_OK: \(checks) checks"
                    : "MODEL_TRIAL_CALLER_FAILED: \(failures)/\(checks)")
            })
        SelfTest.requestTermination()
        return true
    }
}
