import AppKit
import Foundation
import Observation

/// The app the dictated text is going to land in, read at the moment recording starts.
struct OutputTarget: Sendable, Hashable {
    var bundleID: String
    var displayName: String
}

/// Which app gets which formatting, persisted as a plain text file you can edit by hand.
///
/// `DictionaryStore` is the model this follows deliberately: a text file in
/// `Application Support/Next Notes/`, a documented header, atomic writes, and a
/// `DispatchSource` watcher so an edit made in a text editor shows up in the app live.
/// That is what "the user should be able to edit the list" means here, and it keeps the
/// table out of `UserDefaults`, where a list of records with five flags each has no
/// business being.
///
/// The format is one app per line, three `|`-separated fields:
///
/// ```
/// com.tinyspeck.slackmacgap | Slack | bullets, numbered, code
/// com.apple.mail            | Mail  | plain
/// ```
///
/// The third field is a comma-separated list of `markdown`, `bullets`, `numbered`,
/// `tables`, `code`, or the word `plain` for none of them. `#` starts a comment.
/// An app with no line here is plain prose — see `profile(for:)`.
@MainActor
@Observable
final class OutputProfileStore {
    static let shared = OutputProfileStore()

    private(set) var profiles: [OutputProfile] = []

    /// The app that was frontmost when recording started. Nil until something calls
    /// `captureTarget()`.
    private(set) var capturedTarget: OutputTarget?

    /// The most recent frontmost app that was not Next Notes itself.
    ///
    /// Tracked continuously rather than read on demand because the one place the UI needs
    /// it — the "Add the app I was just in" button — runs while the Settings window is
    /// frontmost, so `NSWorkspace.frontmostApplication` at that moment is always Next Notes.
    private(set) var lastForeignApp: OutputTarget?

    private var watcher: DispatchSourceFileSystemObject?
    /// Set while we're writing, so our own save doesn't read back as an external edit.
    private var isSaving = false
    private var activationObserver: NSObjectProtocol?

