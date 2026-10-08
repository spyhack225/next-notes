import CryptoKit
import Foundation

/// The Google Workspace tool (`gws`, Apache-2.0), fetched and kept by the app itself.
///
/// Nobody should have to install Homebrew or open Terminal to connect Google. The app
/// downloads one pinned release from Google's own GitHub project into its Application
/// Support folder, checks it against a SHA-256 written into this file, unpacks it and runs
/// `--version` before trusting it. The transfer goes through `ModelDownloader.download`, the
/// same resumable, verified path the models use. A person who already has their own `gws`
/// keeps it: `GoogleWorkspaceCLI` uses only this verified copy for the app’s own sign-in.
///
/// The paused packet attributes these candidate pins to the release's GitHub asset
/// list. This work has not verified that attribution. A release change must update
/// the version and both assets together, using independently checked publisher data.
enum ManagedWorkspaceTool {
    // Archive pins inherited from the paused packet; neither asset has been fetched or
    // independently checked in this work. Do not treat fixture green as release verification.
    static let version = "0.22.5"

    struct Asset: Sendable, Equatable {
        let name: String
        let bytes: Int64
        let sha256: String
    }

    static let appleSilicon = Asset(
        name: "google-workspace-cli-aarch64-apple-darwin.tar.gz",
        bytes: 6_119_841,
        sha256: "1d2a9ffd5bc9b2c2c4b48630daf082fad13d9e57d741988a2c248eed562f7dac")
    static let intel = Asset(
        name: "google-workspace-cli-x86_64-apple-darwin.tar.gz",
        bytes: 6_384_868,
        sha256: "51f9bd731404d4bba26c36e2e30dd68c56dccd1f834c01252cb0b14d6a6544b2")

    static var currentAsset: Asset {
        #if arch(arm64)
        appleSilicon
        #else
        intel
        #endif
    }

    static let releaseBase = "https://github.com/googleworkspace/cli/releases/download/"

    static func downloadURL(for asset: Asset, version: String = version, base: String = releaseBase) -> URL? {
        URL(string: base + "v\(version)/" + asset.name)
    }

