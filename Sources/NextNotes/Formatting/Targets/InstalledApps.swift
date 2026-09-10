import AppKit
import Foundation

/// One application found on this Mac, reduced to what the formatting table needs.
///
/// Deliberately does not carry the icon. `NSImage` is not `Sendable`, and the scan runs off
/// the main actor; the icon is cheap to fetch by path in the row that draws it.
struct InstalledApp: Identifiable, Sendable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String
    let path: String
}

/// Finds the applications installed on this Mac.
///
/// Exists because the alternative was asking people to type `com.tinyspeck.slackmacgap` from
/// memory. Nobody knows their apps' bundle identifiers, and getting one wrong fails silently:
/// the profile is simply never matched, and the user sees plain prose with no explanation.
enum InstalledApps {
    /// Where applications actually live. `~/Applications` matters more than it looks: Chrome
    /// installs web apps there, and Google Meet as a Chrome web app is exactly the kind of
    /// target this table is for.
    private static var searchRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
        ]
    }

    /// Scans off the main actor. File IO over several hundred bundles is not something to do
    /// while a sheet is trying to appear.
    static func scan() async -> [InstalledApp] {
        await Task.detached(priority: .userInitiated) { scanSync() }.value
    }

    private static func scanSync() -> [InstalledApp] {
        var found: [String: InstalledApp] = [:]
        for root in searchRoots {
            for url in bundles(under: root, depth: 2) {
                guard let app = app(at: url) else { continue }
                // First writer wins, so /Applications beats /System/Applications for an app
                // that exists in both. The user-installed copy is the one they mean.
                if found[app.bundleID] == nil { found[app.bundleID] = app }
            }
        }
        return found.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// One level of recursion below each root, which reaches Utilities and Chrome's web-app
    /// folder without walking an entire home directory.
    private static func bundles(under root: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []

        var result: [URL] = []
        for url in contents {
            if url.pathExtension == "app" {
                result.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                result.append(contentsOf: bundles(under: url, depth: depth - 1))
            }
        }
        return result
    }

    /// Reads one bundle. Returns nil for anything without an identifier, which is the only
    /// thing the formatting table can key on.
    static func app(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else {
            return nil
        }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        // Some bundles prefix the name with a bidirectional control character — WhatsApp
        // ships a left-to-right mark — which is invisible but sorts and compares as content.
        let clean = name.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\u{200E}\u{200F}"))
        )
        return InstalledApp(
            bundleID: id,
            displayName: clean.isEmpty ? url.deletingPathExtension().lastPathComponent : clean,
            path: url.path
        )
    }
}
