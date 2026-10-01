#!/usr/bin/env python3
"""Copied actual manager/store regressions. Card collaborator is not installed UI proof."""
import ast
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCE = ROOT / 'Sources/NextNotes'
reference = ast.parse((ROOT / 'Tests/Reports/durable-tasks/run-task-authority-driver.py').read_text())
collaborators = next(ast.literal_eval(n.value) for n in reference.body
                     if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'collaborators' for t in n.targets))
collaborators = collaborators[:collaborators.index('@main struct TaskDurabilityFixture')]
collaborators = collaborators.replace('enum AgentBackendKind: String { case local, acp }', 'enum AgentBackendKind: String { case local, acp, cloud, remote }')
collaborators = collaborators.replace('static func request(for task: AgentTask) -> ACPCompatibilityRequest? { fatalError("fixture must not request backend") }', '''static func request(for task: AgentTask) -> ACPCompatibilityRequest? {
        guard let cli = task.compatibilityCLI, let command = task.compatibilityCommand else { return nil }
        return ACPCompatibilityRequest(command: command, cli: cli, directory: task.compatibilityDirectory)
    }''')
collaborators = collaborators.replace('static func commandLine(cli: String, objective: String) -> String { fatalError("compile-only CLI collaborator") }', 'static func commandLine(cli: String, objective: String) -> String { "\\(cli) fixture \\(objective)" }')
collaborators += '''
enum AgentRisk: Int, Codable, Sendable { case read, modify }
enum PermissionScopeKind: String, Codable, Sendable { case any, path }
struct PermissionScope: Codable, Equatable, Sendable {
    let kind: PermissionScopeKind
    let value: String
    static let any = PermissionScope(kind: .any, value: "")
}
enum ToolCallTrigger: Codable, Equatable, Sendable { case youSaid(String), unattributed }
struct ToolCallReview: Codable, Equatable, Sendable {
    let id: String
    let toolID: String
    let trigger: ToolCallTrigger
    var arguments: [String:String]
    func executionArguments(mergedOver proposed: [String:String]) -> [String:String] {
        var result = arguments
        for (key,value) in proposed where key.hasPrefix("_") { result[key] = value }
        return result
    }
}
enum AgentTransport: String, Codable, Sendable { case appUI, iMessage }
struct ActionOriginContext: Codable, Equatable, Sendable {
    let transport: AgentTransport
    var isRemote: Bool { transport == .iMessage }
}
@MainActor final class PermissionGate {
    static let shared = PermissionGate()
    var pending: PermissionRequest?
    var pendingReview: ToolCallReview?
    var queued: [PermissionRequest] = []
    var queuedCount: Int { queued.count }
    var restoredCount = 0
    @discardableResult
    func restore(_ request: PermissionRequest, review: ToolCallReview? = nil,
                 onReviewChange: ((ToolCallReview)->Bool)? = nil,
                 onDecision: @escaping (Bool,[String:String])->Bool) -> Bool {
        guard pending?.id != request.id, !queued.contains(where: {$0.id == request.id}) else { return true }
        restoredCount += 1
        if pending != nil { queued.append(request) }
        else {
            pending = request
            pendingReview = review ?? ToolCallReview(id:request.id, toolID:request.toolID,
                trigger: request.trigger, arguments:request.arguments)
        }
        return true
    }
    func cancelPending() { pending = nil; pendingReview = nil; queued = [] }
}
'''
original = '--original' in sys.argv
if original:
    collaborators += '''
@main struct RestorationFixture {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesRestorationOriginal-\\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("agent-tasks.json")
        let store = AgentTaskStore(fileURL:file)
        let request = PermissionRequest(id:"original-request", toolID:"filesystem.write", title:"Save fixture note",
            detail:"Original fixture detail", risk:.modify,
            arguments:["path":"/fixture/original.md","content":"Original fixture content","_authorizationPin":"original fixture pin"],
            taskID:"restoration-original", createdAt:Date(timeIntervalSince1970:1700000000), trigger:.youSaid("Write the approved fixture note"))
        let row = AgentTask(id:"restoration-original", objective:"Write the approved fixture note", source:"text",
            createdAt:Date(timeIntervalSince1970:1700000000), status:.waitingForPermission,
            progress:request.title, tool:request.toolID, arguments:request.arguments,
            pendingInteraction:.permission(request:request,origin:ActionOriginContext(transport:.appUI)))
        guard store.save([row]).primaryCommitted else { fatalError("original fixture did not save") }
        let manager = AgentTaskManager(store:AgentTaskStore(fileURL:file))
        var failures = 0
        if manager.task(id:row.id)?.pendingInteraction != row.pendingInteraction {
            failures += 1
            print("TASK_RESTORATION_WRONG: original primary projection discarded the exact pending permission payload")
        }
        if PermissionGate.shared.pending?.taskID != row.id {
            failures += 1
            print("TASK_RESTORATION_WRONG: original manager retained waiting approval but invoked no actual card consumer")
        }
        print("TASK_RESTORATION_FAILED: \\(failures) assertions")
        exit(failures > 0 ? 1 : 0)
    }
}
'''
else:
    collaborators += '''
@main struct RestorationFixture {
    @MainActor static func main() async {
        let marker = await TaskRestorationSelfTest.run()
        print(marker)
        exit(marker.hasPrefix("TASK_RESTORATION_OK:") ? 0 : 1)
    }
}
'''
with tempfile.TemporaryDirectory(prefix='nextnotes-restoration-copied-') as temporary:
    folder = pathlib.Path(temporary)
    (folder/'Collaborators.swift').write_text(collaborators)
    paths = ['Support/SelfTestStoreGuard.swift', 'Agent/Tasks/AgentTask.swift', 'Agent/Tasks/AgentTaskStore.swift',
             'Agent/Tasks/Durable/TaskDurability.swift', 'Agent/Tasks/Durable/TaskStoreSchema.swift',
             'Agent/Tasks/Durable/TaskEventJournal.swift', 'Agent/Tasks/Durable/TaskRecoveryPlanner.swift',
             'Agent/Tasks/Durable/TaskStore.swift', 'Agent/Tasks/AgentTaskManager.swift',
             'Agent/Permissions/PermissionRequest.swift']
    if not original:
        paths.append('Agent/Tasks/Durable/TaskRestorationSelfTest.swift')
    sources = []
    for relative in paths:
        path = SOURCE/relative
        if original and path.name in {'TaskStore.swift','TaskStoreSchema.swift','TaskEventJournal.swift'}:
            path = pathlib.Path('/tmp/nextnotes-restoration-original')/path.name
        elif original and path.name == 'AgentTaskManager.swift':
            target = folder/'OriginalAgentTaskManager.swift'
            target.write_text(subprocess.check_output(['git','show','5de382a:Sources/NextNotes/Agent/Tasks/AgentTaskManager.swift'],cwd=ROOT,text=True))
            path = target
        target = folder/path.name
        if path != target:
            target.write_text(path.read_text())
        sources.append(str(target))
    binary = folder/'restoration-driver'
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library', str(folder/'Collaborators.swift'),
                    *sources,'-o',str(binary)],check=True,cwd=ROOT)
    sys.exit(subprocess.run([str(binary)],cwd=ROOT).returncode)
