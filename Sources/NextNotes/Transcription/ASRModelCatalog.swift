import Foundation

/// Language mode chooses a default; a deliberate model choice stays separate.
enum DictationLanguage: String, CaseIterable, Sendable {
    case english, multi
    var displayName: String { self == .english ? "English" : "Multi" }
    var recommendedModel: SpeechEngineChoice { self == .english ? .phonon : .voz }
}

struct ASRMeasurement: Sendable {
    let firstMS: Double
    let finalMS: Double
    /// 100 × (1 − WER), one authored fixture. Not a general accuracy estimate.
    let wordAccuracy: Double
}
struct ASRModelInfo: Sendable {
    let choice: SpeechEngineChoice
    let bytes: Int64
    let english: ASRMeasurement
    let french: ASRMeasurement?
    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
    func measurement(for language: DictationLanguage) -> ASRMeasurement? {
        language == .english ? english : french
    }
}

enum ASRModelCatalog {
    static let benchmarkURL = URL(string: "https://next-notes.com/?page=benchmarks#asr-comparison")!
    // Generated measurements below use the retained 22 October M3 runtime suite.
    // The generator and website read shared/asr-models.json, preserving one evidence source.
    static let models: [ASRModelInfo] = ASRMeasuredModels.rows
    static func info(_ choice: SpeechEngineChoice) -> ASRModelInfo? {
        models.first { $0.choice == choice }
    }
    /// Cold preparation can exceed the controller’s45s startup budget. Keep
    /// speech working with Apple until the selected alternative has really loaded.
    static func readyChoice(_ selected: SpeechEngineChoice, language: DictationLanguage,
                            readyModel: SpeechEngineChoice?) -> SpeechEngineChoice {
        let model = resolved(selected, language: language)
        if model == .apple || model == .parakeet || model == readyModel { return model }
        return .apple
    }
    static func resolved(_ selected: SpeechEngineChoice, language: DictationLanguage) -> SpeechEngineChoice {
        if selected == .automatic || (selected == .phonon && language == .multi) {
            return language.recommendedModel
        }
        return selected
    }
}

extension SpeechEngineChoice {
    var usageProvider: UsageProvider {
        switch self {
        case .apple: .appleSpeech
        case .parakeet, .redux, .ultra: .parakeet
        default: .localSpeech
        }
    }
}
