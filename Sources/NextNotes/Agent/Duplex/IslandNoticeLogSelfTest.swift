import Foundation

/// Capture exactly the operand produced at the existing public notice-log boundary.
/// No OS log scan, owner payload, grant, native output or display-frame claim.
@MainActor
enum IslandNoticeLogSelfTest {
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              !AgentCaptureController.shared.isSessionActive, PermissionGate.shared.pending == nil else {
            return (0, ["notice log: INVALID existing foreground owner"])
        }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temporary.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["notice log: INVALID root"]) }
        let owner = SelfTestStoreGuard.take()
        let island = IslandState.shared
        var produced: [String] = []
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("notice log: " + label) } }
        defer {
            _ = island.installNoticeLogForTesting(nil, root: root)
            island.apply(.hidden)
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard island.installNoticeLogForTesting({ produced.append($0) }, root: root) else {
                return (0, ["notice log: INVALID guarded capture installation"])
            }
            let sentinel = "Owned private notice sentinel 74291."
            island.showAgentReply(sentinel)
            check(produced.count == 1, "C01 actual reply push did not emit exactly once")
            check(island.kind == .agentReply(sentinel), "C02 actual presentation lost its authored reply")
            check(produced.first == "agentReply" && produced.first?.contains(sentinel) == false,
                "F01 public reply logger emitted associated result payload")
            let proposal = IslandProposal(id: "owned-private-proposal-74291", title: sentinel,
                detail: sentinel, meetingID: nil)
            island.propose(proposal)
            check(produced.count == 2, "C03 actual proposal push did not emit exactly once")
            check(island.kind == .agentProposal(proposal), "C04 actual presentation lost its authored proposal")
            check(produced.last == "agentProposal" && produced.last?.contains(sentinel) == false
                && produced.last?.contains(proposal.id) == false,
                "F02 public proposal logger emitted associated text or identity")
            check(island.installNoticeLogForTesting(nil, root: root), "C05 owned log capture failed to retire")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C06 actual authored logger fixture changed owner store/defaults")
        } catch { failures.append("notice log: INVALID \(error)") }
        return (checks, failures)
    }
}
