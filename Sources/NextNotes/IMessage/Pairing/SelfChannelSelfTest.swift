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

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
}

/// A thread-safe counter for the self-test's confirmation send.
private actor SendCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
