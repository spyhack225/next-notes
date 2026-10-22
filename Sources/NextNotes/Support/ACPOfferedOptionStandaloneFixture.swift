import AppKit
import Foundation

/// COMMON exact isolated diagnostic entry; no normal AppDelegate or SwiftUI scenes.
/// Actual Gate/Island/context defaults use the same confined MeetingStore singleton.
@MainActor
enum ACPOfferedOptionStandaloneFixture {
    private enum InputError: Error { case unsafe }
    private static var admittedRoot: URL?

    static func runStandalone() {
        guard SelfTest.requested == "--selftest-acp-offered-options" else { exit(1) }
        let root: URL
        do { root = try validateArguments() }
        catch {
            // Refuse before any supplied-output write, Gate, or meeting owner.
            print("ACP_OFFERED_OPTIONS_INVALID: confined diagnostic arguments unavailable")
            exit(1)
        }
        admittedRoot = root
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = FixtureDelegate(root: root)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    static func isolatedMeetingStore() -> MeetingStore {
        guard SelfTest.requested == "--selftest-acp-offered-options", admittedRoot != nil else {
            preconditionFailure("Offered-options entry was not admitted")
        }
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(
                "NextNotesMeetingResumeTest-\(UUID().uuidString)", isDirectory: true)
        guard let store = try? MeetingStore.isolated(at: root) else {
            preconditionFailure("Offered-options temporary store unavailable")
        }
        return store
    }

    private static func validateArguments() throws -> URL {
        let args = Array(CommandLine.arguments.dropFirst())
        var flags = 0
        var output: String?
        var timeout: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--selftest-acp-offered-options": flags += 1
            case SelfTest.outputFlag, SelfTest.timeoutFlag:
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("-") else {
                    throw InputError.unsafe
                }
                if args[index] == SelfTest.outputFlag {
                    guard output == nil else { throw InputError.unsafe }
                    output = args[index + 1]
                } else {
                    guard timeout == nil, let seconds = Double(args[index + 1]),
                          seconds.isFinite, seconds > 0 else { throw InputError.unsafe }
                    timeout = args[index + 1]
                }
                index += 1
            default: throw InputError.unsafe
            }
            index += 1
        }
        guard flags == 1, let output, !output.isEmpty else { throw InputError.unsafe }
        let file = URL(fileURLWithPath: output).standardizedFileURL
        let root = file.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = "NextNotesACPOptionsTest-"
        // Canonical path identity, not Foundation URL trailing-slash spelling.
        guard file.isFileURL, file.resolvingSymlinksInPath().path == file.path,
              root.resolvingSymlinksInPath().path == root.path,
              root.deletingLastPathComponent().path == temporary.path,
              root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              file.lastPathComponent == "selftest.log",
              !FileManager.default.fileExists(atPath: file.path),
              SelfTest.outputPath == output else { throw InputError.unsafe }
        if FileManager.default.fileExists(atPath: root.path) {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw InputError.unsafe
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        return root
    }

    @MainActor
    private final class FixtureDelegate: NSObject, NSApplicationDelegate {
        let root: URL
        private var fixtureTask: Task<Void, Never>?
        init(root: URL) { self.root = root }

        func applicationDidFinishLaunching(_ notification: Notification) {
            fixtureTask = Task { @MainActor in
                var checks = 0
                var failures: [String] = []
                do {
                    try await ACPSessionOfferedOptionSelfTest.originalCases(root: root) { condition, label in
                        checks += 1
                        if !condition { failures.append(label) }
                    }
                    for failure in failures { SelfTest.diagnostic("ACP_OFFER_WRONG: " + failure) }
                    SelfTest.failed = !failures.isEmpty
                    SelfTest.diagnostic(failures.isEmpty
                        ? "ACP_OFFERED_OPTIONS_OK: \(checks) checks"
                        : "ACP_OFFERED_OPTIONS_FAILED: \(failures.count)/\(checks)")
                } catch {
                    SelfTest.failed = true
                    SelfTest.diagnostic("ACP_OFFERED_OPTIONS_INVALID: fixture controls unavailable")
                }
                // Cocoa quit is scheduled after this Swift task yields (132 producer fix).
                SelfTest.requestTermination()
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            exit(SelfTest.failed ? 1 : 0)
        }
    }
}
