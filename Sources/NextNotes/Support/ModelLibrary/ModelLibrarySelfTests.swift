import Foundation

/// The three probes for the model library.
///
/// `--selftest-model-fit` is pure: a table of real models against real machines, with the
/// tier each pairing must land in. It is the only way a claim like "this will be slow" can be
/// checked without downloading twenty gigabytes and waiting.
///
/// `--selftest-hf-search` talks to huggingface.co, and says so when it cannot.
///
/// `--selftest-model-library` is pure too: the "what happens after a download finishes"
/// decision table, the built-in-removal guard, and partial-download bookkeeping — none of
/// which need a real GGUF, a real load, or a real delete to prove correct.
enum ModelLibrarySelfTests {

    // MARK: - Machines

    /// A machine the estimator is tested against. Built by hand rather than read from this
    /// Mac, because a table that changes with the hardware it runs on proves nothing.
    static func machine(
        _ name: String,
        family: AppleSiliconFamily,
        memoryGB: Int,
        freeDiskGB: Double
    ) -> HardwareProfile {
        HardwareProfile(
            chipName: name,
            modelIdentifier: "Mac15,3",
            performanceCores: 4,
            efficiencyCores: 4,
            gpuCores: 10,
            deviceTreeName: nil,
            memoryBytes: Int64(memoryGB) * 1_073_741_824,
            freeDiskBytes: Int64(freeDiskGB * 1_000_000_000),
            macOSVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
            isAppleSilicon: true,
            family: family,
            thermalState: .nominal,
            isLowPowerModeEnabled: false
        )
    }

    /// One row of the table: a model, a machine, and the verdict the estimator owes us.
    struct Case {
        let model: String
        let fileBytes: Int64
        let parameterBillions: Double?
        let machine: HardwareProfile
        let expected: ModelFitEstimator.Verdict
        let why: String
    }

    static var cases: [Case] {
        // Real file sizes, taken from the Q4_K_M build of each repo.
        let qwen4b: Int64 = 2_740_937_888
        let llama8b: Int64 = 4_920_000_000
        let qwen14b: Int64 = 9_000_000_000
        let gemma27b: Int64 = 16_500_000_000
        let llama70b: Int64 = 42_500_000_000
        let qwen06b: Int64 = 500_000_000

        let m3_16 = machine("Apple M3", family: .m3, memoryGB: 16, freeDiskGB: 60)
        let m3_16_fullDisk = machine("Apple M3", family: .m3, memoryGB: 16, freeDiskGB: 8.8)
        let m1_8 = machine("Apple M1", family: .m1, memoryGB: 8, freeDiskGB: 200)
        let m4max_128 = machine("Apple M4 Max", family: .m4Max, memoryGB: 128, freeDiskGB: 900)
        let m2ultra_192 = machine("Apple M2 Ultra", family: .m2Ultra, memoryGB: 192, freeDiskGB: 2_000)

        return [
            // The machine this app was designed for, on the model it ships with.
            Case(model: "Qwen3.5-4B Q4_K_M", fileBytes: qwen4b, parameterBillions: 4,
                 machine: m3_16, expected: .runsWell,
                 why: "the built-in model on a 16 GB M3 is the case the whole app assumes works"),

            // The user's own machine as it is today: plenty of memory, almost no disk. The
            // built-in model still fits — 2.7 GB out of 8.8 GB leaves the 4 GB reserve —
            // and telling them otherwise would be a lie in the pessimistic direction.
            Case(model: "Qwen3.5-4B Q4_K_M", fileBytes: qwen4b, parameterBillions: 4,
                 machine: m3_16_fullDisk, expected: .runsWell,
                 why: "2.7 GB out of 8.8 GB free still clears the 4 GB reserve"),

            // The same nearly-full disk, one size up: this is the disk check doing its job,
            // and the verdict must name space rather than memory.
            Case(model: "Qwen3-14B Q4_K_M", fileBytes: qwen14b, parameterBillions: 14,
                 machine: m3_16_fullDisk, expected: .notRecommended,
                 why: "9 GB will not fit in 8.8 GB free, whatever the memory says"),

            // A 70B on a 16 GB Mac is the headline case from the brief.
            Case(model: "Llama-3.3-70B Q4_K_M", fileBytes: llama70b, parameterBillions: 70,
                 machine: m3_16, expected: .notRecommended,
                 why: "42 GB of weights against about 10 GB this Mac can spare"),

            // A 14B is the boundary: it fits on disk, and does not fit in memory.
            Case(model: "Qwen3-14B Q4_K_M", fileBytes: qwen14b, parameterBillions: 14,
                 machine: m3_16, expected: .slow,
                 why: "9 GB of weights is right at the edge of what a 16 GB Mac can spare"),

            // 8B on 16 GB is the everyday upgrade and must not be discouraged.
            Case(model: "Llama-3.1-8B Q4_K_M", fileBytes: llama8b, parameterBillions: 8,
                 machine: m3_16, expected: .runsWell,
                 why: "the obvious step up from 4B has to read as a good idea"),

            // An 8 GB M1 is the machine that gets hurt by a bad recommendation.
            Case(model: "Llama-3.1-8B Q4_K_M", fileBytes: llama8b, parameterBillions: 8,
                 machine: m1_8, expected: .notRecommended,
                 why: "8 GB of unified memory leaves nothing after macOS and the app"),
            Case(model: "Qwen3-0.6B Q4_K_M", fileBytes: qwen06b, parameterBillions: 0.6,
                 machine: m1_8, expected: .runsGreat,
                 why: "a half-gigabyte model is the one thing an 8 GB M1 is comfortable with"),

            // Big machines must not be told to stay small.
            Case(model: "Qwen3-14B Q4_K_M", fileBytes: qwen14b, parameterBillions: 14,
                 machine: m4max_128, expected: .runsGreat,
                 why: "9 GB of weights at 410 GB/s is the pairing a fast Mac exists for"),
            Case(model: "Gemma-3-27B Q4_K_M", fileBytes: gemma27b, parameterBillions: 27,
                 machine: m4max_128, expected: .runsWell,
                 why: "128 GB swallows a 27B, but 16 GB of weights caps it at reading pace"),
            Case(model: "Llama-3.3-70B Q4_K_M", fileBytes: llama70b, parameterBillions: 70,
                 machine: m2ultra_192, expected: .runsWell,
                 why: "a 192 GB Ultra fits a 70B, and 800 GB/s is just enough to keep up"),
            // The same 70B on half the bandwidth: it fits, and it is not pleasant.
            Case(model: "Llama-3.3-70B Q4_K_M", fileBytes: llama70b, parameterBillions: 70,
                 machine: m4max_128, expected: .slow,
                 why: "410 GB/s across 42 GB of weights is about six tokens a second"),
        ]
    }

