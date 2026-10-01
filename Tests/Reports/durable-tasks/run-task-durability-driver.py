#!/usr/bin/env python3
"""Tiny actual-source P6-01/P6-02a fixture; backend/UI collaborators must never run."""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "Sources/NextNotes"
collaborators = '''import Foundation
import OSLog
enum Log { static let app = Logger(subsystem: "fixture.task-durability", category: "test") }
enum AppIdentity {
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NextNotesDurabilityOwnerFixture-\\(UUID().uuidString)")
}
enum ModelSpec { static var directory: URL { AppIdentity.applicationSupportDirectory.appendingPathComponent("Models") } }
enum SelfTest {
    static let isRunning = true
    static let allowsSavedModelSelection = false
    static func diagnostic(_ text: String) { print(text) }
}
enum AgentBackendKind: String { case local, acp }
enum PermissionDuration { case once }
struct PermissionGrant {
    init(toolID: String, duration: PermissionDuration, meetingID: UUID?, taskID: String) {}
}
struct ACPCompatibilityRequest: Sendable { let command: String; let cli: String; let directory: String? }
enum AgentError: Error {
    case acpHandshakeUnavailable(ACPCompatibilityRequest)
    case needsPermission(String)
}
@MainActor enum ACPCompatibilityCLIBackend {
    static func request(for task: AgentTask) -> ACPCompatibilityRequest? { fatalError("fixture must not request backend") }
    static func submit(_ task: AgentTask, explicitApproval: Bool) async throws -> AgentTaskOutcome { fatalError("fixture must not execute backend") }
}
@MainActor final class PermissionGrantStore {
    static let shared = PermissionGrantStore()
    func add(_ grant: PermissionGrant) { fatalError("fixture must not grant permission") }
}
@MainActor final class AgentBackendRegistry {
    static let shared = AgentBackendRegistry()
    func backend(named: String) -> FixtureBackend { fatalError("fixture must not resolve backend") }
}
@MainActor struct FixtureBackend {
    func submit(_ task: AgentTask) async throws -> AgentTaskOutcome { fatalError("fixture must not run backend") }
}
@MainActor final class AgentActivityStore {
    enum Kind { case waiting }
    static let shared = AgentActivityStore()
    func begin(task: AgentTask, title: String) { fatalError("fixture must not begin activity") }
    func finish(taskID: String, title: String) { fatalError("fixture must not finish activity") }
    func update(taskID: String, kind: Kind, title: String, detail: String) { fatalError("fixture must not update activity") }
}
struct IslandProposal { let id: String; let title: String; let detail: String; let meetingID: UUID? }
@MainActor final class IslandState {
    static let shared = IslandState()
    func showBackgroundAgentWork(title: String) { fatalError("fixture must not show work") }
    func showBackgroundAgentReply(_ text: String) { fatalError("fixture must not show reply") }
    func propose(_ proposal: IslandProposal) { fatalError("fixture must not propose") }
}
struct VoiceJob { let id: UUID; let status: String }
@MainActor final class VoiceConversationCoordinator {
    static let shared = VoiceConversationCoordinator()
    var jobs: [VoiceJob] = []
    func cancel(_ id: UUID) { fatalError("fixture must not cancel") }
}
@MainActor enum AgentArtifactLedger {
    static func take(taskID: String) -> [String] { fatalError("fixture must not take artifacts") }
}
@MainActor final class AgentSession {
    static let shared = AgentSession()
    static let backgroundTaskContextKind = "fixture-background"
    func recordAssistant(_ text: String, contextKind: String) { fatalError("fixture must not record conversation") }
}
@MainActor final class AgentAuditLog {
    enum Kind { case reply }
    static let shared = AgentAuditLog()
    func record(kind: Kind, title: String) { fatalError("fixture must not audit") }
}
@MainActor final class VoiceAnnouncementQueue {
    static let shared = VoiceAnnouncementQueue()
    func enqueue(_ text: String) { fatalError("fixture must not speak") }
}
struct AgentTool: Sendable {}
struct AgentToolResult: Sendable {
    let summary: String
    var reference: String? = nil
    var link: URL? = nil
}
struct PermissionPolicy: Sendable {
    static let selfTest = PermissionPolicy()
    static let denyMutations = PermissionPolicy()
}
@MainActor enum AgentToolExecutor {
    typealias FakeToolRun = @MainActor @Sendable (AgentTool, [String: String]) async throws -> AgentToolResult
    static var fakeForTesting: FakeToolRun?
    static var fireOverrideForTesting: FakeToolRun?
    static var policyOverrideForTesting: PermissionPolicy?
    static func run(_ name: String, arguments: [String: String], policy: PermissionPolicy,
                    taskID: String? = nil) async throws -> AgentToolResult {
        fatalError("standalone fixture must not claim an actual tool-boundary execution")
    }
}
@MainActor enum TaskPermissionJournalSelfTest {
    static func run() async -> (cases: Int, failures: [String]) {
        fatalError("standalone fixture must not claim actual permission-boundary execution")
    }
}
@main struct TaskDurabilityFixture {
    @MainActor static func main() throws {
        // The owner's path collaborator is itself a disposable sentinel fixture.
        let owner = AppIdentity.applicationSupportDirectory
        try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: owner) }
        let sentinelFile = owner.appendingPathComponent("agent-tasks.json")
        let sentinel = Data("Disposable owner-path sentinel\\n".utf8)
        try sentinel.write(to: sentinelFile)
        let marker = TaskStoreSelfTest.run()
        print(marker)
        guard try Data(contentsOf: sentinelFile) == sentinel else { fatalError("fixture owner sentinel changed") }
        if !marker.hasPrefix("TASK_DURABILITY_OK:") { exit(1) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix="nextnotes-task-durability-") as temporary:
    folder = pathlib.Path(temporary)
    stubs = folder / "Collaborators.swift"
    stubs.write_text(collaborators)
    manager = SOURCE / "Agent/Tasks/AgentTaskManager.swift"
    store = SOURCE / "Agent/Tasks/AgentTaskStore.swift"
    durable_store = SOURCE / "Agent/Tasks/Durable/TaskStore.swift"
    journal = SOURCE / "Agent/Tasks/Durable/TaskEventJournal.swift"
    if "--omit-restart-mapping" in sys.argv:
        before = manager.read_text()
        broken = before.replace("if task.status == .running || task.status == .queued {", "if false { // mutation: omit restart mapping")
        assert before != broken, "mutation must change the actual restart producer"
        manager = folder / "AgentTaskManager.swift"
        manager.write_text(broken)
    if "--ignore-injected-path" in sys.argv:
        before = store.read_text()
        broken = before.replace("var storageURL: URL { injectedFileURL ?? Self.fileURL }",
                                "var storageURL: URL { Self.fileURL }")
        assert before != broken, "mutation must actually break isolated binding"
        store = folder / "AgentTaskStore.swift"
        store.write_text(broken)
    if "--drop-compatibility-directory" in sys.argv:
        before = durable_store.read_text()
        broken = before.replace(".optionalText(task.compatibilityDirectory)", ".optionalText(nil)")
        assert before != broken, "mutation must break the actual SQLite row mapper"
        durable_store = folder / "TaskStore.swift"
        durable_store.write_text(broken)
    if "--omit-sqlite-mirror" in sys.argv:
        before = store.read_text()
        broken = before.replace("try mirror.replaceSnapshot(canonical, failFast: true, events: events)",
                                "// mutation: omit actual JSON-to-SQLite mirror call")
        assert before != broken, "mutation must break the production persistence call site"
        store = folder / "AgentTaskStore.swift"
        store.write_text(broken)
    if "--wait-for-mirror-lock" in sys.argv:
        before = store.read_text()
        broken = before.replace("mirror.replaceSnapshot(canonical, failFast: true, events: events)",
                                "mirror.replaceSnapshot(canonical, failFast: false, events: events)")
        assert before != broken, "mutation must break the production fail-fast caller"
        store = folder / "AgentTaskStore.swift"
        store.write_text(broken)
    if "--omit-journal-events" in sys.argv or "--non-atomic-journal" in sys.argv:
        before = durable_store.read_text()
        broken = before.replace("try TaskEventJournal.append(events, to: db)", "// mutation: omit in-transaction append")
        assert before != broken, "mutation must alter actual journal write"
        if "--non-atomic-journal" in sys.argv:
            needle = "            }\n    }\n\n    func journal"
            assert needle in broken, "mutation must identify real transaction completion"
            broken = broken.replace(needle,
                "            }\n        try TaskEventJournal.append(events, to: db)\n    }\n\n    func journal", 1)
        durable_store = folder / "TaskStore.swift"
        durable_store.write_text(broken)
    if "--wrong-retention-age" in sys.argv:
        before = journal.read_text()
        broken = before.replace("AND last.at<?", "AND t.created_at<?")
        assert before != broken, "mutation must break actual journal retention age"
        journal = folder / "TaskEventJournal.swift"
        journal.write_text(broken)
    binary = folder / "task-durability-driver"
    definitions = [] if "--compile-tool-wrapper" in sys.argv else ["-D", "TASK_DURABILITY_STANDALONE"]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", *definitions, "-parse-as-library",
                    str(stubs), str(SOURCE / "Support/SelfTestStoreGuard.swift"),
                    str(SOURCE / "Agent/Tasks/AgentTask.swift"), str(store),
                    str(SOURCE / "Agent/Tasks/Durable/TaskDurability.swift"),
                    str(SOURCE / "Agent/Tasks/Durable/TaskStoreSchema.swift"),
                    str(journal),
                    str(durable_store),
                    str(manager), str(SOURCE / "Agent/Tasks/Durable/TaskStoreSelfTest.swift"),
                    "-o", str(binary)], check=True)
    sys.exit(subprocess.run([str(binary)]).returncode)
