import Foundation

/// Exact google-connect flag only. Gates pause existing producer seams; no owner state.
enum GoogleReviewFixture {
    actor Gate {
        private var entered = false
        private var released = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?
        func pause() async {
            entered = true
            arrival?.resume(); arrival = nil
            if !released { await withCheckedContinuation { held = $0 } }
        }
        func wait() async {
            if !entered { await withCheckedContinuation { arrival = $0 } }
        }
        func release() { released = true; held?.resume(); held = nil }
    }
    final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Int] = [:]
        func hit(_ key: String) -> Int { lock.withLock { values[key, default: 0] += 1; return values[key]! } }
        func count(_ key: String) -> Int { lock.withLock { values[key, default: 0] } }
    }
    static func executable(_ label: String) throws -> (root: URL, executable: URL, marker: URL) {
        precondition(GoogleAccessTokens.testHooksAdmitted)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesGoogleReview-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("gws")
        let script = #"""
        #!/bin/sh
        touch "$(dirname "$0")/ran"
        if [ "$1" = --version ]; then echo 'gws 0.22.5'; exit 0; fi
        if [ "$1" = auth ] && [ "$2" = status ]; then
          echo '{"auth_method":"oauth","client_config_exists":true,"encrypted_credentials_exists":true,"plain_credentials_exists":false,"token_cache_exists":false,"storage":"alternate fixture login"}'
        elif [ "$3" = getProfile ]; then
          echo '{"emailAddress":"alternate@example.test"}'
        else
          echo '{}'
        fi

        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (root, executable, root.appendingPathComponent("ran"))
    }
    nonisolated static func response(_ request: URLRequest, status: Int = 200, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
