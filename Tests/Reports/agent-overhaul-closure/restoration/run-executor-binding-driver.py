#!/usr/bin/env python3
"""Actual full Executor.run + real Broker; observer runtime is NOT installed flow proof."""
import hashlib
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCE = ROOT / "Sources/NextNotes"
original = "--original" in sys.argv
relative = "Agent/Tools/AgentToolExecutor.swift"
source = (subprocess.check_output(["git", "show", f"8888474:Sources/NextNotes/{relative}"],
          cwd=ROOT, text=True) if original else (SOURCE / relative).read_text())
# A stable named overload boundary preserves the complete first production run
# method, including its effect closure. No branch is rewritten or reconstructed.
boundary = "    /// The Workspace runner, kept as the implementation for the eleven existing tools."
assert source.count(boundary) == 1
executor = source[:source.index(boundary)] + """
    @MainActor static func perform(_ tool: AgentTool, arguments: [String:String],
        taskID: String?, authority: ActionAuthority) async throws -> AgentToolResult {
        fatalError("producer probe must never execute a backing")
    }
}
"""

collaborators = r'''
import Foundation
import OSLog
enum SelfTest { static let isRunning = true }
enum Log { static let agent = Logger(subsystem: "isolated.executor.binding", category: "probe") }
enum AgentRisk: Int, Codable, Sendable, Comparable {
    case observe, read, modify, write, send, purchase, destructive, privileged
    static func <(a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    var mayAutoRun: Bool { self <= .read }
}
enum AgentToolNamespace: Sendable { case filesystem, shell, browser, memory, schedule, computer, workspace }
struct Parameter: Sendable { let name: String; let isRequired: Bool }
struct AgentTool: Sendable {
    let id: String; let namespace: AgentToolNamespace; let name: String
    let parameters: [Parameter]; let risk: AgentRisk = .modify
    let description = "Isolated fixture"
    func title(for arguments: [String:String]) -> String { "Isolated fixture" }
    func preview(for arguments: [String:String]) -> String? { nil }
}
struct AgentToolResult: Sendable { let summary: String }
@MainActor final class AgentToolRegistry {
    static let shared = AgentToolRegistry()
    func tool(named id: String) -> AgentTool? {
        switch id {
        case "filesystem.write": return AgentTool(id:id, namespace:.filesystem, name:"write",
            parameters:[Parameter(name:"path",isRequired:true),Parameter(name:"text",isRequired:true)])
        case "shell.run": return AgentTool(id:id, namespace:.shell, name:"run",
            parameters:[Parameter(name:"command",isRequired:true)])
        default: return nil
        }
    }
}
enum AgentError: Error { case unknownTool(String), missingArgument(name:String,tool:String),
    permissionDenied(String), backendUnavailable(String) }
enum ToolCallTrigger: Codable, Equatable, Sendable { case unattributed }
enum AppIdentity {
    static var applicationSupportDirectory:URL { fatalError("probe must never read or write owner grants") }
}
@MainActor enum Settings {
    struct Values { let agentAutoRunReadTools:Bool; let agentAutoSearchFiles:Bool; let agentAllowComputerControl:Bool }
    static var shared:Values { fatalError("probe must use its explicit policy, never owner settings") }
}
enum ScheduleToolCatalogue {
    static var confirmableIDs:Set<String> { fatalError("probe has no schedule tool") }
}
enum ActionAuthority: Equatable, Sendable { case user, systemDerived, memoryReview, scheduled
    var isScheduled: Bool { self == .scheduled } }
enum ActionSource: Sendable { case agent, meeting, scheduled }
struct ActionIntent: Sendable {
    let source:ActionSource; let authority:ActionAuthority; let verb:String; let target:String?
    let arguments:[String:String]; let evidence:[String]; let risk:AgentRisk; let confidence:Double
}
struct PreparedContent { let title:String; let visiblePlan:String? }
struct ActionRouting { let resource:String?; let taskID:String?; let meetingID:UUID? }
struct ActionExecutionPlan { let arguments:[String:String] }
struct PreparedAction { let executionPlan:ActionExecutionPlan }
struct RemoteIdentity: Codable, Hashable, Sendable {}
struct ToolCallReview: Sendable {}
struct TaskJournalContext: Sendable {
    let taskID:String; let attempt:Int
    let record: @MainActor @Sendable (String)->Void
    var restoredOrigin:ActionOriginContext? = nil
    var restoredPermission:PermissionRequest? = nil
    var restoredArguments:[String:String]? = nil
}
enum TaskEventJournal {
    @TaskLocal static var current:TaskJournalContext?
    @MainActor static func toolStarted(taskID:String?,tool:String)->TaskJournalContext? { nil }
    @MainActor static func toolCompleted(_ context:TaskJournalContext?,tool:String,succeeded:Bool) {}
}
enum ToolCallValidation {
    static func problem(tool:AgentTool,arguments:[String:String])->String? {
        tool.parameters.first(where: { $0.isRequired && (arguments[$0.name] ?? "").isEmpty }).map { "Missing \($0.name)" }
    }
}
enum PermissionScopeResolver {
    static func inferredAsync(tool:AgentTool,arguments:[String:String]) async->PermissionScope {
        if let path=arguments["path"] { return PermissionScope(kind:.path,value:path) }
        return .any
    }
}
enum BrowserCDPClient {
    static func isReachable() async->Bool { fatalError("no browser fixture in this producer probe") }
    static func targetID(for tool:AgentTool,arguments:[String:String]) async->String? { fatalError() }
    static func targetURL(for tool:AgentTool,arguments:[String:String]) async->String? { fatalError() }
}
enum BrowserToolExecutor { static func currentURL()->String? { fatalError() } }
enum MemoryWriteError: Error { case provenance(String) }
struct MemoryProvenanceValue { let requiredAuthority:ActionAuthority }
enum MemoryProvenance { static var current:MemoryProvenanceValue? { nil } }
enum ScheduleConfirmation { static func problem(toolID:String,arguments:[String:String],provenance:MemoryProvenanceValue?)->String? { fatalError() } }
enum AgentActivityProjector {
    static func title(for tool:AgentTool,arguments:[String:String])->String { "Isolated fixture" }
    static func kind(for tool:AgentTool)->String { "fixture" }
}
enum AgentAvatarState { static func forTool(namespace:AgentToolNamespace,name:String,risk:AgentRisk)->String { "fixture" } }
@MainActor final class AgentActivityStore {
    static let shared=AgentActivityStore()
    func update(taskID:String,kind:String,title:String,avatar:String) { fatalError("effect override must run first") }
    func presentationBinding(taskID:String?)->String? { fatalError() }
}
@MainActor final class IslandState {
    static let shared=IslandState()
    func showAgentWork(title:String) { fatalError() }
    func showBackgroundAgentWork(title:String) { fatalError() }
}
@MainActor final class AgentAuditLog {
    enum Kind { case tool }; static let shared=AgentAuditLog()
    func record(kind:Kind,title:String,detail:String,toolID:String,taskID:String?,meetingID:UUID?) { fatalError() }
}
struct ToolExecutionTimer { static var current:ToolExecutionTimer? { nil }; func begin() {}; func end() {} }
enum AgentWorkPresentationScope { @TaskLocal static var binding:String? }
enum AgentArtifactLedger { static func capture(taskID:String?,result:AgentToolResult) { fatalError() } }

// This consumer observer invokes the ACTUAL PermissionBroker but replaces
// ActionOrchestrator. It proves the executor's producer contract/callsite only.
@MainActor final class ActionOrchestrator {
    static let shared=ActionOrchestrator()
    func execute(intent:ActionIntent,tool:AgentTool,title:String,preparedContent:PreparedContent?,
        routing:ActionRouting,steps:[String],policy:PermissionPolicy,promptIfNeeded:Bool,
        permissionAlreadyGranted:Bool,allowUnverifiedResult:Bool,
        isStillValid:(@MainActor @Sendable () async->Bool)?,origin:ActionOriginContext?=nil,
        fire:@escaping @MainActor (PreparedAction) async throws->AgentToolResult) async throws->AgentToolResult {
        let decision=await PermissionBroker.shared.authorize(tool,arguments:intent.arguments,policy:policy,
            taskID:routing.taskID,authority:intent.authority,origin:origin)
        if case .deny(let reason)=decision { throw AgentError.permissionDenied(reason) }
        return try await fire(PreparedAction(executionPlan:ActionExecutionPlan(arguments:intent.arguments)))
    }
}
@main struct ExecutorBindingFixture {
    @MainActor static func main() async {
        var failures=0
        var fires=0
        AgentToolExecutor.fireOverrideForTesting={ _,_ in fires+=1; return AgentToolResult(summary:"Observed fixture effect boundary") }
        let expected=["path":"/isolated/fixture.md","text":"Exact reviewed text","_fixturePin":"original pin"]
        let request=PermissionRequest(id:"exact-request",toolID:"filesystem.write",title:"Fixture",detail:"Fixture",
            risk:.modify,arguments:expected,taskID:"exact-task")
        let context=TaskJournalContext(taskID:"exact-task",attempt:0,record:{ _ in },
            restoredPermission:request,restoredArguments:expected)
        var changed=expected; changed["_fixturePin"]="changed pin"
        var denied=false
        do {
            _=try await TaskEventJournal.$current.withValue(context) {
                try await AgentToolExecutor.run("filesystem.write",arguments:changed,policy:.denyMutations,
                    taskID:context.taskID,permissionAlreadyGranted:true)
            }
        } catch let error as AgentError {
            if case .permissionDenied(let reason)=error { denied=reason=="The action changed since you reviewed it. Please review it again." }
        } catch {}
        if !denied || fires != 0 { failures+=1; print("EXECUTOR_BINDING_WRONG: actual producer let changed pin reach observer effect=\(fires)") }
        fires=0
        let remote=TaskJournalContext(taskID:"remote-origin",attempt:0,record:{ _ in },
            restoredOrigin:ActionOriginContext(transport:.iMessage))
        var remoteDenied=false
        do {
            _=try await TaskEventJournal.$current.withValue(remote) {
                try await AgentToolExecutor.run("shell.run",arguments:["command":"sudo /usr/bin/true"],
                    policy:.denyMutations,taskID:remote.taskID,permissionAlreadyGranted:true)
            }
        } catch let error as AgentError {
            if case .permissionDenied(let reason)=error { remoteDenied=reason==RemoteAccessPolicy.sudoDenied }
        } catch {}
        if !remoteDenied || fires != 0 { failures+=1; print("EXECUTOR_BINDING_WRONG: actual producer dropped origin before real broker, observer effect=\(fires)") }
        print(failures==0 ? "EXECUTOR_BINDING_OK: 2 producer probes; runtime observer only" : "EXECUTOR_BINDING_FAILED: \(failures) assertions")
        exit(failures==0 ? 0:1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="nextnotes-executor-binding-") as temporary:
    folder = pathlib.Path(temporary)
    producer = folder / "AgentToolExecutor.swift"
    producer.write_text(executor)
    print(f"EXECUTOR_BINDING_SOURCE: {relative} original={'8888474' if original else 'worktree'} "
          f"full_sha256={hashlib.sha256(source.encode()).hexdigest()} "
          f"extracted_sha256={hashlib.sha256(executor.encode()).hexdigest()}", flush=True)
    support = folder / "Collaborators.swift"
    support.write_text(collaborators)
    sources = [producer, support]
    for relative in ("Agent/Permissions/PermissionRequest.swift", "Agent/Permissions/PermissionBroker.swift",
                     "Agent/Permissions/RemoteAccessPolicy.swift", "Agent/Permissions/PermissionPolicy.swift",
                     "Agent/Permissions/PermissionScope.swift"):
        path = folder / pathlib.Path(relative).name
        full_source = (SOURCE / relative).read_text()
        copied = full_source
        if path.name == "PermissionScope.swift":
            # Keep the complete native scope type/grant containment logic. Browser
            # discovery is a compile-only trap in this filesystem/shell probe.
            scope_boundary = "/// Pulls a scope out of the tool arguments, then the app argument for computer/browser."
            assert copied.count(scope_boundary) == 1
            copied = copied[:copied.index(scope_boundary)]
        path.write_text(copied)
        print(f"EXECUTOR_BINDING_SOURCE: {relative} full_sha256={hashlib.sha256(full_source.encode()).hexdigest()} "
              f"copied_sha256={hashlib.sha256(path.read_bytes()).hexdigest()}", flush=True)
        sources.append(path)
    binary = folder / "executor-binding-driver"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(folder / "module-cache"),
                    "-parse-as-library", *map(str, sources), "-o", str(binary)], cwd=ROOT, check=True)
    sys.exit(subprocess.run([str(binary)], cwd=ROOT).returncode)
