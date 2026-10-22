import Foundation
import Darwin

@MainActor enum ASRSettingsSelfTest {
    static func runStandalone() -> Never {
        Task {
            let failures = await run()
            for failure in failures { print("ASR_SETTINGS_WRONG: \(failure)") }
            print(failures.isEmpty ? "ASR_SETTINGS_OK" : "ASR_SETTINGS_FAILED")
            exit(failures.isEmpty ? 0 : 1)
        }
        RunLoop.main.run(); exit(1)
    }
    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let suite = "nextnotes.asr-settings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(Settings.initialSpeechChoice(from: defaults) == .automatic, "new selection is not automatic")
        check(Settings.initialDictationLanguage(from: defaults) == .multi, "new language is not Multi")
        defaults.set("parakeet", forKey: "engine")
        check(Settings.initialSpeechChoice(from: defaults) == .parakeet, "existing manual selection lost")
        defaults.set("apple", forKey: "engine")
        check(Settings.initialSpeechChoice(from: defaults) == .apple, "existing Apple selection lost")
        check(ASRModelCatalog.models.count == 8, "eight measured models missing")
        for language in DictationLanguage.allCases {
            let engine = engineForSetting(.automatic, language: language) as? ParakeetEngine
            check(engine?.modelChoice == language.recommendedModel, "actual factory does not use language default")
            for model in ASRModelCatalog.models {
                let expected = model.choice == .phonon && language == .multi ? .voz : model.choice
                let actual = engineForSetting(model.choice, language: language) as? ParakeetEngine
                check(actual?.modelChoice == expected, "factory/model mismatch \(model.choice)")
                let cold = ASRModelCatalog.readyChoice(model.choice, language: language, readyModel: nil)
                check(cold == (model.choice == .parakeet ? .parakeet : .apple), "cold model blocks speech instead of using Apple")
                let warm = ASRModelCatalog.readyChoice(model.choice, language: language, readyModel: expected)
                check(warm == expected, "warm model does not replace temporary Apple")
                check(engineForSetting(cold, language: language) is AppleSpeechEngine || model.choice == .parakeet,
                      "actual cold factory failed to select Apple")
                check(model.bytes > 0 && model.english.wordAccuracy <= 100, "invalid measured values")
                if model.choice != .parakeet {
                    check(!ASRArtifacts.files(model.choice).isEmpty, "missing download specification")
                    for spec in ASRArtifacts.files(model.choice) {
                        check(spec.expectedSHA256?.count == 64 && spec.expectedBytes > 0, "unpinned model file")
                        check(!spec.fileName.hasPrefix("/") && !spec.fileName.split(separator: "/").contains(".."), "unsafe artifact path")
                    }
                }
            }
        }
        // Actual store producer: a cancelled source that has not joined still
        // owns preparation; a different model cannot begin beside it.
        let gate = PreparationGate()
        let store = ASRModelStore(preparationOverride: { choice in await gate.prepare(choice) })
        let first = Task { try await store.ready(.phonon) }
        await gate.waitForEntry()
        do { try await store.ready(.voz); failures.append("second model admitted during first download") }
        catch ASRModelError.busy { } catch { failures.append("wrong busy failure") }
        store.cancel()
        check(store.preparing == .phonon, "cancel released ownership before source joined")
        await gate.finish()
        _ = await first.result
        check(store.preparing == nil, "joined source retained preparation ownership")
        do { try await store.ready(.voz) } catch { failures.append("successor failed after join") }
        let calls = await gate.calls
        check(calls == [.phonon, .voz], "download source order changed or overlapped")
        return failures
    }
    private actor PreparationGate {
        var calls: [SpeechEngineChoice] = []
        var source: CheckedContinuation<Void, Never>?
        var entry: CheckedContinuation<Void, Never>?
        func prepare(_ choice: SpeechEngineChoice) async {
            calls.append(choice)
            if calls.count > 1 { return }
            await withCheckedContinuation { continuation in
                source = continuation
                entry?.resume(); entry = nil
            }
        }
        func waitForEntry() async {
            if source != nil { return }
            await withCheckedContinuation { entry = $0 }
        }
        func finish() { source?.resume(); source = nil }
    }
}
