import Foundation

/// IM-07's self-test: `--selftest-imessage-pairing`.
///
/// **Red-first, and the reason is the same as every other self-test in this feature.**
/// A self-test that passes on the first run proves nothing — it might be asserting
/// something that is already true, or not asserting the thing that matters.
///
/// The final line is `IMESSAGE_PAIRING_OK: <n> cases` or `IMESSAGE_PAIRING_FAILED: <case>: <detail>`.
@MainActor
enum SelfChannelSelfTest {
    /// The harness-isolated directory, following `MessagesDatabaseSelfTest`'s pattern.
    private static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-imessage-pairing-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
    }

    static func run() async -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ condition: Bool, _ detail: String) {
            caseCount += 1
            if !condition { failures.append("\(name): \(detail)") }
        }

        let persistence = storePersistenceProblems()
        failures += persistence.failures
        caseCount += persistence.cases
        if !failures.isEmpty || CommandLine.arguments.contains("--imessage-store-persistence") {
            var lines = failures.map { "IMESSAGE_PAIRING_WRONG: \($0)" }
            lines.append(failures.isEmpty
                ? "IMESSAGE_PAIRING_OK: \(caseCount) cases"
                : "IMESSAGE_PAIRING_FAILED: \(failures.count) persistence checks; \(failures[0])")
            return lines.joined(separator: "\n")
        }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // MARK: - The pure decision

        let match = SelfChannel.decide(
            text: "Hi Next", rowID: 100, chatGUID: "iMessage;-;+15551234567",
            pairingStartRowID: 50)
        check("a matching row inside the window is accepted", match == .matches, "got \(match)")

        let boundary = SelfChannel.decide(
            text: "Hi Next", rowID: 50, chatGUID: "iMessage;-;+15551234567",
            pairingStartRowID: 50)
        check("a row at the boundary is refused (exclusive)", boundary == .outsideWindow, "got \(boundary)")

        let before = SelfChannel.decide(
            text: "Hi Next", rowID: 49, chatGUID: "iMessage;-;+15551234567",
            pairingStartRowID: 50)
        check("a row before the window is refused", before == .outsideWindow, "got \(before)")

        let wrongText = SelfChannel.decide(
            text: "Hello", rowID: 100, chatGUID: "iMessage;-;+15551234567",
            pairingStartRowID: 50)
        check("the wrong text is refused", wrongText == .wrongText, "got \(wrongText)")

        let group = SelfChannel.decide(
            text: "Hi Next", rowID: 100, chatGUID: "iMessage;+;opaque-group-id",
            pairingStartRowID: 50)
        check("a group chat is refused in V1", group == .groupChat, "got \(group)")

        let unrecognised = SelfChannel.decide(
            text: "Hi Next", rowID: 100, chatGUID: "unknown-shape",
            pairingStartRowID: 50)
        check("an unrecognised chat shape is refused", unrecognised == .unrecognisedChat, "got \(unrecognised)")

        let nilText = SelfChannel.decide(
            text: nil, rowID: 100, chatGUID: "iMessage;-;+15551234567",
            pairingStartRowID: 50)
        check("nil text is refused", nilText == .wrongText, "got \(nilText)")

        // MARK: - The store round-trip

        let store = RemoteIdentityStore(directory: directory)
        let original = store.configuration
        try? store.update { config in
            config.enabled = true
            config.pairedChatGUID = "iMessage;-;+15551234567"
            config.pairedAt = 1_700_000_000
            config.localIdentity = "+15551234567"
            config.remotePolicyVersion = 1
            config.chatHandleCache = "+15551234567"
            config.lastInboundCommandAt = 1_700_000_100
        }
        let roundTripped = store.configuration
        check("the settings file round-trips",
              roundTripped.enabled == true
              && roundTripped.pairedChatGUID == "iMessage;-;+15551234567"
              && roundTripped.pairedAt == 1_700_000_000
              && roundTripped.localIdentity == "+15551234567"
              && roundTripped.chatHandleCache == "+15551234567"
              && roundTripped.lastInboundCommandAt == 1_700_000_100,
              "round-trip lost fields")

        try? store.update { $0 = original }

        // MARK: - Decoding an older shape

        let oldShape = """
        {"enabled":true,"pairedChatGUID":"iMessage;-;+15551234567"}
        """
        let oldData = oldShape.data(using: .utf8)!
        let realFile = store.fileURL
        let backup = try? Data(contentsOf: realFile)
        try? oldData.write(to: realFile)
        let decoded = RemoteIdentityStore(directory: directory).configuration
        check("a settings file without the new keys decodes with defaults",
              decoded.enabled == true
              && decoded.pairedChatGUID == "iMessage;-;+15551234567"
              && decoded.pairedAt == nil
              && decoded.localIdentity == nil
              && decoded.lastProcessedRowID == 0
              && decoded.remotePolicyVersion == 1,
              "decoded with wrong defaults")
        if let backup { try? backup.write(to: realFile) }

        // MARK: - The service

        let serviceStore = RemoteIdentityStore(directory: directory)
        let watermark = MessagesWatermark()
        let counter = SendCounter()
        let service = SelfChannelPairing(store: serviceStore, watermark: watermark) {
            await counter.increment()
            return true
        }

        let entered = await service.enterPairingMode()
        check("pairing mode is entered", entered, "enterPairingMode returned \(entered)")
        check("pairing mode is active", await service.isPairingActive, "isPairingActive is false")

        let second = await service.enterPairingMode()
        check("a second pairing attempt is refused", !second, "second enterPairingMode returned \(second)")

        let notMatch = await service.handle(input: PairingInput(
            rowID: 100, text: "Hello",
            chatGUID: "iMessage;-;+15551234567", senderHandle: "+15551234567"))
        check("a non-matching row is not a pairing message", !notMatch, "handle returned \(notMatch)")

        let matched = await service.handle(input: PairingInput(
            rowID: 101, text: "Hi Next",
            chatGUID: "iMessage;-;+15551234567", senderHandle: "+15551234567"))
        check("a matching row pairs and sends", matched, "handle returned \(matched)")
        check("the confirmation was sent", await counter.count == 1, "count is \(await counter.count)")
        check("the confirmation was observed", await service.isConfirmationObserved, "isConfirmationObserved is false")

        let paired = serviceStore.configuration
        check("the pairing was persisted",
              paired.enabled && paired.pairedChatGUID == "iMessage;-;+15551234567"
              && paired.localIdentity == "+15551234567",
              "pairing not persisted")

        await service.cancelPairing()
        check("cancelling pairing clears the window", !(await service.isPairingActive), "isPairingActive is still true")

        return failures.isEmpty
            ? "IMESSAGE_PAIRING_OK: \(caseCount) cases"
            : "IMESSAGE_PAIRING_FAILED: \(failures[0])"
    }

    /// Real store writes on isolated authored fixtures. Failure checks never start a
    /// thread that could remain stuck on the original leaked lock.
    private static func storePersistenceProblems() -> (cases: Int, failures: [String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-imessage-store-" + UUID().uuidString,
                                    isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        var cases = 0
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            cases += 1
            if !condition { failures.append(name) }
        }
        var baseline = IMessageConfiguration()
        baseline.enabled = true
        baseline.pairedChatGUID = "iMessage;-;+15551234567"
        baseline.localIdentity = "+15551234567"
        baseline.chatHandleCache = "+15551234567"
        baseline.lastProcessedRowID = 42
        baseline.pairedAt = 1_700_000_000
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let firstDirectory = root.appendingPathComponent("first")
            let first = RemoteIdentityStore(directory: firstDirectory)
            var firstThrew = false
            do { try first.update { $0 = baseline } } catch { firstThrew = true }
            check("first save succeeds without an existing settings file", !firstThrew)
            let firstSnapshot = first.configurationWithoutBlockingForTesting()
            check("first save releases its actual lock", firstSnapshot != nil)
            check("first save publishes exact settings in memory", firstSnapshot == baseline)
            check("fresh reader consumes exact first-save settings",
                  RemoteIdentityStore(directory: firstDirectory).configuration == baseline)
            if firstSnapshot != nil {
                check("ordinary configuration consumer receives first-save settings",
                      first.configuration == baseline)
                try first.update { _ in }
                check("unchanged update releases its actual lock",
                      first.configurationWithoutBlockingForTesting() == baseline)
            }

            // Seed valid prior bytes without relying on the broken first-write path.
            for failure in ["encoding", "directory", "destination"] {
                let fixture = root.appendingPathComponent(failure, isDirectory: true)
                try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
                let file = fixture.appendingPathComponent(RemoteIdentityStore.fileName)
                let bytes = try JSONEncoder().encode(baseline)
                try bytes.write(to: file, options: .atomic)
                let store = RemoteIdentityStore(directory: fixture)
                var retainedFile = file
                if failure == "directory" {
                    let retainedDirectory = root.appendingPathComponent("retained-directory")
                    try fm.moveItem(at: fixture, to: retainedDirectory)
                    try Data("blocked directory".utf8).write(to: fixture)
                    retainedFile = retainedDirectory.appendingPathComponent(RemoteIdentityStore.fileName)
                } else if failure == "destination" {
                    retainedFile = fixture.appendingPathComponent("retained-settings.json")
                    try fm.moveItem(at: file, to: retainedFile)
                    try fm.createDirectory(at: file, withIntermediateDirectories: true)
                    try Data("occupied destination".utf8).write(to: file.appendingPathComponent("child"))
                }
                var threw = false
                do {
                    try store.update {
                        $0.remoteAccessSuspended = true
                        if failure == "encoding" { $0.pairedAt = Double.nan }
                    }
                } catch { threw = true }
                check("\(failure) failure is reported", threw)
                let snapshot = store.configurationWithoutBlockingForTesting()
                check("\(failure) failure releases the same store lock", snapshot != nil)
                check("\(failure) failure retains exact in-memory settings", snapshot == baseline)
                check("\(failure) failure retains exact prior disk bytes",
                      (try? Data(contentsOf: retainedFile)) == bytes)
                // Recover the authored filesystem obstacle. Never retry a locked old
                // store: its missing unlock is already an explicit failed assertion.
                if failure == "directory" {
                    try fm.removeItem(at: fixture)
                    try fm.moveItem(at: retainedFile.deletingLastPathComponent(), to: fixture)
                } else if failure == "destination" {
                    try fm.removeItem(at: file)
                    try fm.moveItem(at: retainedFile, to: file)
                }
                if snapshot != nil {
                    check("\(failure) ordinary reader preserves the previous configuration",
                          store.configuration == baseline)
                    var updated = baseline
                    updated.remoteAccessSuspended = true
                    try store.suspendRemoteAccess()
                    check("\(failure) same-store retry publishes the requested change",
                          store.configurationWithoutBlockingForTesting() == updated)
                    check("\(failure) retry reaches the normal fresh-reader consumer",
                          RemoteIdentityStore(directory: fixture).configuration == updated)
                    try store.resumeRemoteAccessLocally()
                    check("\(failure) later local resume retains all other settings",
                          store.configurationWithoutBlockingForTesting() == baseline)
                }
            }
        } catch {
            failures.append("isolated persistence fixture setup or recovery failed")
        }
        return (cases, failures)
    }
}

/// A thread-safe counter for the self-test's confirmation send.
private actor SendCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
