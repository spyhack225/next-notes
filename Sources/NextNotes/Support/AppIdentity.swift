import Foundation

enum AppIdentity {
    static let bundleIdentifier = "ai.pivotstudio.nextnotes"

    private static let supportDirectoryName = "Next Notes"

    /// What the app called itself before the rename. Every meeting, transcript, dictionary
    /// entry and the multi-gigabyte local model are still filed under these two names on
    /// machines that ran an earlier build, so both migrations below need them.
    private static let previousBundleIdentifier = "ai.pivotstudio.speechify"
    private static let previousSupportDirectoryName = "Speechify"

    /// Written once the old preferences domain has been folded into this one, so a second
    /// launch can't undo settings the user has changed since.
    private static let defaultsMigratedKey = "migratedFromPreviousBundleIdentifier"

    static var applicationSupportDirectory: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = root.appendingPathComponent(supportDirectoryName, isDirectory: true)

        // Deliberately above the `createDirectory` below, and not somewhere in app startup:
        // several stores make their own subdirectory the first time they are read, and any
        // one of them arriving here first would create the new folder, make the guard inside
        // `migrateSupportDirectory` skip, and strand the user's data in the old one.
        _ = migration

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// The rename migrations, run exactly once per launch.
    ///
    /// A `static let` is the dispatch-once: Swift guarantees the initializer runs a single
    /// time, on first access, no matter how many callers reach it at once.
    ///
    /// Both halves exist only to carry existing installs over the rename, and can be deleted
    /// — along with the two `previous…` constants and the marker key — once every machine
    /// that mattered has launched a renamed build. A few weeks is plenty.
    private static let migration: Void = {
        migrateSupportDirectory()
        migrateUserDefaults()
    }()

    /// Renames `~/Library/Application Support/Speechify` to `…/Next Notes`.
    ///
    /// A move, never a copy. That folder holds the meetings, the transcripts, the dictionary,
    /// `formatting.txt`, `runs.jsonl` and a local model of several gigabytes; copying it would
    /// demand all of that in free space a second time, which is space the machines running
    /// this app do not reliably have. `moveItem` within one volume is a rename, so it costs
    /// nothing and cannot half-succeed.
    private static func migrateSupportDirectory() {
        let fileManager = FileManager.default
        guard let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }

        let new = root.appendingPathComponent(supportDirectoryName, isDirectory: true)
        let old = root.appendingPathComponent(previousSupportDirectoryName, isDirectory: true)

        guard !fileManager.fileExists(atPath: new.path),
              fileManager.fileExists(atPath: old.path) else { return }

        do {
            try fileManager.moveItem(at: old, to: new)
            Log.app.notice("Moved the support directory to \(supportDirectoryName, privacy: .public).")
        } catch {
            // Failing here is not worth taking the app down for. The caller goes on to make
            // an empty directory and the app starts as if it were new — but the old folder is
            // untouched on disk, so nothing is lost and the log says where it went wrong.
            Log.app.error(
                "Could not move the old support directory: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Carries the settings across from the old preferences domain.
    ///
    /// `UserDefaults.standard` is keyed on the bundle identifier, so the renamed app opens on
    /// a domain that has never been written: the push-to-talk key, the engine choice, the
    /// cleanup toggles and the HUD placement would all quietly snap back to their defaults.
    /// The app is not sandboxed, so the old domain can simply be opened by name and read.
    private static func migrateUserDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return }

        // Marked before the copy, not after. Whatever happens below happens once: a domain
        // that could not be read will not be retried on the next launch, and a copy that
        // half-finished will not run again over settings the user has since corrected.
        defaults.set(true, forKey: defaultsMigratedKey)

        guard let previous = UserDefaults(suiteName: previousBundleIdentifier) else {
            Log.app.error(
                "Could not open the previous preferences domain \(previousBundleIdentifier, privacy: .public)."
            )
            return
        }

        // Only keys this domain has no answer for. `dictionaryRepresentation()` includes
        // everything the old domain inherited from the global domain — languages, keyboard
        // settings, measurement units — and this app has no business stamping private copies
        // of those into its own defaults.
        for (key, value) in previous.dictionaryRepresentation()
        where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