    // MARK: - --selftest-model-fit

    /// Fails when any pairing lands in the wrong tier, when a verdict comes back without a
    /// sentence a person could read, or when the name parser misreads a model.
    @discardableResult
    static func runModelFitSelfTest() async -> Bool {
        var failures: [String] = []

        for testCase in cases {
            let fit = ModelFitEstimator.fit(
                weightBytes: testCase.fileBytes,
                parameterBillions: testCase.parameterBillions,
                contextTokens: ModelFitEstimator.typicalContextTokens,
                hardware: testCase.machine
            )
            let line = "\(testCase.model) on \(testCase.machine.chipName) "
                + "\(testCase.machine.memoryGigabytesLabel)/\(testCase.machine.freeDiskLabel) free"
            if fit.verdict != testCase.expected {
                failures.append("\(line): got \(fit.verdict.rawValue), want \(testCase.expected.rawValue) — \(testCase.why)")
            } else {
                print("MODEL_FIT: \(line) → \(fit.verdict.title). \(fit.reason)")
            }
            if fit.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                failures.append("\(line): the verdict had no reason attached")
            }
            // Nothing in this feature may put jargon in front of a person.
            for jargon in ["quantiz", "KV cache", "tokens/s", "GGUF", "param"]
            where fit.reason.lowercased().contains(jargon.lowercased()) {
                failures.append("\(line): the reason says “\(jargon)”, which the user cannot act on")
            }
            if fit.verdict != .notRecommended, fit.speedSentence == nil {
                failures.append("\(line): a runnable model came back with nothing to say about speed")
            }
        }

        // A verdict that never says no is a verdict that says nothing.
        let tiers = Set(cases.map {
            ModelFitEstimator.fit(
                weightBytes: $0.fileBytes, parameterBillions: $0.parameterBillions,
                contextTokens: ModelFitEstimator.typicalContextTokens, hardware: $0.machine).verdict
        })
        if tiers.count < 3 {
            failures.append("the table only produced \(tiers.count) distinct tiers; the estimator is not discriminating")
        }

        failures.append(contentsOf: nameParsingFailures())
        failures.append(contentsOf: monotonicityFailures())
        failures.append(contentsOf: liveMachineFailures())
        failures.append(contentsOf: swapDecisionFailures())
        failures.append(contentsOf: await confirmedDownloadFailures())

        // Choosing a model is half the feature; the runtime has to adopt it safely.
        if await NotesModelRuntime.modelSwapSelfTest() {
            print("MODEL_FIT: switching models waits for work in flight, then swaps")
        } else {
            failures.append("the runtime either refused to switch models, or switched one "
                            + "out from under a generation that was still running")
        }

