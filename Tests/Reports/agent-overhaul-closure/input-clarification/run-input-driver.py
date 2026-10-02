#!/usr/bin/env python3
"""Actual manager/backend/executor/question producers; runtime observer is not installed UI proof."""
import ast
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCE = ROOT / 'Sources/NextNotes'
REPORT = pathlib.Path(__file__).resolve().parent
original = '--original' in sys.argv
scope_original = '--scope-original' in sys.argv

def literal(name, path):
    module = ast.parse(path.read_text())
    return next(ast.literal_eval(n.value) for n in module.body if isinstance(n, ast.Assign)
                and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))

def drop(source, names):
    # Harness declarations are top-level; retain no duplicate stand-in for a copied producer.
    pattern = re.compile(r'^(?:@(?:MainActor|main)\s+)?(?:final\s+)?(?:enum|struct|class|actor)\s+(\w+)\b', re.M)
    matches = list(pattern.finditer(source))
    for index in range(len(matches)-1, -1, -1):
        match = matches[index]
        if match.group(1) in names:
            end = matches[index+1].start() if index+1 < len(matches) else len(source)
            start = match.start()
            # A preceding stand-alone actor annotation belongs to the removed declaration.
            if source[:start].endswith('@MainActor\n'):
                start -= len('@MainActor\n')
            source = source[:start] + source[end:]
    return source

base = literal('collaborators', ROOT/'Tests/Reports/durable-tasks/run-task-authority-driver.py')
base = base[:base.index('@main struct TaskDurabilityFixture')]
base = drop(base, {'AgentBackendKind','PermissionDuration','PermissionGrant','AgentError',
                  'PermissionGrantStore','AgentBackendRegistry','FixtureBackend','AgentArtifactLedger',
                  'AgentTool','AgentToolResult','PermissionPolicy','AgentToolExecutor'})
base = base.replace('static let app = Logger', 'static let agent = Logger(subsystem: "fixture.task-input", category: "executor"); static let app = Logger')
base = base.replace('enum Kind { case waiting }', 'enum Kind { case waiting, tool }')
base = base.replace('    func begin(task: AgentTask, title: String)',
    '    func update(taskID:String,kind:Kind,title:String,avatar:String) { fatalError("final backing override must run first") }\n'
    '    func presentationBinding(taskID:String?)->String? { fatalError("final backing override must run first") }\n'
    '    func begin(task: AgentTask, title: String)')
base = base.replace('func finish(taskID: String, title: String) { fatalError("fixture must not finish activity") }',
    'func finish(taskID: String, title: String) { /* declared Activity projection observer; no UI/store claim */ }')
base = base.replace('    func showBackgroundAgentWork(title: String)',
    '    func showAgentWork(title:String) { fatalError("final backing override must run first") }\n'
    '    func showBackgroundAgentWork(title: String)')
base = base.replace('enum Kind: Equatable { case reply, task }', 'enum Kind: Equatable { case reply, task, tool }')
base = base.replace('    func record(kind: Kind, title: String)',
    '    func record(kind:Kind,title:String,detail:String,toolID:String,taskID:String?,meetingID:UUID?) { fatalError("final backing override must run first") }\n'
    '    func record(kind: Kind, title: String)')

observer = literal('collaborators', ROOT/'Tests/Reports/agent-overhaul-closure/restoration/run-executor-binding-driver.py')
observer = observer[:observer.index('@main struct ExecutorBindingFixture')]
observer = drop(observer, {'SelfTest','Log','AgentRisk','AgentToolNamespace','Parameter','AgentTool',
    'AgentToolResult','AgentToolRegistry','AgentError','ToolCallTrigger','AppIdentity','Settings',
    'ToolCallReview','TaskJournalContext','TaskEventJournal','ToolCallValidation','AgentActivityStore',
    'IslandState','AgentAuditLog','AgentArtifactLedger'})
observer = observer.replace('static func kind(for tool:AgentTool)->String { "fixture" }',
    'static func kind(for tool:AgentTool)->AgentActivityStore.Kind { .tool }')
