from pathlib import Path
import json,difflib,hashlib
root=Path(__file__).resolve().parent
manifest=json.loads((root/'candidate-worker-manifest.json').read_text())
p=root/'candidate-LocalAgentBackend.swift.txt';s=p.read_text();old='''        let permissionAlreadyGranted = await MainActor.run {''';new='''        let boundAttempt = task.scheduleID == nil && ["user", "text", "selftest"].contains(task.source)
            && task.backend == AgentBackendKind.local.rawValue
            && (task.durability?.attempt ?? 0) > 0
            && task.durability?.runtimeClass == .localDeterministic
            && task.durability?.attemptStartedAt != nil
            && task.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
        if boundAttempt {
            guard let context = TaskEventJournal.current, context.taskID == task.id,
                  context.attempt == task.durability?.attempt, context.isStillValid != nil else {
                throw AgentError.backendUnavailable("This task can’t safely continue. Nothing was run.")
            }
        }
        let permissionAlreadyGranted = await MainActor.run {''';assert s.count(old)==1;s=s.replace(old,new);p.write_text(s)
p=root/'candidate-TaskEventJournal.swift.txt';s=p.read_text();s=s.replace('''    static func toolCompleted(_ context: TaskJournalContext?, tool: String, succeeded: Bool) {
        guard let context else { return }
        _ = context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolCompleted,
            detail: "\\(tool):\\(succeeded ? "returned" : "threw")", attempt: context.attempt))
    }''','''    static func toolCompleted(_ context: TaskJournalContext?, tool: String, succeeded: Bool) -> Bool {
        guard let context else { return true }
        let admitted = context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolCompleted,
            detail: "\\(tool):\\(succeeded ? "returned" : "threw")", attempt: context.attempt))
        return context.isStillValid == nil || admitted
    }''');assert 'static func toolCompleted(_ context: TaskJournalContext?, tool: String, succeeded: Bool) -> Bool' in s;p.write_text(s)
p=root/'candidate-AgentToolExecutor.swift.txt';s=p.read_text();old='''        return try await ActionOrchestrator.shared.execute(
            intent: intent,
            tool: tool,
            title: publicTitle,''';new='''        var completedJournalAccepted = true
        let executedResult = try await ActionOrchestrator.shared.execute(
            intent: intent,
            tool: tool,
            title: publicTitle,''';assert s.count(old)==1;s=s.replace(old,new)
s=s.replace('''                defer { TaskEventJournal.toolCompleted(journal, tool: tool.id, succeeded: backingReturned) }''','''                defer {
                    completedJournalAccepted = TaskEventJournal.toolCompleted(journal, tool: tool.id,
                        succeeded: backingReturned)
                }''')
old='''        )
    }

    /// The Workspace runner''';new='''        )
        // Preserve the runtime's verified receipt before reporting the missing primary
        // task fact. A completed effect is never converted into a retryable task success.
        guard completedJournalAccepted else {
            throw AgentError.backendUnavailable("The action ran, but its task history could not be saved. Check the result before trying again.")
        }
        return executedResult
    }

    /// The Workspace runner''';assert s.count(old)==1;s=s.replace(old,new);p.write_text(s)
# Preserve the existing live gate/grant ordering. Normal typed LocalBackend does not
# open a live ask; its exact capture/restored callbacks already use SQL-first manager
# admission. Do not turn a late journal check into a purported grant safety proof.
name='Sources/NextNotes/Agent/Permissions/PermissionGate.swift'
p=root/manifest['files'][name]['candidate'];s=Path(name).read_text();s=s.replace('                    context.record(TaskJournalEventDraft','                    _ = context.record(TaskJournalEventDraft').replace('            context.record(TaskJournalEventDraft','            _ = context.record(TaskJournalEventDraft');p.write_text(s)
patch=[]
for name,entry in manifest['files'].items():
    source=Path(name).read_text();proposed=(root/entry['candidate']).read_text()
    assert hashlib.sha256(source.encode()).hexdigest()==entry['original_sha256'],name
    entry['candidate_sha256']=hashlib.sha256(proposed.encode()).hexdigest()
    patch += list(difflib.unified_diff(source.splitlines(True),proposed.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
(root/'candidate-worker-producer.patch').write_text(''.join(patch))
(root/'candidate-worker-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Prepared strict backend context guard; post-runtime completion refusal preserves receipts; no Sources edits')