        for failure in failures { print("MODEL_FIT_WRONG: \(failure)") }
        print(failures.isEmpty ? "MODEL_FIT_OK" : "MODEL_FIT_FAILED")
        return failures.isEmpty
    }

    /// The parser that turns a repo name into a parameter count and a quantization.
    private static func nameParsingFailures() -> [String] {
        var failures: [String] = []

        let parameterCases: [(String, Double?)] = [
            ("Qwen3.5-4B-Instruct", 4),
            ("Llama-3.1-8B-Instruct-GGUF", 8),
            ("gemma-3-1b-it", 1),
            ("Qwen3-30B-A3B-Instruct-2507", 30),
            ("Mistral-7B-v0.3", 7),
            ("Llama-3.3-70B-Instruct", 70),
            ("Qwen3-0.6B", 0.6),
            ("DeepSeek-R1-Distill-Qwen-1.5B", 1.5),
            // No parameter count at all: the caller must fall back to the file size.
            ("some-model-Q4_K_M", nil),
            ("bge-m3", nil),
        ]
        for (name, expected) in parameterCases {
            let parsed = ModelFitEstimator.parameterBillions(fromName: name)
            if parsed != expected {
                let got: String = parsed.map { String($0) } ?? "nil"
                let want: String = expected.map { String($0) } ?? "nil"
                failures.append("parameterBillions(\"\(name)\") = \(got), want \(want)")
            }
        }

        let quantCases: [(String, String?)] = [
            ("Qwen3.5-4B-Q4_K_M.gguf", "Q4_K_M"),
            ("Llama-3.1-8B-Instruct-Q8_0.gguf", "Q8_0"),
            ("model-IQ4_XS.gguf", "IQ4_XS"),
            ("model-BF16.gguf", "BF16"),
            ("model.gguf", nil),
        ]
        for (name, expected) in quantCases {
            let parsed = ModelFitEstimator.quantization(fromFileName: name)
            if parsed != expected {
                failures.append("quantization(\"\(name)\") = \(parsed ?? "nil"), want \(expected ?? "nil")")
            }
        }

        // Q4_K_M has to win, or the library downloads the wrong file every time.
        let ranks = ["Q4_K_M", "Q5_K_M", "Q8_0", "Q2_K"].map(ModelFitEstimator.quantizationPreferenceRank)
        if ranks != ranks.sorted() || ranks[0] != 0 {
            failures.append("quantization preference is \(ranks); Q4_K_M must rank first")
        }

        // Chip detection is what the bandwidth table is keyed on.
        let chips: [(String, AppleSiliconFamily)] = [
            ("Apple M1", .m1), ("Apple M1 Pro", .m1Pro), ("Apple M1 Max", .m1Max),
            ("Apple M2 Ultra", .m2Ultra), ("Apple M3", .m3), ("Apple M4 Pro", .m4Pro),
            ("Apple M5 Max", .m5Max), ("Apple M9 Hyper", .unknownAppleSilicon),
        ]
        for (brand, expected) in chips {
            let parsed = AppleSiliconFamily.parse(brandString: brand, isAppleSilicon: true)
            if parsed != expected {
                failures.append("chip \"\(brand)\" parsed as \(parsed.rawValue), want \(expected.rawValue)")
            }
        }
        if AppleSiliconFamily.parse(brandString: "Intel Core i9", isAppleSilicon: false) != .intel {
            failures.append("an Intel Mac was not recognised as Intel")
        }
        // An unknown chip must be under-promised, never over-promised.
        if AppleSiliconFamily.unknownAppleSilicon.memoryBandwidthGBPerSecond
            > AppleSiliconFamily.m3.memoryBandwidthGBPerSecond {
            failures.append("the unknown-chip default is faster than a base M3; it must be conservative")
        }

        return failures
    }

    /// Properties the estimator must have whatever the numbers are.
    private static func monotonicityFailures() -> [String] {
        var failures: [String] = []
        let mac = machine("Apple M3", family: .m3, memoryGB: 16, freeDiskGB: 500)

        // A bigger file is never faster.
        var previous = Double.greatestFiniteMagnitude
        for gigabytes in stride(from: 1.0, through: 40.0, by: 3.0) {
            let rate = ModelFitEstimator.tokensPerSecond(
                weightBytes: Int64(gigabytes * 1e9), hardware: mac)
            if rate > previous {
                failures.append("a \(gigabytes) GB model was estimated faster than a smaller one")
            }
            previous = rate
        }

        // A faster machine is never slower on the same model.
        let slow = ModelFitEstimator.tokensPerSecond(weightBytes: 5_000_000_000, hardware: mac)
        let fast = ModelFitEstimator.tokensPerSecond(
            weightBytes: 5_000_000_000,
            hardware: machine("Apple M4 Max", family: .m4Max, memoryGB: 64, freeDiskGB: 500))
        if fast <= slow {
            failures.append("an M4 Max was not estimated faster than a base M3 on the same model")
        }

        // Low Power Mode and thermal throttling must lower the estimate, not be ignored.
        var throttled = mac
        throttled = HardwareProfile(
            chipName: mac.chipName, modelIdentifier: mac.modelIdentifier,
            performanceCores: mac.performanceCores, efficiencyCores: mac.efficiencyCores,
            gpuCores: mac.gpuCores, deviceTreeName: mac.deviceTreeName,
            memoryBytes: mac.memoryBytes, freeDiskBytes: mac.freeDiskBytes,
            macOSVersion: mac.macOSVersion, isAppleSilicon: true, family: mac.family,
            thermalState: .critical, isLowPowerModeEnabled: true)
        if ModelFitEstimator.tokensPerSecond(weightBytes: 5_000_000_000, hardware: throttled) >= slow {
            failures.append("Low Power Mode and a critical thermal state did not lower the speed estimate")
        }

        // More free disk never makes a verdict worse.
        let roomy = ModelFitEstimator.fit(
            weightBytes: 2_740_937_888, parameterBillions: 4,
            contextTokens: ModelFitEstimator.typicalContextTokens, hardware: mac)
        let cramped = ModelFitEstimator.fit(
            weightBytes: 2_740_937_888, parameterBillions: 4,
            contextTokens: ModelFitEstimator.typicalContextTokens,
            hardware: machine("Apple M3", family: .m3, memoryGB: 16, freeDiskGB: 5))
        if roomy.verdict == .notRecommended || cramped.verdict != .notRecommended {
            failures.append("the disk check did not separate a 500 GB volume from a 5 GB one")
        }
        if cramped.fitsOnDisk {
            failures.append("a 2.7 GB model was reported as fitting in 5 GB of free space with a 4 GB reserve")
        }

        return failures
    }

    /// Choosing a model has to reach the *next* answer.
    ///
    /// The runtime decides from the work in flight, never from whether weights happen to be
    /// resident: "loaded and idle" is the ordinary state a second after the last answer, and
    /// treating it as busy meant the following generation quietly ran on the old model and
    /// only the one after that used the new one. No GGUF is loaded here — the decision is a
    /// function of five counters, and this table is every state that matters.
    private static func swapDecisionFailures() -> [String] {
        var failures: [String] = []

        if NotesModelRuntime.swapMustWait(
            activeOperations: 0, loadInFlight: false, nativeOwner: false,
            nativeWaiters: 0, conversationLeases: 0) {
            failures.append("a model chosen while the runtime was loaded but idle would not take "
                            + "effect until after one more answer had been written by the old one")
        }

        let busy: [(String, Bool)] = [
            ("a generation was running",
             NotesModelRuntime.swapMustWait(activeOperations: 1, loadInFlight: false,
                                            nativeOwner: false, nativeWaiters: 0, conversationLeases: 0)),
            ("the weights were being loaded",
             NotesModelRuntime.swapMustWait(activeOperations: 0, loadInFlight: true,
                                            nativeOwner: false, nativeWaiters: 0, conversationLeases: 0)),
            ("the native context was owned",
             NotesModelRuntime.swapMustWait(activeOperations: 0, loadInFlight: false,
                                            nativeOwner: true, nativeWaiters: 0, conversationLeases: 0)),
            ("a request was queued behind one",
             NotesModelRuntime.swapMustWait(activeOperations: 0, loadInFlight: false,
                                            nativeOwner: false, nativeWaiters: 1, conversationLeases: 0)),
            ("a voice conversation was open",
             NotesModelRuntime.swapMustWait(activeOperations: 0, loadInFlight: false,
                                            nativeOwner: false, nativeWaiters: 0, conversationLeases: 1)),
        ]
        for (state, mustWait) in busy where !mustWait {
            failures.append("a model chosen while \(state) would have been swapped in underneath it")
        }
        return failures
    }

    /// "Download anyway" has to mean it.
    ///
    /// The app tells a person that a model is too big for their disk and then promises that
    /// nothing stops them from fetching it. Nothing may: a second, silent refusal inside the
    /// downloader made that promise false for every model over about 4 GB on a Mac like this
    /// one. Offline on purpose — the transfer is pointed at a local file, so what is proved is
    /// which error comes back, not whether the network is up.
    private static func confirmedDownloadFailures() async -> [String] {
        var failures: [String] = []

        // The verdict half: a model that will not fit on the disk still routes through the
        // confirmation sheet rather than a refusal.
        let crowded = machine("Apple M3", family: .m3, memoryGB: 16, freeDiskGB: 8.13)
        let eightB = ModelFitEstimator.fit(
            weightBytes: 4_920_000_000, parameterBillions: 8,
            contextTokens: ModelFitEstimator.typicalContextTokens, hardware: crowded)
        if !eightB.verdict.needsConfirmation {
            failures.append("an 8B on a nearly full disk skipped the confirmation sheet")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-disk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let standIn = directory.appendingPathComponent("source.bin")
        FileManager.default.createFile(atPath: standIn.path, contents: Data("a model, notionally".utf8))

        // Larger than any Mac's free space, so the reserve is certain to have an opinion.
        let enormous: Int64 = 400 * 1_000_000_000
        func attempt(confirmed: Bool) async -> Error? {
            let remote = ModelDownloader.RemoteFile(
                url: standIn,
                destination: directory.appendingPathComponent("model-\(confirmed).gguf"),
                expectedBytes: enormous,
                expectedSHA256: nil,
                bearerToken: nil,
                allowLowDiskSpace: confirmed
            )
            do {
                try await ModelDownloader.download(remote)
                return nil
            } catch {
                return error
            }
        }

        let refused = await attempt(confirmed: false)
        if !isInsufficientDisk(refused) {
            failures.append("an unconfirmed download of a 400 GB file was not stopped by the "
                            + "free-space reserve (got \(describe(refused)))")
        }
        let allowed = await attempt(confirmed: true)
        if isInsufficientDisk(allowed) {
            failures.append("a download the user confirmed was still refused for free space; "
                            + "“Download anyway” does not work")
        } else {
            print("MODEL_FIT: a confirmed download is attempted despite the free-space reserve "
                  + "(\(describe(allowed)))")
        }
        return failures
    }

    private static func isInsufficientDisk(_ error: Error?) -> Bool {
        guard let error = error as? ModelDownloadError, case .insufficientDisk = error else { return false }
        return true
    }

    private static func describe(_ error: Error?) -> String {
        guard let error else { return "no error" }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The live reader, on whatever Mac this is running on.
    ///
    /// The values cannot be asserted against constants — the point of the reader is that it
    /// works on a machine nobody anticipated — so what is checked is that every field came
    /// back at all. A profile with zero memory would send every verdict to "not
    /// recommended" and nobody would ever see a model they could run.
    private static func liveMachineFailures() -> [String] {
        var failures: [String] = []
        let mac = HardwareProfile.current()
        print("MODEL_FIT: this Mac is \(mac.plainSummary)")
        print("MODEL_FIT: \(mac.coreSummary) · \(mac.family.rawValue) "
              + "· \(Int(mac.memoryBandwidthGBPerSecond)) GB/s")

        if mac.chipName.isEmpty || mac.chipName == "Unknown processor" {
            failures.append("the processor could not be read from sysctl")
        }
        if mac.memoryBytes <= 0 {
            failures.append("hw.memsize came back as \(mac.memoryBytes)")
        }
        if mac.totalCores <= 0 {
            failures.append("no CPU cores were reported")
        }
        if mac.memoryBandwidthGBPerSecond <= 0 {
            failures.append("the bandwidth table produced \(mac.memoryBandwidthGBPerSecond) GB/s")
        }
        if mac.macOSVersion.majorVersion <= 0 {
            failures.append("the macOS version came back as \(mac.macOSLabel)")
        }
        if ModelFitEstimator.safelyUsableMemoryBytes(mac) <= 0 {
            failures.append("this Mac was judged to have no memory to spare at all")
        }
        // The built-in model is the one case the app cannot afford to be wrong about.
        let builtIn = ModelFitEstimator.fit(
            weightBytes: NotesModels.spec.expectedBytes, parameterBillions: 4,
            contextTokens: ModelFitEstimator.typicalContextTokens, hardware: mac)
        print("MODEL_FIT: the built-in model here → \(builtIn.verdict.title). \(builtIn.reason)")
        return failures
    }

    // MARK: - --selftest-hf-search

    /// Live network. Fails honestly when there is none rather than passing on an empty list.
    @discardableResult
    static func runSearchSelfTest() async -> Bool {
        var failures: [String] = []

        do {
            let page = try await HuggingFaceClient.search(sort: .downloads, limit: 20)
            if page.models.isEmpty {
                failures.append("the most-downloaded GGUF search returned nothing")
            }
            if page.nextPageURL == nil {
                failures.append("the Hub did not send a cursor for the next page; pagination is broken")
            }
            for model in page.models.prefix(5) {
                print("HF_SEARCH: \(model.id) · \(model.popularitySentence) · \(model.licenseSentence)")
            }
            // The list is offered as "a brain for your assistant". Speech, voice and
            // embedding models also ship as GGUF and once topped it.
            let notChat = ["asr", "parakeet", "whisper", "tts", "embed", "audio.cpp"]
            for model in page.models {
                let id = model.id.lowercased()
                if let word = notChat.first(where: { id.contains($0) }) {
                    failures.append("\(model.id) is not a chat model (\(word)) but was listed")
                }
            }
            if !page.models.contains(where: { $0.parameterBillions != nil }) {
                failures.append("no result had a readable parameter count; the name parser is broken")
            }

            // Reading one repository: sizes and hashes are what a download depends on.
            let query = try await HuggingFaceClient.search(query: "Qwen3 GGUF", sort: .downloads, limit: 10)
            guard let candidate = query.models.first(where: { !$0.isGated }) else {
                failures.append("searching for a named model returned nothing usable")
                return report(failures)
            }
            let details = try await HuggingFaceClient.details(repoID: candidate.id)
            guard let file = details.recommendedFile else {
                failures.append("\(candidate.id) offered no GGUF this app would pick")
                return report(failures)
            }
            print("HF_SEARCH: \(candidate.id) → \(file.fileName) "
                  + "\(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))")
            if file.sizeBytes <= 0 {
                failures.append("\(file.fileName) came back with no size; the fit estimate would be a guess")
            }
            if file.sha256 == nil {
                failures.append("\(file.fileName) came back with no SHA-256; the download could not be verified")
            }
            if details.parameterBillions == nil {
                failures.append("\(candidate.id) reported no parameter count in its GGUF metadata")
            }
            // No model is downloaded here on purpose — this Mac has under 10 GB free.
            print("HF_SEARCH: no model fetched (disk is nearly full by design)")
            failures.append(contentsOf: await resumeFailures())
        } catch let error as HuggingFaceError {
            failures.append(error.errorDescription ?? "Hugging Face was unreachable")
        } catch {
            failures.append(error.localizedDescription)
        }

        return report(failures)
    }

    /// A model is gigabytes; the resume logic is the same code whatever the size.
    ///
    /// So it is exercised on a 3.9 MB LFS file in the same repositories the library browses —
    /// and it is exercised the way it actually happens to people: a transfer is *stopped part
    /// way through*, which is the case an earlier version of this test faked by truncating a
    /// finished file. Faking it hid a real bug, because the bytes were only committed to disk
    /// when a whole HTTP leg finished, so a genuine interruption kept nothing at all.
    ///
    /// What is checked: the partial file holds what arrived before the stop, the second
    /// attempt picks up from that offset rather than starting over, and the finished file
    /// matches the SHA-256 the Hub publishes. Everything lands in a temporary directory and
    /// is removed afterwards.
    private static func resumeFailures() async -> [String] {
        var failures: [String] = []
        let repoID = "unsloth/Qwen3-4B-Instruct-2507-GGUF"
        let path = "imatrix_unsloth.gguf_file"

        let listing: [HuggingFaceRepoFile]
        do {
            listing = try await HuggingFaceClient.files(repoID: repoID)
        } catch {
            return ["could not list \(repoID) to test resuming: \(error.localizedDescription)"]
        }
        guard let small = listing.first(where: { $0.path == path }),
              small.sizeBytes > 0, let expectedHash = small.sha256 else {
            // The probe file is gone. Say so rather than quietly skipping the check.
            return ["\(repoID) no longer publishes \(path), so resuming was never exercised"]
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = ModelDownloader.RemoteFile(
            url: HuggingFaceClient.downloadURL(repoID: repoID, path: path),
            destination: directory.appendingPathComponent("probe.bin"),
            expectedBytes: small.sizeBytes,
            expectedSHA256: expectedHash,
            bearerToken: nil
        )

        // Stop the transfer once a third of it has arrived. Three attempts, because a small
        // file on a fast line can finish between the decision to stop and the stop landing —
        // and "it finished" must not be allowed to read as "interruption works".
        var stoppedAt: Int64 = 0
        for attempt in 1...3 where stoppedAt == 0 {
            ModelDownloader.discardPartial(remote)
            try? FileManager.default.removeItem(at: remote.destination)

            let interrupter = DownloadInterrupter()
            let threshold = max(1, small.sizeBytes / 3)
            let transfer = Task {
                try await ModelDownloader.download(remote) { progress in
                    guard progress.completedBytes >= threshold else { return }
                    Task { await interrupter.stop() }
                }
            }
            await interrupter.hold(transfer)
            let outcome = await transfer.result

            let partial = ModelDownloader.fileSize(at: remote.partialURL)
            if partial > 0, partial < small.sizeBytes {
                stoppedAt = partial
            } else if ModelDownloader.fileSize(at: remote.destination) == small.sizeBytes {
                print("HF_SEARCH: attempt \(attempt) finished before the stop landed; trying again")
            } else {
                var why = "nothing was kept, so \u{201C}resume\u{201D} would start from zero"
                if case .failure(let error) = outcome, !(error is CancellationError) {
                    why = "the transfer itself failed: \(error.localizedDescription)"
                }
                failures.append("stopping a transfer after \(threshold) of \(small.sizeBytes) "
                                + "bytes left \(partial) bytes in the partial file — \(why)")
                return failures
            }
        }

        guard stoppedAt > 0 else {
            return failures + ["a transfer of \(path) could never be stopped part way, so "
                               + "resuming was never exercised"]
        }
        print("HF_SEARCH: stopped after \(stoppedAt) of \(small.sizeBytes) bytes, and the "
              + "partial file kept every one of them")

        do {
            // Resuming must continue from the offset on disk. A first progress report below
            // what was already there means the server sent the whole file again and the
            // Range request was not honoured — a working download, but not a resumed one.
            let firstReport = FirstProgressReport()
            try await ModelDownloader.download(remote) { progress in
                firstReport.record(progress.completedBytes)
            }
            if let first = firstReport.value, first < stoppedAt {
                failures.append("resuming restarted from the beginning: the first \(first) bytes "
                                + "were fetched again although \(stoppedAt) were already on disk")
            }
            let size = ModelDownloader.fileSize(at: remote.destination)
            if size != small.sizeBytes {
                failures.append("the resumed download produced \(size) bytes, want \(small.sizeBytes)")
            }
            if try ModelDownloader.sha256(of: remote.destination) != expectedHash {
                failures.append("the resumed file did not match the hash the Hub publishes")
            } else {
                print("HF_SEARCH: resumed from \(stoppedAt) bytes and the finished file matched "
                      + "the Hub's hash")
            }
        } catch {
            let manager = FileManager.default
            failures.append("resuming a download failed: \(error.localizedDescription) "
                            + "[part=\(manager.fileExists(atPath: remote.partialURL.path)) "
                            + "final=\(manager.fileExists(atPath: remote.destination.path)) "
                            + "offset=\(remote.resumeOffset)]")
        }
        return failures
    }

    /// Stops the transfer the moment enough of it has arrived, whichever order the two
    /// happen in: the progress callback can fire before the task handle is in hand.
    private actor DownloadInterrupter {
        private var transfer: Task<Void, Error>?
        private var stopRequested = false

        func hold(_ transfer: Task<Void, Error>) {
            if stopRequested {
                transfer.cancel()
            } else {
                self.transfer = transfer
            }
        }

        func stop() {
            stopRequested = true
            transfer?.cancel()
        }
    }

    /// The first byte count a download reported, recorded from the session's delegate queue.
    private final class FirstProgressReport: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Int64?

        func record(_ bytes: Int64) {
            lock.lock()
            if first == nil { first = bytes }
            lock.unlock()
        }

        var value: Int64? {
            lock.lock()
            defer { lock.unlock() }
            return first
        }
    }

    private static func report(_ failures: [String]) -> Bool {
        for failure in failures { print("HF_SEARCH_WRONG: \(failure)") }
        print(failures.isEmpty ? "HF_SEARCH_OK" : "HF_SEARCH_FAILED")
        return failures.isEmpty
    }

    // MARK: - --selftest-model-library

    /// No downloads, no loads, no real deletes — every case here is a decision table or a
    /// filesystem listing over files this test writes and removes itself. `@MainActor`
    /// because `ModelLibraryStore` and `InstalledModelLibrary` are.
    @MainActor
    @discardableResult
    static func runModelLibrarySelfTest() -> Bool {
        var failures: [String] = []
        failures.append(contentsOf: postDownloadDecisionFailures())
        failures.append(contentsOf: builtInRemovalFailures())
        failures.append(contentsOf: partialDownloadFailures())
        for failure in failures { print("MODEL_LIBRARY_WRONG: \(failure)") }
        print(failures.isEmpty ? "MODEL_LIBRARY_OK" : "MODEL_LIBRARY_FAILED")
        return failures.isEmpty
    }

    /// "The default policy switches and keeps; delete-old deletes only after a simulated
    /// successful load and keeps on simulated failure" — the coordinator's own words for what
    /// this table has to prove.
    private static func postDownloadDecisionFailures() -> [String] {
        var failures: [String] = []
        let old = "old/brain.gguf"
        let new = "new/brain.gguf"

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let keepSuccess = ModelLibraryStore.decide(
            policy: .switchKeepOld, previousActiveID: old, newModelID: new, loadSucceeded: true)
        check("switchKeepOld on success switched to the new model",
              keepSuccess.activeID == new)
        check("switchKeepOld deleted something although it never should",
              keepSuccess.deleteID == nil)

        let keepFailure = ModelLibraryStore.decide(
            policy: .switchKeepOld, previousActiveID: old, newModelID: new, loadSucceeded: false)
        check("switchKeepOld on a failed load did not switch back to the old model",
              keepFailure.activeID == old)
        check("switchKeepOld deleted the old model after a failed load",
              keepFailure.deleteID == nil)

        let deleteSuccess = ModelLibraryStore.decide(
            policy: .switchDeleteOld, previousActiveID: old, newModelID: new, loadSucceeded: true)
        check("switchDeleteOld on success switched to the new model",
              deleteSuccess.activeID == new)
        check("switchDeleteOld on success did not mark the old model for deletion",
              deleteSuccess.deleteID == old)

        let deleteFailure = ModelLibraryStore.decide(
            policy: .switchDeleteOld, previousActiveID: old, newModelID: new, loadSucceeded: false)
        check("switchDeleteOld on a failed load did not switch back to the old model",
              deleteFailure.activeID == old)
        check("switchDeleteOld deleted the old model although the new one never loaded — "
              + "this is the one case that must never happen",
              deleteFailure.deleteID == nil)

        let downloadOnly = ModelLibraryStore.decide(
            policy: .downloadOnly, previousActiveID: old, newModelID: new, loadSucceeded: true)
        check("downloadOnly switched models on its own",
              downloadOnly.activeID == old)
        check("downloadOnly deleted anything on its own",
              downloadOnly.deleteID == nil)

        // A download that lands back on the model already active (re-fetching the same file)
        // must never propose deleting the thing it just switched to.
        let sameModel = ModelLibraryStore.decide(
            policy: .switchDeleteOld, previousActiveID: new, newModelID: new, loadSucceeded: true)
        check("re-downloading the active model proposed deleting it",
              sameModel.deleteID == nil)

        return failures
    }

    /// "Built-in removable only when another brain is installed and in use."
    ///
    /// Pure on purpose: `InstalledModelLibrary` reads and writes `UserDefaults.standard`
    /// under fixed keys, with no way to point a second instance at a scratch suite — so a
    /// self-test that stood one up would read and silently overwrite the *real* person's
    /// saved model choice the moment `refresh()` ran. `canRemoveBuiltIn` is `nonisolated`
    /// and takes no store, precisely so every case of the rule can be driven here instead.
    /// `InstalledModelLibrary.canRemove(_:)` itself is a one-line delegation to it for a
    /// non-built-in model (`guard model.isBuiltIn else { return true }`), reviewed by eye
    /// rather than re-proven at runtime, to avoid that shared-state trap.
    private static func builtInRemovalFailures() -> [String] {
        var failures: [String] = []
        let builtIn = InstalledModelLibrary.builtInID
        let other = "unsloth/Qwen3-4B-GGUF/model.gguf"

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check("the built-in model could be removed while it was itself the one in use",
              !InstalledModelLibrary.canRemoveBuiltIn(activeID: builtIn, installedIDs: [builtIn]))
        check("the built-in model could be removed while nothing else was installed",
              !InstalledModelLibrary.canRemoveBuiltIn(activeID: builtIn, installedIDs: [builtIn, other]))
        check("the built-in model could not be removed once a different brain was active",
              InstalledModelLibrary.canRemoveBuiltIn(activeID: other, installedIDs: [builtIn, other]))
        check("the built-in model could be removed although the \u{201c}active\u{201d} brain "
              + "was not actually installed",
              !InstalledModelLibrary.canRemoveBuiltIn(activeID: other, installedIDs: [builtIn]))

        return failures
    }

    /// "Partials listed" — a `.part` file dropped in a scratch directory has to be found,
    /// sized correctly, and named something a person could recognise, without touching the
    /// real Models folder or downloading a single byte. `@MainActor`: `ModelLibraryStore` is.
    @MainActor
    private static func partialDownloadFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-partials-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let big = directory.appendingPathComponent("unsloth--big-model.gguf.part")
        let small = directory.appendingPathComponent("unsloth--small-model.gguf.part")
        let finished = directory.appendingPathComponent("unsloth--finished-model.gguf")
        let empty = directory.appendingPathComponent("unsloth--empty.gguf.part")
        FileManager.default.createFile(atPath: big.path, contents: Data(repeating: 0, count: 5_000))
        FileManager.default.createFile(atPath: small.path, contents: Data(repeating: 0, count: 1_000))
        FileManager.default.createFile(atPath: finished.path, contents: Data(repeating: 0, count: 9_000))
        FileManager.default.createFile(atPath: empty.path, contents: Data())

        let store = ModelLibraryStore.shared
        let partials = store.partialDownloads(in: directory)

        check("a finished (non-.part) file was listed as a partial download",
              !partials.contains { $0.fileName == finished.lastPathComponent })
        check("an empty .part file (nothing arrived yet) was listed as reclaimable space",
              !partials.contains { $0.fileName == empty.lastPathComponent })
        check("the two real partial files were not both found",
              partials.count == 2)
        check("partial downloads were not sorted largest first",
              partials.first?.fileName == big.lastPathComponent)
        check("a partial's display name did not read as plain text",
              partials.first?.displayName == "unsloth / big-model.gguf")
        check("a partial's byte count did not match the file on disk",
              partials.first?.bytes == 5_000)

        store.discardPartial(PartialModelDownload(fileName: small.lastPathComponent, bytes: 1_000), in: directory)
        check("discarding a partial download left its file behind",
              !FileManager.default.fileExists(atPath: small.path))
        check("discarding one partial download removed the other",
              FileManager.default.fileExists(atPath: big.path))

        return failures
    }
}
