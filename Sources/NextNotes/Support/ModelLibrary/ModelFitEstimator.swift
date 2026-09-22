import Foundation

/// How a model will behave on a particular Mac, in language a person can act on.
///
/// Pure arithmetic on purpose: everything it needs arrives as a value, nothing it returns
/// touches the network or the disk, and `--selftest-model-fit` runs a table of known models
/// against known machines through it. That is the only way a claim like "this will be slow"
/// can be checked before a user has to find out by waiting.
enum ModelFitEstimator {

    // MARK: - What the app itself keeps resident

    /// Memory the rest of Next Notes is holding while a language model is loaded.
    ///
    /// Parakeet (~470 MB of Core ML), S1-mini (484 MB of GGUF), the wake-phrase spotter
    /// (~51 MB) and, on an indexing pass, an embedding model (up to 278 MB) are all resident
    /// alongside the writer. `ModelResidencyPolicy` guarantees the embedder and the notes
    /// model are never loaded together, so this is the sum of the ones that genuinely
    /// overlap plus headroom for the app's own UI and audio buffers.
    static let appResidentBytes: Int64 = 1_500_000_000

    /// Memory left to macOS, the window server, and whatever else the person has open.
    ///
    /// Thirty per cent with a 3 GB floor. A Mac where the language model has taken
    /// everything else is a Mac that beachballs, and the user blames the app that is
    /// obviously running rather than the model file they chose three screens ago.
    static func systemReserveBytes(totalMemory: Int64) -> Int64 {
        max(3_000_000_000, Int64(Double(totalMemory) * 0.30))
    }

    /// What a model may use without making the machine miserable.
    static func safelyUsableMemoryBytes(_ hardware: HardwareProfile) -> Int64 {
        max(0, hardware.memoryBytes - systemReserveBytes(totalMemory: hardware.memoryBytes) - appResidentBytes)
    }

    /// Free space a download must leave behind, matching `ModelDownloader`'s own reserve.
    static let diskReserveBytes = ModelDownloader.minimumFreeBytesAfterDownload

    /// The context length a verdict is judged at.
    ///
    /// Not `NotesModelRuntime.maxContextTokens`: that 32K ceiling is reserved only when a
    /// two-hour transcript is actually in the prompt, because the runtime builds its context
    /// to fit the work in hand and rebuilds it when the next prompt does not. Judging every
    /// model against the worst case would mark models "not recommended" that are fine for
    /// everything except the longest meeting anyone will ever record.
    static let typicalContextTokens = 8_192

    // MARK: - Memory

    /// Bytes of key/value cache one token of context costs, at 16-bit cache precision.
    ///
    /// Every current open-weight text model uses grouped-query attention, which fixes the
    /// number of cached heads at eight or fewer however large the model gets — so the cache
    /// grows with the layer count, roughly as the square root of the parameter count rather
    /// than linearly. Calibrated against Llama-3-8B (128 KB/token measured), Qwen3-14B
    /// (160 KB) and Llama-3-70B (320 KB).
    static func kvCacheBytesPerToken(parameterBillions: Double) -> Double {
        let billions = max(0.1, parameterBillions)
        return max(49_152, 131_072 * (billions / 8).squareRoot())
    }

    /// Compute buffers, the Metal command allocations, and the slack a real process needs on
    /// top of its weights. Flat plus a small share of the weights, which is how llama.cpp's
    /// own buffers actually scale.
    static func overheadBytes(weightBytes: Int64) -> Int64 {
        600_000_000 + Int64(Double(weightBytes) * 0.05)
    }

    /// Total resident memory a model will want: the weight file, the cache for the context
    /// it is given, and the runtime's own buffers.
    static func residentMemoryBytes(
        weightBytes: Int64,
        parameterBillions: Double?,
        contextTokens: Int
    ) -> Int64 {
        // A model with no stated parameter count is sized from its file instead. Q4 lands
        // near 4.7 bits per weight once the embedding and output tensors are counted, so a
        // 2.74 GB file is about 4.6 B parameters — close enough for a cache estimate.
        let billions = parameterBillions ?? (Double(weightBytes) * 8 / 4.7 / 1e9)
        let cache = kvCacheBytesPerToken(parameterBillions: billions) * Double(max(0, contextTokens))
        return weightBytes + Int64(cache) + overheadBytes(weightBytes: weightBytes)
    }

    // MARK: - Speed

    /// How much of peak memory bandwidth llama.cpp actually reaches while generating.
    ///
    /// Decoding one token reads the whole weight set out of memory once, so the ceiling is
    /// bandwidth ÷ weight bytes — but a real run never reaches the ceiling: attention,
    /// sampling and the dispatch overhead between kernels all cost time that moves no
    /// weights. Sixty-five per cent is what Metal builds measure across chips.
    static let bandwidthRealismFactor = 0.65