observer = observer.replace('enum ScheduleToolCatalogue {', 'enum ScheduleToolCatalogue { static let all:[AgentTool]=[]')
observer = observer.replace('''        if case .deny(let reason)=decision { throw AgentError.permissionDenied(reason) }
        return try await fire''', '''        switch decision {
        case .allow: break
        case .deny(let reason): throw AgentError.permissionDenied(reason)
        case .ask(let request), .askLocal(let request): throw AgentError.needsPermission(request.title)
        }
        return try await fire''')

collaborators = base + observer + r'''
@MainActor enum Settings {
    struct Values {
        let agentAutoRunReadTools=true; let agentAutoSearchFiles=true; let agentAllowComputerControl=false
        let agentBackend=AgentBackendKind.local
    }
    static let shared=Values()
}
@MainActor final class PermissionGate {
    static let shared=PermissionGate()
    var pending:PermissionRequest?
    var pendingReview:ToolCallReview?
    var queuedCount:Int { 0 }
    func hasRestoredRequest(taskID:String)->Bool { false }
    func cancelPending(taskID:String) {}
    func cancelPending() { pending=nil; pendingReview=nil }
    func resetForRestartTesting() { cancelPending() }
    @discardableResult
    func restore(_ request:PermissionRequest,review:ToolCallReview?=nil,
        onReviewChange:((ToolCallReview)->Bool)?=nil,onDecision:@escaping (Bool,[String:String])->Bool)->Bool {
        fatalError("read clarification must never restore a permission card")
    }
    @discardableResult
    func respond(id:String,approved:Bool,duration:PermissionDuration = .once)->Bool { fatalError("no permission decision in read fixture") }
}
struct ACPAgentBackend:AgentBackend {
    func describe() async->AgentBackendDescription { fatalError("no ACP in local input fixture") }
    func start() async throws { fatalError() }
    func health() async->String { fatalError() }
    func submit(_ task:AgentTask) async throws->AgentTaskOutcome { fatalError() }
    func status(taskID:String) async->AgentTaskStatus? { fatalError() }
    func cancel(taskID:String) async { fatalError() }
    func respondPermission(taskID:String,approved:Bool) async { fatalError() }
    func respondInput(taskID:String,text:String) async { fatalError() }
}
enum MeetingToolCatalogue { static let all:[AgentTool]=[] }
enum ComputerToolCatalogue { static let all:[AgentTool]=[] }
enum FileToolCatalogue { static let all:[AgentTool]=[]; static let findName="find"; static let treeName="tree" }
enum FileToolExecutor { static func run(_ tool:AgentTool,arguments:[String:String]) throws->AgentToolResult { fatalError("no indexed file backing") } }
enum ShellToolCatalogue { static let all:[AgentTool]=[] }
enum BrowserToolCatalogue { static let all:[AgentTool]=[] }
enum MemoryToolCatalogue { static let all:[AgentTool]=[] }
enum KnowledgeToolCatalogue { static let all:[AgentTool]=[] }
enum AssemblerToolCatalogue { static let all:[AgentTool]=[] }
enum SkillToolCatalogue { static let all:[AgentTool]=[] }
enum BrowserPurchase { static func problem(arguments:[String:String])->String? { fatalError("no purchase fixture") } }
'''

acp_source = (SOURCE/'Agent/Backend/ACPCompatibilityCLIBackend.swift').read_text()
request_type = acp_source[acp_source.index('struct ACPCompatibilityRequest'):acp_source.index('enum CompatibilityCLIError')]
collaborators = drop(collaborators, {'ACPCompatibilityRequest'}) + request_type
file_catalogue_source = (SOURCE/'Knowledge/Files/FileIndexTools.swift').read_text()
file_catalogue = file_catalogue_source[file_catalogue_source.index('enum FileToolCatalogue {'):file_catalogue_source.index('// MARK: - Execution')]
collaborators = drop(collaborators, {'FileToolCatalogue'}) + file_catalogue

