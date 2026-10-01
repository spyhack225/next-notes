#!/usr/bin/env python3
"""Compile copied actual task history producers; all stores are injected temp fixtures."""
import ast
import pathlib
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
collaborators = collaborators.replace('    func cancelPending() {', '''    func hasRestoredRequest(taskID: String) -> Bool { false }
    func cancelPending(taskID: String) {}
    @discardableResult func respond(id: String, approved: Bool, duration: PermissionDuration) -> Bool { false }
    func cancelPending() {''')
collaborators += '''
@main struct HistoryFixture {
 @MainActor static func main() {
   let marker = TaskHistoryRepairSelfTest.run()
   print(marker)
   exit(marker.hasPrefix("TASK_HISTORY_REPAIR_OK:") ? 0 : 1)
 }
}
'''
paths = ['Support/SelfTestStoreGuard.swift','Agent/Permissions/PermissionRequest.swift',
 'Agent/Tasks/AgentTask.swift','Agent/Tasks/AgentTaskStore.swift',
 'Agent/Tasks/Durable/TaskDurability.swift','Agent/Tasks/Durable/TaskStoreSchema.swift',
 'Agent/Tasks/Durable/TaskEventJournal.swift','Agent/Tasks/Durable/TaskRecoveryPlanner.swift',
 'Agent/Tasks/Durable/TaskStore.swift','Agent/Tasks/AgentTaskManager.swift',
 'Agent/Tasks/Durable/TaskHistoryRepairSelfTest.swift']
with tempfile.TemporaryDirectory(prefix='NextNotesHistoryRepairCopied-') as temporary:
 folder=pathlib.Path(temporary)
 stub=folder/'Collaborators.swift'; stub.write_text(collaborators)
 copies=[]
 for rel in paths:
  target=folder/pathlib.Path(rel).name; target.write_text((SOURCE/rel).read_text()); copies.append(str(target))
 binary=folder/'driver'
 definitions=['-D','TASK_HISTORY_REPAIR_ORIGINAL'] if '--original' in sys.argv else []
 command=['xcrun','swiftc','-swift-version','6','-parse-as-library',*definitions,
   '-module-cache-path',str(folder/'modules'),str(stub),*copies,'-o',str(binary)]
 compiled=subprocess.run(command,capture_output=True,text=True)
 print(compiled.stdout+compiled.stderr,end='')
 print('compile_exit='+str(compiled.returncode))
 if compiled.returncode: raise SystemExit(compiled.returncode)
 result=subprocess.run([str(binary)],capture_output=True,text=True)
 print(result.stdout+result.stderr,end=''); print('run_exit='+str(result.returncode))
 raise SystemExit(result.returncode)
