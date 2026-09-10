import AppKit
import Foundation

/// The three things the user has to do outside Speechify before the agent can work, and the
/// one thing it can do for them.
///
/// Installing software, authorising a Google Cloud project and signing in all happen in
/// Terminal, in front of the user, because each of them asks questions and changes something
/// on the machine. An app that ran `brew install` behind a progress bar — or that drove an
/// OAuth consent screen itself — would be doing quietly what a note-taker most needs to be
/// seen doing openly.
///
/// Terminal is reached by writing a `.command` file and opening it, rather than through
/// AppleScript: `open` needs no Automation grant, and a script the user can read afterwards
/// is a better answer to "what did it just run on my Mac" than an Apple event nobody logged.
@MainActor
enum WorkspaceInstaller {

    /// Installs `gws` through whichever package manager the machine has.
    static func install() {
        run(named: "install-gws", script: installScript)
    }

    /// `gws auth setup` needs gcloud, so this installs that first. The long path, and the
    /// only one that produces a client without a trip to the Cloud console.
    static func setUpWithGcloud() {
        run(named: "gws-setup", script: """
            #!/bin/zsh
            set -e
            echo "Setting up a Google Cloud OAuth client for the Workspace CLI."
            echo
            if ! command -v gcloud >/dev/null 2>&1; then
              echo "> brew install --cask google-cloud-sdk"
              brew install --cask google-cloud-sdk
            fi
            gcloud auth login
            gws auth setup --login
            echo
            echo "Done. Back in Speechify, the Workspace tab will re-check this."
            """)
    }

    /// Signs the CLI in, asking only for the four services the tool catalogue uses.
    static func signIn() {
        run(named: "gws-signin", script: """
            #!/bin/zsh
            set -e
            gws auth login --services gmail,calendar,drive,docs
            echo
            gws auth status
            echo
            echo "Done. Back in Speechify, the Workspace tab will re-check this."
            """)
    }

    /// Copies a Desktop-app OAuth client downloaded from the Google Cloud console into the
    /// place `gws` reads it from.
    ///
    /// The short path, and the one worth taking on a machine that will never have gcloud:
    /// the same client ID also works for Phase 3's Google Calendar provider, so a user who
    /// has already made one for that has nothing left to do here.
    static func importClientConfig(from source: URL) throws {
        // Applied to Calendar as well as written to disk for the CLI: they are the same
        // credential, and asking for it twice is the kind of paperwork that makes a user
        // conclude the feature is broken.
        Settings.shared.apply(try GoogleClientConfig.adopt(from: source))
        Log.agent.info("imported an OAuth client for the Workspace CLI and Calendar")
    }

    // MARK: - Terminal

    /// The bundled installer, or a one-line equivalent when running outside a bundle.
    ///
    /// The script is a resource so that what the user is asked to run is reviewable as a
    /// file rather than assembled from string literals — but the app also runs straight out
    /// of the build directory during development, where there is no bundle to read.
    private static var installScript: String {
        if let url = Bundle.main.url(forResource: "install-gws", withExtension: "sh"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            return script
        }
        return """
            #!/bin/zsh
            set -e
            if command -v brew >/dev/null 2>&1; then
              brew install googleworkspace-cli
            else
              npm install -g @googleworkspace/cli
            fi
            gws --version
            """
    }

    /// Writes the script somewhere durable and opens it. `.command` is Terminal's own file
    /// type, so this needs no Automation permission and no AppleScript.
    private static func run(named name: String, script: String) {
        let directory = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("Scripts", isDirectory: true)
        let url = directory.appendingPathComponent("\(name).command")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        } catch {
            Log.agent.error("couldn't write \(name): \(error.localizedDescription, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(url)
        // Whatever this step does happens in Terminal and finishes after the user comes
        // back. Dropping the cached probe is what makes that return re-read the answer
        // instead of being served the state from before they started.
        AgentService.shared.invalidateStatus()
    }
}