model = (SOURCE/'Agent/AgentModels.swift').read_text()
model_types = 'import Foundation\n' + model[model.index('enum AgentRisk:'):model.index('enum AgentProposalSource:')]
model_types += model[model.index('struct WorkspaceToolResult:'):model.index('struct AgentActionRecord:')]
model_types += model[model.index('enum AgentError:'):]

executor_source = (SOURCE/'Agent/Tools/AgentToolExecutor.swift').read_text()
boundary = '    /// The Workspace runner, kept as the implementation for the eleven existing tools.'
assert executor_source.count(boundary) == 1
executor = executor_source[:executor_source.index(boundary)] + '''
    @MainActor static func perform(_ tool:AgentTool,arguments:[String:String],taskID:String?,authority:ActionAuthority) async throws->AgentToolResult {
        fatalError("only the restricted final backing override may execute")
    }
}
'''

production = (SOURCE/'Agent/Tasks/Durable/TaskRestorationProductionSelfTest.swift').read_text()
helper = production[production.index('    /// Actual missing-argument producer'):production.rfind('\n}')]
if original:
    fixture = r'''
@main struct InputFixture {
    @MainActor static func main() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskInputOriginal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:root) }
        let sql=TaskStore(root:root); defer { sql.close() }
        let store=AgentTaskStore(fileURL:root.appendingPathComponent("agent-tasks.json"),mirror:sql)
        guard store.allowsHarnessPersistence else { fatalError("unsafe fixture store") }
        let manager=AgentTaskManager(store:store)
        AgentToolExecutor.fakeForTesting=nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        var fires=0
        AgentToolExecutor.fireOverrideForTesting={ _,_ in fires+=1; fatalError("missing original path must never reach a read") }
        let task=manager.submit(objective:"Read my chosen fixture file",tool:"filesystem.read",source:"text")
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while [AgentTaskStatus.queued,.running].contains(manager.task(id:task.id)?.status ?? .failed),ContinuousClock.now<deadline { await Task.yield() }
        let question=manager.pendingInputs.first
        var failures=0
        if manager.task(id:task.id)?.status != AgentTaskStatus.waitingForInput {
            failures+=1; print("TASK_INPUT_CLARIFICATION_WRONG: actual original missing-path producer ended \(manager.task(id:task.id)?.status.rawValue ?? "absent") rather than waiting for its answer")
        }
        if question?.question != "Which file?" || question?.toolID != "filesystem.read" || question?.argumentName != "path" {
            failures+=1; print("TASK_INPUT_CLARIFICATION_WRONG: original producer retained no bound review question")
        }
        if fires != 0 || manager.backendStartsForTesting != 1 { failures+=1; print("TASK_INPUT_CLARIFICATION_WRONG: original fixture did not exercise exactly one incomplete backend without an effect") }
        print(failures==0 ? "TASK_INPUT_CLARIFICATION_OK: 3 original producer probes" : "TASK_INPUT_CLARIFICATION_FAILED: \(failures) assertions")
        exit(failures==0 ? 0:1)
    }
}
'''
else:
    fixture = '@MainActor enum TaskRestorationProductionSelfTest {\nprivate enum FixtureError:Error { case unsafeEffect,absentRequest }\n' + helper + r'''
}
@main struct InputFixture {
    @MainActor static func main() async {
        let marker=await TaskRestorationProductionSelfTest.runInputClarification()
        print(marker)
        exit(marker.hasPrefix("TASK_INPUT_CLARIFICATION_OK:") ? 0:1)
    }
}
'''

