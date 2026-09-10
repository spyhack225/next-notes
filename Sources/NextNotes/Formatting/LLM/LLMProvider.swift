import Foundation

/// Which local language model writes the notes.
///
/// Both are on-device and both are optional: Qwen is a 2.7 GB download the user may not
/// want to keep, and Apple's model needs Apple Intelligence turned on. The generator picks
/// the configured one and falls back to the other rather than producing nothing.
enum LLMProviderID: String, CaseIterable, Sendable, Codable, Identifiable {
    case qwen35_4b
    case appleFoundation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen35_4b: "Qwen3.5-4B"
        case .appleFoundation: "Apple Foundation Model"
        }
    }

    /// What the difference actually means to someone choosing between them.
    var summary: String {
        switch self {
        case .qwen35_4b:
            "A 2.7 GB download that reads a whole meeting at once. Slower, and much better "
                + "at long transcripts."
        case .appleFoundation:
            "Already on this Mac and fast, but its short context means a long meeting is "
                + "summarised in pieces."
        }
    }
}

/// One text-generation model, described the way the notes generator needs it.
///
/// The generator's only real decision is "does this transcript fit in one prompt", so a
/// provider has to answer two questions beyond generating: how much context it has, and how
/// many tokens a piece of text costs. Everything else — loading, unloading, sampling — is
/// the provider's own business.
protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }

    /// The largest prompt this provider will accept, in tokens.
    var contextTokens: Int { get }

    /// Why this provider can't run right now, or nil when it can.
    var unavailableReason: String? { get async }

    func countTokens(_ text: String) async throws -> Int

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion
}

/// What a generation produced, and what it cost.
///
/// The token count and duration are here rather than logged inside each provider because
/// `--selftest-notes` reports tokens per second, and a number the provider keeps to itself
/// can't be reported by the thing that ran it.
struct LLMCompletion: Sendable {
    let text: String
    let generatedTokens: Int
    let duration: TimeInterval

    var tokensPerSecond: Double {
        duration > 0 ? Double(generatedTokens) / duration : 0
    }
}

enum LLMProviders {
    static func make(_ id: LLMProviderID) -> any LLMProvider {
        switch id {
        case .qwen35_4b: LlamaLLMProvider()
        case .appleFoundation: FoundationModelLLMProvider()
        }
    }

    /// The configured provider when it can run, otherwise the other one when *it* can.
    ///
    /// Falling back rather than failing is deliberate: a user who turned on automatic notes
    /// and then deleted the Qwen download should still get notes, and being told which model
    /// wrote them (`Meeting.notesModel`) is a better outcome than an empty Notes tab.
    static func resolve(preferring preferred: LLMProviderID) async -> (any LLMProvider)? {
        let ordered = [preferred] + LLMProviderID.allCases.filter { $0 != preferred }
        for id in ordered {
            let provider = make(id)
            if await provider.unavailableReason == nil { return provider }
        }
        return nil
    }
}
