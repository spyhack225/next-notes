import Foundation

/// `--selftest-imessage-authority` — IM-12: a remote turn is the same authority as
/// a local one and gets a smaller budget.
///
/// No grant, no pairing, no model and no live database: every case calls the
/// broker or the pure policy with constructed tools, plus a temp settings dir
/// for the suspension and pairing gates. The final line is
/// `IMESSAGE_AUTHORITY_OK: <n> cases`; per-case lines are
/// `IMESSAGE_AUTHORITY_WRONG: …`, which is not a verdict token.
enum IMessageAuthoritySelfTest {
    static func run() async -> String {
        var failures: [String] = []
        var caseCount = 0

        func check(_ name: String, _ body: () async throws -> String?) async rethrows {
            caseCount += 1
            do {
                if let problem = try await body() { failures.append("\(name): \(problem)") }
            } catch {
                failures.append("\(name): threw \(error)")
            }
        }

        func tool(id: String, namespace: AgentToolNamespace, risk: AgentRisk) -> AgentTool {
            AgentTool(id: id, namespace: namespace, name: id, description: "authority-suite stand-in",
                      parameters: [], risk: risk, source: .native, executionMode: .immediate,
                      titleBuilder: { _ in id }, previewBuilder: nil)
        }
        let remote = ActionOriginContext(transport: .iMessage)
        let policy = PermissionPolicy()

        // 1–4. Each band's representative gets its decision from a remote origin.
        await check("band1_read_auto_allows") {
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "search_email", namespace: .workspace, risk: .read),
                arguments: [:], policy: policy, origin: remote)
            guard decision == .allow else { return "a remote read was \(decision)" }
            return nil
        }
        await check("band2_send_asks_in_channel") {
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "send_email", namespace: .workspace, risk: .send),
                arguments: [:], policy: policy, origin: remote)
            guard case .ask = decision else { return "a remote send was \(decision), not .ask" }
            return nil
        }
        await check("band3_destructive_asks_local") {
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "computer.delete", namespace: .computer, risk: .destructive),
                arguments: [:], policy: policy, origin: remote)
            guard case .askLocal = decision else { return "a remote delete was \(decision), not .askLocal" }
            return nil
        }
        await check("band4_privileged_denies") {
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "computer.install", namespace: .computer, risk: .privileged),
                arguments: [:], policy: policy, origin: remote)
            guard case .deny = decision else { return "a remote privileged tool was \(decision), not .deny" }
            return nil
        }

        // 5. `sudo` through the shell is denied remotely, whatever the grant says.
        await check("band4_sudo_denies") {
            var granted = policy
            granted.grants = [PermissionGrant(toolID: "run", duration: .alwaysThisAction)]
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "run", namespace: .shell, risk: .modify),
                arguments: ["command": "sudo rm -rf /"], policy: granted, origin: remote)
            guard case .deny = decision else { return "a remote sudo was \(decision), not .deny" }
            return nil
        }

        // 6. A remote origin cannot raise authority: a standing grant covers the
        // local turn and does not cover the remote one.
        await check("remote_origin_never_rides_a_grant") {
            var granted = policy
            granted.grants = [PermissionGrant(toolID: "send_email", duration: .alwaysThisAction)]
            let local = await PermissionBroker.shared.authorize(
                tool(id: "send_email", namespace: .workspace, risk: .send),
                arguments: [:], policy: granted, origin: nil)
            guard local == .allow else { return "the local granted turn was \(local), not .allow" }
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "send_email", namespace: .workspace, risk: .send),
                arguments: [:], policy: granted, origin: remote)
            guard case .ask = decision else { return "the remote granted turn was \(decision), not .ask" }
            return nil
        }

        // 7. A remote turn may not carry review or unattended authority.
        await check("remote_origin_cannot_carry_review_authority") {
            let decision = await PermissionBroker.shared.authorize(
                tool(id: "memory.remember", namespace: .memory, risk: .modify),
                arguments: [:], policy: policy, authority: .memoryReview, origin: remote)
            guard case .deny = decision else { return "a remote review authority was \(decision), not .deny" }
            return nil
        }

        // 8. Suspended: even band-1 reads are denied remotely with the Mac path,
        // while local turns are unaffected.
        await check("suspension_denies_remote_spares_local") {
            let denied = await PermissionBroker.shared.authorize(
                tool(id: "search_email", namespace: .workspace, risk: .read),
                arguments: [:], policy: policy, origin: remote, remoteAccessSuspended: true)
            guard case .deny(let reason) = denied, reason.contains("Settings on your Mac") else {
                return "a suspended remote read was \(denied)"
            }
            let local = await PermissionBroker.shared.authorize(
                tool(id: "search_email", namespace: .workspace, risk: .read),
                arguments: [:], policy: policy, origin: nil)
            guard local == .allow else { return "suspension leaked into a local read: \(local)" }
            return nil
        }

        // 9. Re-pairing is a local act: the gate refuses a remote origin, and the
        // pairing service refuses input while pairing mode is closed (the mechanism
        // by which a remote "Hi Next" fails).
        await check("re_pairing_needs_the_mac") {
            let remoteOrigin = ActionOriginContext(
                transport: .iMessage,
                remoteIdentity: RemoteIdentity(raw: "+15550000000"),
                chatGUID: "iMessage;-;+15550000000")
            guard !RemoteAccessPolicy.mayEnterPairing(origin: remoteOrigin) else {
                return "a remote origin may enter pairing"
            }
            guard RemoteAccessPolicy.mayEnterPairing(origin: nil) else {
                return "a local process may not enter pairing"
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-authority-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let pairing = SelfChannelPairing(store: RemoteIdentityStore(directory: dir),
                                             watermark: MessagesWatermark())
            let refused = await pairing.handle(input: PairingInput(
                rowID: 99, text: "Hi Next",
                chatGUID: "iMessage;-;+15550000000", senderHandle: "+15550000000"))
            return refused ? "a pairing message outside pairing mode paired" : nil
        }

        // 10. The six persisted authorities still decode from the previous build's
        // strings: adding context beside `ActionAuthority` changed no encoding.
        await check("authority_decode_compatibility") {
            let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
            let pairs: [(String, ActionAuthority)] = [
                ("\"user\"", .user),
                ("\"otherParticipant\"", .otherParticipant),
                ("\"systemDerived\"", .systemDerived),
                ("\"background\"", .background),
                ("\"memoryReview\"", .memoryReview),
                ("\"scheduled:\(id.uuidString)\"", .scheduled(id)),
            ]
            for (json, expect) in pairs {
                guard let data = json.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(ActionAuthority.self, from: data),
                      decoded == expect else {
                    return "\(json) no longer decodes"
                }
            }
            return nil
        }

        // 11. The sudo predicate: root asks, lookalikes do not.
        await check("sudo_predicate") {
            guard RemoteAccessPolicy.isSudoCommand("sudo rm -rf /") else { return "missed sudo" }
            guard RemoteAccessPolicy.isSudoCommand("/usr/bin/sudo x") else { return "missed pathed sudo" }
            guard !RemoteAccessPolicy.isSudoCommand("echo sudo") else { return "matched trailing sudo" }
            guard !RemoteAccessPolicy.isSudoCommand("") else { return "matched empty" }
            return nil
        }

        var lines = failures.map { "IMESSAGE_AUTHORITY_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_AUTHORITY_OK: \(caseCount) cases"
            : "IMESSAGE_AUTHORITY_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}
