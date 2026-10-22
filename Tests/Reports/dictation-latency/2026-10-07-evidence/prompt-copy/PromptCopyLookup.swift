import Foundation

typealias llama_token = Int32

enum LookupProducer {
    /// Request-local continuation proposal only. Matching sampler tokens, not this
    /// lookup, authorize output. A bounded first prototype measures this scan's cost.
    static func promptCopyDraft(
        source: [llama_token], history: [llama_token], limit: Int
    ) -> [llama_token] {
        guard limit > 0, history.count >= 3, source.count > 3 else { return [] }
        let width = min(8, history.count, source.count - 1)
        for count in stride(from: width, through: 3, by: -1) {
            let suffix = history.suffix(count)
            for end in stride(from: source.count - 1, through: count, by: -1) {
                if source[(end - count)..<end].elementsEqual(suffix) {
                    let length = min(limit, source.count - end)
                    return Array(source[end..<(end + length)])
                }
            }
        }
        return []
    }

}
