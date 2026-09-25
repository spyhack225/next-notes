import CryptoKit
import Foundation

/// P0-11's snapshot of the owner's real stores, taken before and after a harness run.
///
/// `--selftest-store-isolation` compares two of these. It reads and never writes: the
/// point is to prove a self-test left every file and preference alone. Paths are built
/// exactly the way the stores build them, so a store that moves its file moves this
/// with it rather than silently dropping out of the check.
enum SelfTestStoreGuard {
    /// Files are `"size|mtime|sha256"`, not existence alone: a store's atomic write
    /// replaces a file with the same size inside the same second often enough that
    /// either signal alone would miss it. `"absent"` is a value, so a file that
    /// *appears* during a run is a difference too.
    struct StoreSnapshot: Equatable {
        var files: [String: String] = [:]
        var defaults: [String: String] = [:]
    }

    /// Every file a self-test must leave alone. `Models/library.json` is the one under
    /// a subdirectory; the rest live at the root of the support directory. `usage.jsonl`
    /// joined the list with P0-20e: the harness's `UsageLog.shared` writes to a temp
    /// directory, so a run that ever reached the owner's history would fail here.
    static let fileNames: [String] = [
        "runs.jsonl",
        "agent-tasks.json",
        "agent-audit.jsonl",
        "agent-conversation.json",
        "next-memory.json",
        "agent-memory-review.json",
        "metrics.jsonl",
        "usage.jsonl",
        "action-receipts.json",
        "permission-grants.json",
        "persona.md",
        "agent-identity.json",
        "portrait-insights.json",
    ]

    /// The owner's real stores, right now.
    static func take() -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        let support = AppIdentity.applicationSupportDirectory
        for name in fileNames {
            snapshot.files[name] = describe(support.appendingPathComponent(name))
        }
        snapshot.files["Models/library.json"] =
            describe(ModelSpec.directory.appendingPathComponent("library.json"))
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix("modelRoles.")
            || key.hasPrefix("modelLibrary.")
            || key.hasPrefix("agent") {
            snapshot.defaults[key] = canonical(value)
        }
        return snapshot
    }

    /// Every difference, the owner's defaults first and each group sorted — the keys
    /// are what the harness writes, and `dictionaryRepresentation()` has no order of
    /// its own, so a report has to be readable twice.
    static func diff(_ before: StoreSnapshot, _ after: StoreSnapshot) -> [String] {
        var changes: [String] = []
        for key in Set(before.defaults.keys).union(after.defaults.keys).sorted() {
            guard before.defaults[key] != after.defaults[key] else { continue }
            if before.defaults[key] == nil {
                changes.append("\(key) appeared")
            } else if after.defaults[key] == nil {
                changes.append("\(key) disappeared")
            } else {
                changes.append("\(key) changed")
            }
        }
        for name in Set(before.files.keys).union(after.files.keys).sorted() {
            guard before.files[name] != after.files[name] else { continue }
            switch (before.files[name], after.files[name]) {
            case (nil, .some(let value)): changes.append("\(name) appeared (\(value))")
            case (.some(let value), nil): changes.append("\(name) disappeared (was \(value))")
            default: changes.append("\(name) changed")
            }
        }
        return changes
    }

    /// `"size|mtime|sha256"`, or `"absent"`. Read through `FileManager` for the
    /// attributes, like `ModelDownloader.fileSize`, so a `URL` instance's cached
    /// `resourceValues` cannot serve a stale answer.
    private static func describe(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "absent" }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)|\(modified)|\(sha256(data))"
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A value as text that does not depend on dictionary iteration order. A stored
    /// table (`modelLibrary.lastUsedAt`, `callAppAnswers`) is a `[String: Any]`, whose
    /// `String(describing:)` order is unspecified; sorting keys here means two
    /// snapshots of the same value are equal strings.
    private static func canonical(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if let text = value as? String { return text }
        if let table = value as? [String: Any] {
            return "{" + table.keys.sorted()
                .map { "\($0)=\(canonical(table[$0]))" }
                .joined(separator: ",") + "}"
        }
        if let list = value as? [Any] {
            return "[" + list.map { canonical($0) }.joined(separator: ",") + "]"
        }
        if let date = value as? Date { return "\(date.timeIntervalSince1970)" }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }
}

/// The `UserDefaults` domain the harness's process-wide stores read and write (P0-11).
///
/// `InstalledModelLibrary.shared` and `ModelRoleStore.shared` are built on this under
/// `SelfTest.isRunning`, so a self-test that drives `.shared` cannot move the owner's
/// `modelLibrary.*` or `modelRoles.*` keys. One suite per process, and its persistent
/// domain is removed on the way out, so nothing outlives the run.
///
/// The two flags that answer a question about the model this Mac actually has selected
/// (`SelfTest.allowsSavedModelSelection`) are the one exception: the selection keys are
/// copied into the suite once, at creation, so those stores still *read* what the owner
/// chose — while every write lands in the suite.
///
/// A type of its own rather than a member of `SelfTestStoreGuard`: the guard reads and
/// compares, and must never write.
@MainActor
enum SelfTestHarnessDefaults {
    /// One harness domain per process, and the same name `ModelOpenFailureStore` already
    /// uses, so a run has one suite rather than one per store.
    nonisolated static let suiteName =
        "NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)"

    static let shared: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return .standard }
        if SelfTest.allowsSavedModelSelection {
            copyOwnerSelection(into: defaults)
        }
        _ = atexit(removeHarnessDefaultsOnExit)
        return defaults
    }()

    /// The keys the two `.shared` stores read. `modelLibrary.openFailures` is deliberately
    /// absent: that table belongs to `ModelOpenFailureStore`, which gets a fresh picture
    /// every run, and inheriting the owner's failures could hide the very model the
    /// read-only flags were launched to exercise.
    private static let copiedLibraryKeys: Set<String> = [
        "modelLibrary.activeAgentModelID",
        "modelLibrary.lastUsedAt",
    ]

    private static func copyOwnerSelection(into defaults: UserDefaults) {
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix("modelRoles.") || copiedLibraryKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
    }
}

/// The suite is not the owner's store, but it is still something the run wrote down.
/// `atexit` is the one hook that covers every harness exit — `NSApp.terminate`, which the
/// self-test flags call, and the watchdog's `exit(1)` — where a termination notification
/// would miss the watchdog. Registered only when the suite was actually created.
private func removeHarnessDefaultsOnExit() {
    UserDefaults.standard.removePersistentDomain(forName: SelfTestHarnessDefaults.suiteName)
}