    /// Tokens per second this model should generate on this Mac.
    ///
    /// Thermal throttling and Low Power Mode are applied last, because they are states the
    /// user can change and the number should follow the machine as it is right now.
    static func tokensPerSecond(weightBytes: Int64, hardware: HardwareProfile) -> Double {
        guard weightBytes > 0 else { return 0 }
        let bytesPerSecond = hardware.memoryBandwidthGBPerSecond * 1e9 * bandwidthRealismFactor
        var rate = bytesPerSecond / Double(weightBytes)

        if hardware.isLowPowerModeEnabled { rate *= 0.6 }
        switch hardware.thermalState {
        case .serious: rate *= 0.7
        case .critical: rate *= 0.5
        default: break
        }
        // A model that does not fit in memory is not merely slower, it is swapping: the
        // weights are read from the SSD every token instead of from RAM.
        return rate
    }

    // MARK: - Verdict

    enum Verdict: String, Sendable, Equatable, CaseIterable {
        case runsGreat
        case runsWell
        case slow
        case notRecommended

        var title: String {
            switch self {
            case .runsGreat: "Runs great"
            case .runsWell: "Runs well"
            case .slow: "Will be slow"
            case .notRecommended: "Not recommended on this Mac"
            }
        }

        /// SF Symbol for the badge beside the title.
        var symbolName: String {
            switch self {
            case .runsGreat: "checkmark.circle.fill"
            case .runsWell: "checkmark.circle"
            case .slow: "tortoise.fill"
            case .notRecommended: "exclamationmark.triangle.fill"
            }
        }

        /// True when the app should ask "download anyway?" first. It never refuses.
        var needsConfirmation: Bool {
            self == .slow || self == .notRecommended
        }
    }

    /// Everything the UI needs about one model on one Mac.
    struct Fit: Sendable, Equatable {
        let verdict: Verdict
        /// One sentence, plain language, no jargon. Shown under the verdict badge.
        let reason: String
        /// A second plain sentence about speed, or nil when the model cannot run at all.
        let speedSentence: String?
        let residentMemoryBytes: Int64
        let safelyUsableMemoryBytes: Int64
        let tokensPerSecond: Double
        let fitsOnDisk: Bool
        let downloadBytes: Int64
        let freeDiskBytes: Int64

        /// The line behind the "Technical details" disclosure. This is the only place in the
        /// feature where the words "GB of memory" and "tokens" are allowed together.
        var technicalDetail: String {
            let needed = ModelFitEstimator.gigabytes(residentMemoryBytes)
            let spare = ModelFitEstimator.gigabytes(safelyUsableMemoryBytes)
            let rate = tokensPerSecond >= 10
                ? String(Int(tokensPerSecond.rounded()))
                : String(format: "%.1f", tokensPerSecond)
            return "About \(needed) GB of memory while running, of \(spare) GB this Mac can spare. "
                + "Roughly \(rate) tokens a second. Download is "
                + ByteCountFormatter.string(fromByteCount: downloadBytes, countStyle: .file) + "."
        }
    }

    /// The judgement. Order matters: disk before memory before speed, because a model that
    /// will not fit on the disk has no memory verdict worth reading.
    static func fit(
        weightBytes: Int64,
        parameterBillions: Double?,
        contextTokens: Int,
        hardware: HardwareProfile
    ) -> Fit {
        let resident = residentMemoryBytes(
            weightBytes: weightBytes, parameterBillions: parameterBillions, contextTokens: contextTokens)
        let usable = safelyUsableMemoryBytes(hardware)
        let rate = tokensPerSecond(weightBytes: weightBytes, hardware: hardware)
        let fitsDisk = hardware.freeDiskBytes - weightBytes >= diskReserveBytes

        func make(_ verdict: Verdict, _ reason: String, speed: String?) -> Fit {
            Fit(
                verdict: verdict,
                reason: reason,
                speedSentence: speed,
                residentMemoryBytes: resident,
                safelyUsableMemoryBytes: usable,
                tokensPerSecond: rate,
                fitsOnDisk: fitsDisk,
                downloadBytes: weightBytes,
                freeDiskBytes: hardware.freeDiskBytes
            )
        }

        if !fitsDisk {
            let needed = ByteCountFormatter.string(fromByteCount: weightBytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: hardware.freeDiskBytes, countStyle: .file)
            return make(
                .notRecommended,
                "Needs \(needed) of space; you have \(free) free.",
                speed: nil
            )
        }

        let memorySentence = "Needs about \(gigabytes(resident)) GB of memory; "
            + "this Mac can spare about \(gigabytes(usable)) GB."

        if resident > Int64(Double(usable) * 1.15) {
            return make(.notRecommended, memorySentence, speed: nil)
        }
        if resident > usable {
            return make(
                .slow,
                memorySentence + " It will run, but the rest of your Mac will feel sluggish.",
                speed: speedSentence(rate)
            )
        }
        if rate < 3 {
            return make(
                .notRecommended,
                "This model is too big for this Mac to keep up with — answers would arrive a word at a time.",
                speed: speedSentence(rate)
            )
        }
        if rate < 12 {
            return make(.slow, "It fits, but this Mac will take its time with it.", speed: speedSentence(rate))
        }
        if resident <= Int64(Double(usable) * 0.6), rate >= 25 {
            return make(.runsGreat, "Fits comfortably and answers quickly.", speed: speedSentence(rate))
        }
        return make(.runsWell, "Fits with room to spare.", speed: speedSentence(rate))
    }

