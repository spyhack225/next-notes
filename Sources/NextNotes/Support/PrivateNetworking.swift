import Foundation

/// Where every request that carries a person's words, a model's reply, a token or account
/// data goes.
///
/// `URLSession.shared` is backed by the process-wide `URLCache`, and that cache writes
/// response bodies to disk. On 2026-09-23 a full OpenRouter SSE stream — the model's
/// reasoning included — was found in
/// `~/Library/Caches/ai.pivotstudio.nextnotes/fsCachedData/` (G N4, P0-19). The private
/// session is ephemeral with `urlCache = nil`, so nothing from these requests reaches
/// `Cache.db`; the ephemeral configuration still keeps in-memory cookies, which is enough
/// for the OAuth token endpoint.
///
enum PrivateURLSession {
    /// For every request that carries a person's words, a model's reply, a token or account data.
    static let shared = URLSession(configuration: configuration)

    /// The configuration `shared` is built from: no cache to read or write, and a policy
    /// that would ignore one if it were there.
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// The record that the one-time purge already ran; `purgeLegacyCache` is its only writer.
    static let purgeRecordKey = "privacy.urlCachePurged.v1"

    /// Once per install; the caller passes stores so a self-test can isolate them.
    ///
    /// `true` when this call removed the legacy cache, `false` when it had already run and
    /// touched nothing. `NextNotesApp` calls it at the first normal launch after this
    /// ships — never under the self-test harness, which returns before the call site.
    @discardableResult
    static func purgeLegacyCache(
        cache: URLCache = .shared,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !defaults.bool(forKey: purgeRecordKey) else { return false }
        cache.removeAllCachedResponses()
        defaults.set(true, forKey: purgeRecordKey)
        return true
    }
}
