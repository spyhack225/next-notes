import Foundation

enum AppIdentity {
    static let bundleIdentifier = "ai.pivotstudio.speechify"

    private static let supportDirectoryName = "Speechify"

    static var applicationSupportDirectory: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = root.appendingPathComponent(supportDirectoryName, isDirectory: true)

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