    /// The speed line, with no unit a non-technical person would have to look up.
    static func speedSentence(_ tokensPerSecond: Double) -> String {
        switch tokensPerSecond {
        case 35...: "Answers appear faster than you can read them."
        case 18..<35: "Answers appear about as fast as you can read them."
        case 10..<18: "Answers arrive at a comfortable reading pace."
        case 4..<10: "Answers arrive slowly — a paragraph takes several seconds."
        default: "Answers would arrive a word at a time."
        }
    }

    /// One decimal, or none once the number is big enough that a decimal is noise.
    ///
    /// The decimal has to survive past ten: "needs about 11 GB; this Mac can spare about
    /// 11 GB" is the sentence a person reads on a 14B model on a 16 GB Mac, and it reads as
    /// a bug. 11.5 against 10.5 says the same thing and is true.
    static func gigabytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
    }

    // MARK: - Reading a model's name

    /// Parameter count in billions, from a repo or file name.
    ///
    /// Parses any vendor's "-<N>B" token — e.g. a 4B-class app LLM, an 8B Instruct,
    /// a 1b-it, a 30B-A3B MoE (returns the total, 30, not the active 3) and a 7B.
    /// Returns nil rather
    /// than guessing when there is no such token — the file size then stands in.
    static func parameterBillions(fromName name: String) -> Double? {
        let text = name.replacingOccurrences(of: "_", with: "-")
        var best: Double?
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = index
            var sawDot = false
            while end < text.endIndex, text[end].isNumber || (text[end] == "." && !sawDot) {
                if text[end] == "." {
                    // "3.5-4B": the dot only belongs to the number when a digit follows.
                    let next = text.index(after: end)
                    guard next < text.endIndex, text[next].isNumber else { break }
                    sawDot = true
                }
                end = text.index(after: end)
            }
            // The character after the digits must be a b/B, and the one after that must not
            // be a letter — otherwise "Q4_K_M" and "bf16" would both look like sizes.
            if end < text.endIndex, text[end] == "b" || text[end] == "B" {
                let after = text.index(after: end)
                let boundaryOK = after >= text.endIndex || !text[after].isLetter
                if boundaryOK, let value = Double(text[index..<end]), value > 0, value <= 2_000 {
                    // "A3B" is the active-parameter marker on a mixture-of-experts model.
                    // Keep the largest number, which is the total.
                    best = max(best ?? 0, value)
                }
            }
            index = end < text.endIndex ? text.index(after: end) : end
        }
        return best
    }

    /// The quantization label in a GGUF file name: "Q4_K_M", "Q8_0", "IQ4_XS", "BF16".
    static func quantization(fromFileName fileName: String) -> String? {
        let stem = fileName.replacingOccurrences(of: ".gguf", with: "")
        let pieces = stem.split(whereSeparator: { $0 == "-" || $0 == "." })
        for piece in pieces.reversed() {
            let token = String(piece).uppercased()
            if token == "F16" || token == "F32" || token == "BF16" { return token }
            guard token.hasPrefix("Q") || token.hasPrefix("IQ") else { continue }
            let digits = token.drop(while: { !$0.isNumber })
            guard digits.first?.isNumber == true else { continue }
            return token
        }
        return nil
    }

    /// How good a quantization is, in words. "Q4_K_M" is the default everywhere because it
    /// is the smallest one that still sounds like the full model.
    static func quantizationDescription(_ quantization: String?) -> String {
        guard let quantization else { return "Standard quality" }
        let token = quantization.uppercased()
        if token.hasPrefix("F16") || token.hasPrefix("BF16") || token.hasPrefix("F32") {
            return "Full quality · much larger file"
        }
        if token.hasPrefix("Q8") { return "Highest quality · large file" }
        if token.hasPrefix("Q6") { return "Very high quality" }
        if token.hasPrefix("Q5") { return "High quality" }
        if token.hasPrefix("Q4") { return "Balanced quality and size" }
        if token.hasPrefix("Q3") { return "Smaller file · noticeably rougher answers" }
        if token.hasPrefix("Q2") || token.hasPrefix("IQ1") || token.hasPrefix("IQ2") {
            return "Smallest file · answers get unreliable"
        }
        return "Standard quality"
    }

    /// Ranks the files in a repo so the app can pick one without asking.
    ///
    /// Q4_K_M first: it is the size/quality knee for every model family, which is why it is
    /// the one almost every GGUF repo publishes. Then the neighbours either side.
    static func quantizationPreferenceRank(_ quantization: String?) -> Int {
        guard let quantization else { return 99 }
        return switch quantization.uppercased() {
        case "Q4_K_M": 0
        case "Q4_K_S": 1
        case "Q5_K_M": 2
        case "Q5_K_S": 3
        case "Q4_0", "Q4_1": 4
        case "Q6_K": 5
        case "IQ4_XS", "IQ4_NL": 6
        case "Q3_K_M", "Q3_K_L": 7
        case "Q8_0": 8
        default: 20
        }
    }
}
