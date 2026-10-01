import Foundation

/// `--selftest-imessage-approval` — IM-13: one exact action, once, payload frozen.
///
/// No grant, no pairing, no model and no live database: offers live in the
/// matcher under test, the clock is injected, and firing answers through a
/// fake. The final line is `IMESSAGE_APPROVAL_OK: <n> cases`; per-case lines are
/// `IMESSAGE_APPROVAL_WRONG: …`, which is not a verdict token.
enum IMessageApprovalSelfTest {
    static let pairedChat = "iMessage;-;+15550000000"

    static func made(
        id: String = UUID().uuidString,
        kind: RemoteActionKind = .sendMessage,
        title: String = "Ready to send",
        payload: Data = Data("frozen".utf8),
        chatGUID: String = pairedChat,
        expiresAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> RemotePreparedAction {
        RemotePreparedAction(
            actionID: id, kind: kind, title: title, payload: payload,
            payloadSummary: ["one summary line"],
            offeredOn: RemoteOffer(chatGUID: chatGUID, messageGUID: "message-1"),
            expiresAt: expiresAt, decidedAt: nil, decision: nil)
    }

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

        let now = Date(timeIntervalSince1970: 1_799_999_000)

        // 1. One pending approval answers "send" with the frozen payload: the bytes
        // that fire are the bytes that were offered, the decision is stamped, and a
        // second "send" meets no offer and clarifies.
        await check("approve_single_fires_frozen_payload") {
            let matcher = RemoteApprovalMatcher()
            let offered = made()
            await matcher.offer(offered)
            let answer = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .approved(let decided) = answer else {
                return "a single pending approval did not approve"
            }
            guard decided.payload == offered.payload else {
                return "the approved payload is not the offered payload"
            }
            guard decided.decision == .approve, decided.decidedAt == now else {
                return "the approval is unstamped"
            }
            guard await matcher.outstanding.isEmpty else {
                return "the decided offer is still pending"
            }
            let again = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                             pairedChatGUID: pairedChat, now: now)
            guard case .clarify = again else {
                return "a second send did not clarify"
            }
            return nil
        }