    static var defaultRoot: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("Tools/gws", isDirectory: true)
    }

    private struct Verification: Codable {
        let archiveSHA256: String
        let executableSHA256: String
    }
    private struct FileIdentity: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
        let created: Date
        init?(_ url: URL) {
            guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
                  let values = try? FileManager.default.attributesOfItem(atPath: url.path),
                  values[.type] as? FileAttributeType == .typeRegular,
                  let inode = values[.systemFileNumber] as? UInt64,
                  let size = values[.size] as? UInt64,
                  let modified = values[.modificationDate] as? Date,
                  let created = values[.creationDate] as? Date else { return nil }
            self.inode = inode; self.size = size; self.modified = modified; self.created = created
        }
    }
    private final class VerifiedCache: @unchecked Sendable {
        let lock = NSLock()
        var value: (url: URL, binary: FileIdentity, witness: FileIdentity, pin: String)?
    }
    private static let cache = VerifiedCache()
    static func executable(root: URL = defaultRoot, version: String = version, asset: Asset = currentAsset) -> URL? {
        if SelfTest.isRunning, root == defaultRoot { return nil }
        let url = root.appendingPathComponent(version).appendingPathComponent("gws")
        let witness = url.deletingLastPathComponent().appendingPathComponent("verified.json")
        guard FileManager.default.isExecutableFile(atPath: url.path),
              let binary = FileIdentity(url), let record = FileIdentity(witness) else { return nil }
        if cache.lock.withLock({
            guard let value = cache.value else { return false }
            return value.url == url && value.binary == binary && value.witness == record && value.pin == asset.sha256
        }) { return url }
        guard let data = try? Data(contentsOf: witness),
              let verified = try? JSONDecoder().decode(Verification.self, from: data),
              verified.archiveSHA256 == asset.sha256,
              let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
              digest(bytes) == verified.executableSHA256,
              FileIdentity(url) == binary, FileIdentity(witness) == record else { return nil }
        cache.lock.withLock { cache.value = (url, binary, record, asset.sha256) }
        return url
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum Failure: LocalizedError, Equatable {
        case couldNotFetch
        case damaged
        case wouldNotRun

        var errorDescription: String? {
            switch self {
            case .couldNotFetch:
                "Next Notes couldn\u{2019}t get what it needs to reach Google. Check your connection and try again."
            case .damaged:
                "What Next Notes fetched for Google didn\u{2019}t check out, so it wasn\u{2019}t used. Please try again."
            case .wouldNotRun:
                "Next Notes couldn\u{2019}t start what it needs to reach Google on this Mac."
            }
        }
    }

    /// Fetches, verifies, unpacks and checks the tool, returning its path. Does nothing when
    /// this version is already installed. Safe to call from the main actor: the transfer and
    /// the unpacking suspend, they never block it.
    @discardableResult
    static func install(
        root: URL = defaultRoot,
        asset: Asset = currentAsset,
        version: String = version,
        base: String = releaseBase,
        commandTimeout: TimeInterval = runTimeout
    ) async throws -> URL {
        precondition(GoogleAccessTokens.testHooksAdmitted || (root == defaultRoot && asset == currentAsset && version == Self.version && base == releaseBase))
        if let existing = executable(root: root, version: version, asset: asset) { return existing }
        guard let url = downloadURL(for: asset, version: version, base: base) else { throw Failure.couldNotFetch }

        let fileManager = FileManager.default
        let staging = root.appendingPathComponent("\(version).staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent(asset.name)
        let remote = ModelDownloader.RemoteFile(
            url: url, destination: archive, expectedBytes: asset.bytes,
            expectedSHA256: asset.sha256, bearerToken: nil,
            // About six megabytes: the model downloader's four-gigabyte reserve is for models.
            allowLowDiskSpace: true)
        do {
            try await ModelDownloader.download(remote)
        } catch ModelDownloadError.invalidChecksum, ModelDownloadError.invalidSize {
            try? fileManager.removeItem(at: archive)
            throw Failure.damaged
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.couldNotFetch
        }
        defer { try? fileManager.removeItem(at: archive) }

        // `tar` ships with macOS. Unpacked into the staging folder, then the one executable
        // is picked out wherever the archive put it.
        guard try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", staging.path], timeout: commandTimeout).status == 0,
              let found = findExecutable(named: "gws", under: staging)
        else { throw Failure.damaged }

        let final = root.appendingPathComponent(version, isDirectory: true)
        let packed = staging.appendingPathComponent("ready", isDirectory: true)
        try fileManager.createDirectory(at: packed, withIntermediateDirectories: true)
        let target = packed.appendingPathComponent("gws")
        try fileManager.moveItem(at: found, to: target)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)

        let check = try await run(target.path, ["--version"], timeout: commandTimeout)
        guard check.status == 0, check.output.contains(version) else { throw Failure.wouldNotRun }

        let binaryHash = digest(try Data(contentsOf: target, options: .mappedIfSafe))
        let verification = Verification(archiveSHA256: asset.sha256, executableSHA256: binaryHash)
        try JSONEncoder().encode(verification).write(to: packed.appendingPathComponent("verified.json"), options: .atomic)
        try? fileManager.removeItem(at: final)
        try fileManager.moveItem(at: packed, to: final)
        // Older pinned versions are left behind by an upgrade; one copy is enough.
        for entry in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        where entry != version && !entry.contains(".staging-") && entry.first?.isNumber == true {
            try? fileManager.removeItem(at: root.appendingPathComponent(entry))
        }
        return final.appendingPathComponent("gws")
    }

    private static func findExecutable(named name: String, under directory: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == name {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { return url }
        }
        return nil
    }

    /// How long unpacking or the `--version` check may take. Both answer in well under a
    /// second; a program that has not answered in this time is wedged, and an install that
    /// waited for it would leave "Getting ready" on screen for ever.
    static let runTimeout: TimeInterval = 30

    private static func run(
        _ path: String, _ arguments: [String], timeout: TimeInterval = runTimeout
    ) async throws -> (status: Int32, output: String) {
        do {
            let result = try await GoogleWorkspaceCLI.spawn(executable: URL(fileURLWithPath: path),
                arguments: arguments, timeout: timeout)
            return (result.exitCode, result.text)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Failure.wouldNotRun }

    }
}
