import llama

/// Prefix reuse for the llama runtime (P0-18): which tokens of a prompt are already in the
/// KV cache, and what the last prefill did.
///
/// The runtime used to clear the whole memory and decode every prompt token on every call,
/// so a three-round tool turn paid the same 1.2–2.3 k-token prefill three times. The helpers
/// here decide how much of the prompt is already decoded; `NotesModelRuntime.preparePrefix`
/// removes the rest and decodes only what changed.
enum PrefixReuse {
    /// One switch for rollback. False restores clear-and-re-prefill everywhere: `keepCount`
    /// answers 0, so the runtime clears the memory before it decodes. Read from the actor;
    /// only ever flipped by a person rolling the feature back.
    nonisolated(unsafe) static var enabled = true

    /// How many tokens of `a` and `b` agree position for position from the start.
    static func commonPrefixLength(_ a: [llama_token], _ b: [llama_token]) -> Int {
        let limit = min(a.count, b.count)
        var matched = 0
        while matched < limit, a[matched] == b[matched] { matched += 1 }
        return matched
    }

    /// Tokens of `cached` kept for `prompt`: the longest common token prefix, capped so at
    /// least one prompt token is decoded now.
    ///
    /// The cap is the whole reason this is not `commonPrefixLength`. llama.cpp samples the
    /// next token from the logits of the last decoded position, so keeping the entire prompt
    /// would leave the sampler with no fresh logits. When the cached prefix is identical to
    /// the prompt, the last token is removed and decoded again.
    static func keepCount(cached: [llama_token], prompt: [llama_token]) -> Int {
        guard enabled else { return 0 }
        let common = commonPrefixLength(cached, prompt)
        return min(common, max(0, prompt.count - 1))
    }
}

/// What one prefill cost: the prompt it was given, how much of it was already decoded, how
/// much was decoded now, and how long that took.
struct PrefillStats: Sendable, Equatable {
    let promptTokens: Int
    let reused: Int
    let decoded: Int
    let seconds: Double
}
