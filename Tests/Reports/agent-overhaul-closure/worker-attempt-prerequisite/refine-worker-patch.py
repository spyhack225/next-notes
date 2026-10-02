from pathlib import Path
import difflib,json,hashlib
root=Path(__file__).resolve().parent
manifest=json.loads((root/'candidate-worker-manifest.json').read_text())
p=root/'candidate-AgentTaskManager.swift.txt';s=p.read_text()
s=s.replace('''    private func workerCondition(_ captured: AgentTask, states: [AgentTaskStatus])''','''    private func hasBoundLocalAttempt(_ task: AgentTask) -> Bool {
        guard ownsLocalAttempt(task), let durability = task.durability else { return false }
        return durability.attempt > 0 && durability.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
            && durability.attemptStartedAt != nil && durability.runtimeClass == .localDeterministic
    }

    private func workerCondition(_ captured: AgentTask, states: [AgentTaskStatus])''')
s=s.replace('guard ownsLocalAttempt(captured), let durability = captured.durability, durability.attempt > 0,','guard hasBoundLocalAttempt(captured), let durability = captured.durability,')
s=s.replace('if ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0 {','if hasBoundLocalAttempt(task) {')
s=s.replace('if self.ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0 {','if self.hasBoundLocalAttempt(task) {')
s=s.replace('if self.ownsLocalAttempt(task), (task.durability?.attempt ?? 0) > 0,','if self.hasBoundLocalAttempt(task),')
s=s.replace('if let current, ownsLocalAttempt(current), (current.durability?.attempt ?? 0) > 0 {','if let current, hasBoundLocalAttempt(current) {')
s=s.replace('''        let before = tasks[index]
        mutate(&tasks[index])
        let result = persist(events: transitionEvents(from: before, to: tasks[index], kinds: kinds), worker: worker)''','''        let before = tasks[index]
        let expected = worker ?? (hasBoundLocalAttempt(before)
            ? TaskWorkerWriteCondition(taskID: before.id, attempt: before.durability!.attempt,
                leaseOwner: before.durability!.leaseOwner, status: before.status) : nil)
        mutate(&tasks[index])
        let result = persist(events: transitionEvents(from: before, to: tasks[index], kinds: kinds), worker: expected)''')
s=s.replace('''        } catch {
            let failed = updateWorker(task)''','''        } catch {
            if ownsLocalAttempt(task), workerCondition(task, states: [.running]) == nil { return }
            let failed = updateWorker(task)''')
p.write_text(s)
# Archive exact currently unchanged application sources for this reviewed candidate set.
patch=[]
for name,entry in manifest['files'].items():
    source=Path(name).read_text(); proposed=(root/entry['candidate']).read_text()
    assert hashlib.sha256(source.encode()).hexdigest()==entry['original_sha256'],name
    entry['candidate_sha256']=hashlib.sha256(proposed.encode()).hexdigest()
    patch += list(difflib.unified_diff(source.splitlines(True),proposed.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
(root/'candidate-worker-producer.patch').write_text(''.join(patch))
(root/'candidate-worker-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Refined candidate bound-metadata scope and transaction guards; Sources unchanged')