paths = ['Support/SelfTestStoreGuard.swift','Agent/Tasks/AgentTask.swift','Agent/Tasks/AgentTaskStore.swift',
 'Agent/Tasks/Durable/TaskDurability.swift','Agent/Tasks/Durable/TaskStoreSchema.swift',
 'Agent/Tasks/Durable/TaskEventJournal.swift','Agent/Tasks/Durable/TaskRecoveryPlanner.swift',
 'Agent/Tasks/Durable/TaskStore.swift','Agent/Tasks/AgentTaskManager.swift','Agent/Tasks/AgentArtifactLedger.swift',
 'Agent/Backend/AgentBackend.swift','Agent/Backend/LocalAgentBackend.swift','Agent/WorkspaceTools.swift',
 'Agent/Tools/AgentTool.swift','Agent/Tools/AgentToolRegistry.swift','Agent/Tools/FilesystemTools.swift',
 'Shell/FilesystemExecutor.swift','Agent/Permissions/ToolCallReview.swift','Agent/Permissions/ToolCallReviewBuilder.swift',
 'Agent/Permissions/ToolCallInspector.swift','Agent/Permissions/ToolCallContext.swift','Agent/Permissions/ToolCallValidation.swift',
 'Agent/Permissions/PermissionRequest.swift','Agent/Permissions/PermissionPolicy.swift',
 'Agent/Permissions/PermissionBroker.swift','Agent/Permissions/PermissionScope.swift','Agent/Permissions/RemoteAccessPolicy.swift']
fixture = 'import Foundation\nimport SQLite3\n' + fixture
with tempfile.TemporaryDirectory(prefix='NextNotesTaskInputCopied-') as temporary:
    folder=pathlib.Path(temporary)
    generated={'Collaborators.swift':collaborators,'ModelTypes.swift':model_types,
               'AgentToolExecutor.swift':executor,'InputFixture.swift':fixture,
               'BackendEvent.swift':(SOURCE/'Agent/Backend/ACPSession.swift').read_text().split('/// One ACP stdio session:')[0]}
    files=[]
    inputs={}
    for name,text in generated.items():
        target=folder/name; target.write_text(text); files.append(target)
        inputs[name]={'copied_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
    for relative in paths:
        target=folder/pathlib.Path(relative).name
        source=(SOURCE/relative).read_text()
        if original and target.name=='AgentTaskManager.swift':
            source=(REPORT/'original-AgentTaskManager.swift.txt').read_text()
        elif scope_original and target.name=='AgentTaskManager.swift':
            source=(REPORT/'pre-eligibility-AgentTaskManager.swift.txt').read_text()
        copied=source
        if target.name=='PermissionScope.swift':
            copied=source[:source.index('/// Pulls a scope out of the tool arguments, then the app argument for computer/browser.')]
        target.write_text(copied); files.append(target)
        inputs[relative]={'full_sha256':hashlib.sha256(source.encode()).hexdigest(),
                          'copied_sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
        print('INPUT_SOURCE: '+relative+' sha256='+inputs[relative]['copied_sha256'],flush=True)
    inputs['actual-full-FileIndexTools']=hashlib.sha256(file_catalogue_source.encode()).hexdigest()
    inputs['actual-full-Executor']=hashlib.sha256(executor_source.encode()).hexdigest()
    inputs['actual-full-Models']=hashlib.sha256(model.encode()).hexdigest()
    inputs['actual-full-RestorationProductionSelfTest']=hashlib.sha256(production.encode()).hexdigest()
    inputs['actual-full-ACPCompatibilityCLIBackend']=hashlib.sha256(acp_source.encode()).hexdigest()
    (REPORT/('original-input-manifest.json' if original else 'scope-original-input-manifest.json' if scope_original else 'final-input-manifest.json')).write_text(json.dumps(inputs,indent=2)+'\n')
    binary=folder/'driver'
    command=['xcrun','swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(folder/'modules'),
             *map(str,files),'-o',str(binary)]
    compiled=subprocess.run(command,capture_output=True,text=True,cwd=ROOT)
    print(compiled.stdout+compiled.stderr,end=''); print('compile_exit='+str(compiled.returncode),flush=True)
    if compiled.returncode: raise SystemExit(compiled.returncode)
    result=subprocess.run([str(binary)],capture_output=True,text=True,cwd=ROOT)
    print(result.stdout+result.stderr,end=''); print('run_exit='+str(result.returncode),flush=True)
    raise SystemExit(result.returncode)