        // 2. An expired offer is pruned: "send" clarifies rather than approving.
        await check("expired_offer_clarifies") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made(expiresAt: now.addingTimeInterval(-1)))
            let answer = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .clarify = answer else {
                return "an expired offer answered \(answer)"
            }
            guard await matcher.outstanding.isEmpty else {
                return "the expired offer was not pruned"
            }
            return nil
        }

        // 3. A bare keyword with nothing pending is a clarification, not a send.
        await check("bare_keyword_without_pending_clarifies") {
            let matcher = RemoteApprovalMatcher()
            let answer = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .clarify = answer else {
                return "a bare send did not clarify"
            }
            return nil
        }

        // 4. Ordinary text is a normal turn, never an approval.
        await check("ordinary_text_is_not_an_approval") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made())
            let answer = await matcher.decide(reply: "looks good, thanks", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .none = answer else {
                return "a sentence answered as an approval"
            }
            guard await matcher.outstanding.count == 1 else {
                return "the offer was consumed by a sentence"
            }
            return nil
        }

        // 5. A keyword from an unpaired chat approves nothing — it is not even
        // answered.
        await check("unpaired_chat_approves_nothing") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made())
            let answer = await matcher.decide(reply: "send", chatGUID: "iMessage;-;+15550009999",
                                              pairedChatGUID: pairedChat, now: now)
            guard case .none = answer else {
                return "a stranger's chat approved"
            }
            return nil
        }

        // 6. An offer on another chat is not approved by this chat's reply.
        await check("approval_stays_on_its_chat") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made(chatGUID: "iMessage;-;+15550009999"))
            let answer = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .clarify = answer else {
                return "a reply approved another chat's offer"
            }
            return nil
        }

        // 7. "cancel" cancels one pending offer and removes it.
        await check("cancel_cancels_one") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made())
            let answer = await matcher.decide(reply: "cancel", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .cancelled(let decided) = answer, decided.decision == .cancel else {
                return "a cancel did not cancel"
            }
            guard await matcher.outstanding.isEmpty else {
                return "the cancelled offer is still pending"
            }
            return nil
        }

        // 8. Two pending approvals and "send" clarifies — it must not approve the
        // newer action, and neither offer is consumed.
        await check("two_pending_clarifies") {
            let matcher = RemoteApprovalMatcher()
            await matcher.offer(made(title: "First"))
            await matcher.offer(made(title: "Second"))
            let answer = await matcher.decide(reply: "send", chatGUID: pairedChat,
                                              pairedChatGUID: pairedChat, now: now)
            guard case .clarify = answer else {
                return "two pending approvals did not clarify"
            }
            guard await matcher.outstanding.count == 2 else {
                return "clarifying consumed an offer"
            }
            return nil
        }

        // 9. What fires equals the payload byte for byte, through the injected
        // delivery. Anything else answers `.unsupported`, never a fake execution.
        await check("fired_payload_equals_payload") {
            let offered = made()
            var captured: Data? = nil
            let result = await RemoteActionFirer.fire(
                RemotePreparedAction(actionID: offered.actionID, kind: offered.kind,
                                     title: offered.title, payload: offered.payload,
                                     payloadSummary: offered.payloadSummary,
                                     offeredOn: offered.offeredOn, expiresAt: offered.expiresAt,
                                     decidedAt: now, decision: .approve)) {
                captured = $0
                return true
            }
            guard case .fired(let bytes) = result, bytes == offered.payload,
                  captured == offered.payload else {
                return "the fired bytes are not the offered bytes"
            }
            let unsupported = await RemoteActionFirer.fire(
                RemotePreparedAction(actionID: offered.actionID, kind: .email,
                                     title: offered.title, payload: offered.payload,
                                     payloadSummary: offered.payloadSummary,
                                     offeredOn: offered.offeredOn, expiresAt: offered.expiresAt,
                                     decidedAt: now, decision: .approve)) { _ in true }
            guard case .unsupported = unsupported else {
                return "an email kind fired without a firer"
            }
            return nil
        }

        // 10. The receipt attaches to the action: the approval id and the content
        // hash travel in the frozen intent, and a delivered send completes.
        await check("receipt_attaches_to_action") {
            let digest = OutboundDigest.text("frozen-body")
            let actionID = UUID().uuidString
            let intent = ActionIntent(
                source: .agent, authority: .user, verb: "send", target: "self-conversation",
                arguments: ["approvalID": actionID,
                            "textHash": IMessageActionVerifier.hex(digest)],
                risk: .send)
            let receipt = IMessageActionVerifier.receipt(
                verification: .delivered(messageGUID: "message-9"),
                intent: intent, actionID: UUID(uuidString: actionID)!)
            guard receipt.status == .completed else {
                return "a delivered approval receipted as \(receipt.status)"
            }
            guard receipt.intent.arguments["approvalID"] == actionID,
                  receipt.intent.arguments["textHash"] == IMessageActionVerifier.hex(digest) else {
                return "the receipt lost the approval linkage"
            }
            return nil
        }

        // 11. The `.phoneCall` kind is declared (Phone-Calls reuses this type) and
        // the whole action round-trips through `Codable`.
        await check("phone_call_declared_and_codable") {
            let action = made(kind: .phoneCall(PhoneCallRequest(recipient: "+15550000001", topic: nil)))
            guard let data = try? JSONEncoder().encode(action),
                  let back = try? JSONDecoder().decode(RemotePreparedAction.self, from: data),
                  back == action else {
                return "a phoneCall action did not round-trip"
            }
            return nil
        }

        // 12. The offer card wears the runtime name — never a hardcoded one — with
        // the title and the exact reply words.
        await check("offer_card_names_runtime_agent") {
            let text = RemoteApprovalOffer.text(for: made(title: "Ready to test"), agentName: "Will")
            guard text.hasPrefix("Will · ") else {
                return "the offer does not open with the agent's name"
            }
            guard text.contains("Ready to test"), text.contains("send"), text.contains("cancel") else {
                return "the offer lost its title or reply words"
            }
            return nil
        }

        var lines = failures.map { "IMESSAGE_APPROVAL_WRONG: \($0)" }
        lines.append(failures.isEmpty
            ? "IMESSAGE_APPROVAL_OK: \(caseCount) cases"
            : "IMESSAGE_APPROVAL_FAILED: \(failures[0])")
        return lines.joined(separator: "\n")
    }
}