    static var fileURL: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("formatting.txt")
    }

    private init() {
        // Seeding only when the file is absent is the whole contract with the user: once
        // the file exists it is theirs. Re-adding a default row they deleted would make the
        // table impossible to actually edit — the app would keep arguing with them.
        if !FileManager.default.fileExists(atPath: Self.fileURL.path) {
            profiles = OutputProfileDefaults.all
            save()
        } else {
            load()
        }
        startWatching()
        startTrackingFrontmostApp()
    }

    // MARK: - Resolving a target

    /// The profile for a bundle identifier, or nil when the table says nothing about it.
    func profile(for bundleID: String) -> OutputProfile? {
        profiles.first { $0.bundleID == bundleID }
    }

    /// What an app should be given. **An app not in the table gets plain prose.**
    ///
    /// This is the safety property the whole feature turns on: emitting `**bold**` into an
    /// app that shows the asterisks is worse than emitting nothing, so the default is never
    /// "assume it renders Markdown". An unknown app is answered, not guessed at.
    func resolved(for target: OutputTarget?) -> OutputProfile {
        guard let target else {
            return .plain(bundleID: "", displayName: "the focused app")
        }
        return profile(for: target.bundleID)
            ?? .plain(bundleID: target.bundleID, displayName: target.displayName)
    }

    // MARK: - Reading the target

    /// Snapshots the frontmost app. **Call this when recording starts, not when it ends.**
    ///
    /// By the time text is injected the user may have switched away — formatting a list as
    /// Slack bullets and then dropping it into Mail is worse than not formatting at all.
    /// The HUD is a non-activating panel, so Next Notes never takes the foreground during a
    /// dictation and the frontmost app at key-down really is the app the text will land in.
    @discardableResult
    func captureTarget() -> OutputTarget? {
        capturedTarget = Self.frontmostApp() ?? lastForeignApp
        if let capturedTarget {
            Log.inject.info("output target: \(capturedTarget.displayName, privacy: .public)")
        }
        return capturedTarget
    }

    /// Forgets the captured target. Called once the text has been injected, so a stale
    /// target can never be reused by a later dictation that failed to capture.
    func clearCapturedTarget() {
        capturedTarget = nil
    }

    /// The profile for the app captured at recording start, or plain when nothing was
    /// captured. Deliberately *not* falling back to whatever is frontmost right now: that
    /// is exactly the wrong-app case this feature exists to avoid, and being silently plain
    /// is the safe failure.
    var capturedProfile: OutputProfile { resolved(for: capturedTarget) }

    private static func frontmostApp() -> OutputTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != AppIdentity.bundleIdentifier
        else { return nil }
        return OutputTarget(bundleID: bundleID, displayName: app.localizedName ?? bundleID)
    }

    private func startTrackingFrontmostApp() {
        lastForeignApp = Self.frontmostApp()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A `Task` rather than `MainActor.assumeIsolated`, even though this block is
            // delivered on the main queue: `assumeIsolated` does not check the claim, it
            // asserts it, and it has taken this app down once already.
            Task { @MainActor in
                guard let self, let app = Self.frontmostApp() else { return }
                self.lastForeignApp = app
            }
        }
    }

    // MARK: - Editing

    /// Adds a profile, or replaces the one already held for that bundle identifier.
    func upsert(_ profile: OutputProfile) {
        let trimmed = OutputProfile(
            bundleID: profile.bundleID.trimmingCharacters(in: .whitespaces),
            displayName: Self.sanitized(profile.displayName),
            capabilities: profile.capabilities
        )
        guard !trimmed.bundleID.isEmpty else { return }

        if let index = profiles.firstIndex(where: { $0.bundleID == trimmed.bundleID }) {
            profiles[index] = trimmed
        } else {
            profiles.append(trimmed)
        }
        sortProfiles()
        save()
    }

    func delete(bundleIDs: Set<String>) {
        profiles.removeAll { bundleIDs.contains($0.bundleID) }
        save()
    }

    func setCapability(_ capability: OutputCapability, on: Bool, for bundleID: String) {
        guard let index = profiles.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        if on {
            profiles[index].capabilities.insert(capability)
        } else {
            profiles[index].capabilities.remove(capability)
        }
        save()
    }

    /// Puts back every default the user has since deleted, leaving their own rows and their
    /// edits to a default row alone. Additive on purpose — "restore defaults" that threw
    /// away hand-tuned rows would be a data-loss button behind a reassuring word.
    func addMissingDefaults() {
        let known = Set(profiles.map(\.bundleID))
        let missing = OutputProfileDefaults.all.filter { !known.contains($0.bundleID) }
        guard !missing.isEmpty else { return }
        profiles.append(contentsOf: missing)
        sortProfiles()
        save()
    }

    private func sortProfiles() {
        profiles.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// `|` is the field separator and `#` starts a comment, so neither can survive in a
    /// display name — a name carrying one would write a line that reads back as a
    /// different profile, or as half of one.
    private static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Persistence

    private func load() {
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else {
            profiles = []
            return
        }
        profiles = Self.parse(text)
        sortProfiles()
    }

    static func parse(_ text: String) -> [OutputProfile] {
        var result: [OutputProfile] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // A trailing comment is allowed on a real line, so someone can annotate a row.
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
            }

            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { continue }

            let bundleID = fields[0]
            guard !bundleID.isEmpty else { continue }
            // Last line wins on a duplicate, which is what someone editing by hand and
            // pasting a corrected row underneath the old one means.
            let displayName = fields[1].isEmpty ? bundleID : fields[1]
            let capabilities = fields.count >= 3 ? parseCapabilities(fields[2]) : []

            let profile = OutputProfile(
                bundleID: bundleID,
                displayName: displayName,
                capabilities: capabilities
            )
            if let index = result.firstIndex(where: { $0.bundleID == bundleID }) {
                result[index] = profile
            } else {
                result.append(profile)
            }
        }
        return result
    }

    /// Unknown words are ignored rather than failing the line: a row written by a newer
    /// build, or a typo, should cost that one capability and not the whole app's entry.
    /// Ignoring is also the safe direction — an unrecognised word can only ever *remove* a
    /// capability, never grant one.
    private static func parseCapabilities(_ field: String) -> Set<OutputCapability> {
        var result: Set<OutputCapability> = []
        for token in field.split(whereSeparator: { $0 == "," || $0 == " " }) {
            let word = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard !word.isEmpty, word != "plain", word != "none" else { continue }
            if let capability = OutputCapability(rawValue: word) {
                result.insert(capability)
            }
        }
        return result
    }

    private func save() {
        isSaving = true
        defer { isSaving = false }
        try? Self.serialize(profiles).write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }

    /// The file's whole text for a set of profiles.
    ///
    /// Separate from `save()` so `parse(serialize(x)) == x` can be checked without writing
    /// over the user's real table — which is what `--selftest-formatting` does.
    static func serialize(_ profiles: [OutputProfile]) -> String {
        // Pad the first two columns so the file stays a readable table by hand. Cheap, and
        // it is the difference between a file someone will edit and one they won't.
        let idWidth = profiles.map(\.bundleID.count).max() ?? 0
        let nameWidth = profiles.map(\.displayName.count).max() ?? 0

        let body = profiles.map { profile in
            let id = profile.bundleID.padding(toLength: max(idWidth, profile.bundleID.count),
                                              withPad: " ", startingAt: 0)
            let name = profile.displayName.padding(toLength: max(nameWidth, profile.displayName.count),
                                                   withPad: " ", startingAt: 0)
            let capabilities = profile.isPlain
                ? "plain"
                : profile.sortedCapabilities.map(\.token).joined(separator: ", ")
            return "\(id) | \(name) | \(capabilities)"
        }.joined(separator: "\n")

        return header + body + "\n"
    }

    private static let header = """
        # Next Notes output formatting
        #
        # Dictated text is formatted to suit the app it is about to be typed into. One app
        # per line, three fields separated by "|":
        #
        #   bundle identifier | name | what that app renders
        #
        # The third field is any of:
        #
        #   markdown   headings, bold, links — the # and ** marks
        #   bullets    lists written as "- item"
        #   numbered   lists written as "1. item"
        #   tables     Markdown pipe tables
        #   code       ``` fenced blocks
        #
        # or the word "plain" for none of them. "#" starts a comment.
        #
        # An app with no line here gets plain prose. That is deliberate: writing "**bold**"
        # into an app that shows the asterisks is worse than writing nothing at all, so an
        # app is only ever given a mark it is known to render.
        #
        # Nothing here invents structure. These say which syntax a spoken list may be
        # written in — never that prose should be turned into a list or a table.
        #
        # Edit this file directly if you like; the app picks up changes immediately.

        """

    // MARK: - External edits

    /// Watches the file so a hand edit shows up in the UI without a relaunch.
    ///
    /// Rearms after every event: an atomic write replaces the inode, so the descriptor we
    /// were watching is gone the moment the file changes — including when *we* save.
    private func startWatching() {
        watcher?.cancel()

        let descriptor = open(Self.fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.isSaving { self.load() }
            self.startWatching()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()

        watcher = source
    }
}
