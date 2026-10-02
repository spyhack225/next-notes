#!/usr/bin/env python3
"""Compile copied actual task history producers; all stores are injected temp fixtures."""
import ast
import pathlib
import hashlib
import json
import subprocess
import sys
import tempfile
ROOT = pathlib.Path(__file__).resolve().parents[4]
SOURCE = ROOT/'Sources/NextNotes'
# Use the current restoration driver's declared external collaborators, not app bootstrap.
module = ast.parse((ROOT/'Tests/Reports/agent-overhaul-closure/restoration/run-restoration-driver.py').read_text())
prefix = ast.Module(body=module.body[:next(i for i,n in enumerate(module.body)
    if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='original' for t in n.targets))],type_ignores=[])
context = {'__file__': str(ROOT/'Tests/Reports/agent-overhaul-closure/restoration/run-restoration-driver.py')}
exec(compile(prefix,'restoration-collaborators','exec'),context)
collaborators = context['collaborators']
acp_source=(SOURCE/'Agent/Backend/ACPCompatibilityCLIBackend.swift').read_text()
request_type=acp_source[acp_source.index('struct ACPCompatibilityRequest'):acp_source.index('enum CompatibilityCLIError')]
old_type_start=collaborators.index('struct ACPCompatibilityRequest:')
old_type_end=collaborators.index('enum AgentError:',old_type_start)
collaborators=collaborators[:old_type_start]+request_type+collaborators[old_type_end:]
request_method=acp_source[acp_source.index('    static func request(for'):acp_source.index('    static func commandLine')]
command_method=acp_source[acp_source.index('    static func commandLine'):acp_source.index('    /// This entry point')]
quote_method=acp_source[acp_source.index('    private static func shellQuote'):acp_source.rfind('\n}')]
validator='@MainActor enum ACPCompatibilityCLIBackend {\n'+request_method+command_method+quote_method+\
 '\nstatic func submit(_ task:AgentTask, explicitApproval:Bool) async throws -> AgentTaskOutcome { fatalError("CLI backing must never execute") }\n}\n'
backend_start=collaborators.index('@MainActor enum ACPCompatibilityCLIBackend')
backend_end=collaborators.index('@MainActor final class PermissionGrantStore',backend_start)
collaborators=collaborators[:backend_start]+validator+collaborators[backend_end:]
collaborators += '''
@main struct CompatibilityFixture {
 @MainActor static func main() async {
   let marker = await TaskAuthoritySelfTest.runCompatibilityAdmission()
   print(marker)
   exit(marker.hasPrefix("TASK_COMPATIBILITY_ADMISSION_OK:") ? 0 : 1)
 }
}
'''
paths = ['Support/SelfTestStoreGuard.swift','Agent/Permissions/PermissionRequest.swift',
 'Agent/Tasks/AgentTask.swift','Agent/Tasks/AgentTaskStore.swift',
 'Agent/Tasks/Durable/TaskDurability.swift','Agent/Tasks/Durable/TaskStoreSchema.swift',
 'Agent/Tasks/Durable/TaskEventJournal.swift','Agent/Tasks/Durable/TaskRecoveryPlanner.swift',
 'Agent/Tasks/Durable/TaskStore.swift','Agent/Tasks/AgentTaskManager.swift',
 'Agent/Tasks/Durable/TaskAuthoritySelfTest.swift']
with tempfile.TemporaryDirectory(prefix='NextNotesHistoryRepairCopied-') as temporary:
 folder=pathlib.Path(temporary)
 stub=folder/'Collaborators.swift'; stub.write_text(collaborators)
 copies=[]
 for rel in paths:
  target=folder/pathlib.Path(rel).name
  original_source=ROOT/'Tests/Reports/agent-overhaul-closure/compatibility-admission/original-Manager.swift.txt'
  text=original_source.read_text() if '--original' in sys.argv and target.name=='AgentTaskManager.swift' else (SOURCE/rel).read_text()
  target.write_text(text); copies.append(str(target))
  print('COMPATIBILITY_SOURCE: '+rel+' sha256='+hashlib.sha256(target.read_bytes()).hexdigest(),flush=True)
 inputs={pathlib.Path(p).name: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in [str(stub),*copies]}
 inputs['actual-ACPCompatibilityCLIBackend-source']=hashlib.sha256(acp_source.encode()).hexdigest()
 manifest_name='original-input-manifest.json' if '--original' in sys.argv else 'final-input-manifest.json'
 (ROOT/'Tests/Reports/agent-overhaul-closure/compatibility-admission'/manifest_name).write_text(json.dumps(inputs,indent=2)+'\n')
 binary=folder/'driver'
 definitions=['-D','TASK_DURABILITY_STANDALONE']
 command=['xcrun','swiftc','-swift-version','6','-parse-as-library',*definitions,
   '-module-cache-path',str(folder/'modules'),str(stub),*copies,'-o',str(binary)]
 compiled=subprocess.run(command,capture_output=True,text=True)
 print(compiled.stdout+compiled.stderr,end='')
 print('compile_exit='+str(compiled.returncode))
 if compiled.returncode: raise SystemExit(compiled.returncode)
 result=subprocess.run([str(binary)],capture_output=True,text=True)
 print(result.stdout+result.stderr,end=''); print('run_exit='+str(result.returncode))
 raise SystemExit(result.returncode)
