import Foundation

/// A Google OAuth client of type "Desktop app", as the Cloud console hands it over.
///
/// Two separate features need one of these and there is no reason for the user to supply it
/// twice: the Calendar provider signs in with it directly, and the Workspace CLI reads it
/// from `~/.config/gws/client_secret.json`. So the file is the single source of truth —
/// whichever screen the user imports it on, it is written to that path *and* applied to
/// Settings, and the other screen finds it already done.
///
/// The console's JSON wraps everything in one key naming the client type: `installed` for a
/// desktop client, `web` for one that isn't. Both are accepted here because Google will hand
/// a user either, and refusing the wrong one at import time only tells them "invalid file"
/// when the honest answer comes later, from Google, at sign-in.
struct GoogleClientConfig: Sendable, Equatable {
    let clientID: String
    let clientSecret: String

    private struct Payload: Decodable {
        let clientID: String
        let clientSecret: String?

        private enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case clientSecret = "client_secret"
        }
    }

    private struct Document: Decodable {
        let installed: Payload?
        let web: Payload?

        var payload: Payload? { installed ?? web }
    }

    init?(data: Data) {
        guard let payload = try? JSONDecoder().decode(Document.self, from: data).payload,
              !payload.clientID.isEmpty
        else { return nil }
        clientID = payload.clientID
        // A desktop client's secret is not confidential — it ships inside every copy of any
        // app that has one — but Google's token endpoint still asks for it, so an absent one
        // is stored as empty rather than treated as a failure to parse.
        clientSecret = payload.clientSecret ?? ""
    }

    /// The client already on this machine, if the Workspace CLI has one.
    static var installed: GoogleClientConfig? {
        guard let data = try? Data(contentsOf: GoogleWorkspaceCLI.clientConfigURL) else { return nil }
        return GoogleClientConfig(data: data)
    }

    /// Copies a downloaded client JSON to where the CLI reads it, and returns what it holds.
    ///
    /// Replaced wholesale rather than merged: this file is one credential, and a half-updated
    /// one is a sign-in that fails with a message about the wrong project.
    @discardableResult
    static func adopt(from source: URL) throws -> GoogleClientConfig {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: source)
        guard let config = GoogleClientConfig(data: data) else { throw Failure.notAClientConfig }

        let destination = GoogleWorkspaceCLI.clientConfigURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        Log.calendar.info("adopted a Google OAuth client for Calendar and the Workspace CLI")
        return config
    }

    enum Failure: LocalizedError {
        case notAClientConfig

        var errorDescription: String? {
            "That file isn\u{2019}t a Google OAuth client. Download the JSON for a client of "
                + "type \u{201c}Desktop app\u{201d} from the Google Cloud console."
        }
    }
}

@MainActor
extension Settings {
    /// Whether the Calendar provider has what it needs to start a sign-in.
    var hasGoogleClient: Bool { !googleClientID.isEmpty }

    /// Points the Calendar provider at a client. Idempotent, so re-importing the same file
    /// on either screen changes nothing.
    func apply(_ config: GoogleClientConfig) {
        if googleClientID != config.clientID { googleClientID = config.clientID }
        if googleClientSecret != config.clientSecret { googleClientSecret = config.clientSecret }
    }
}
