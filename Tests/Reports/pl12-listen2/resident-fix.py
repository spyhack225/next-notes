from pathlib import Path
p=Path('Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift')
s=p.read_text();a=s.index('    func prepareInteractiveConversation(');b=s.index('    private func streamPrompt(',a);body=s[a:b]
old='''    ) async throws -> PrefillStats {
        try await withLane(.realtimeAgent) { jobID in
            onAdmitted?()
            try await loadIfNeeded(schedulerJobID: jobID)
'''
new='''    ) async throws -> PrefillStats {
        // Optional partials must not initiate uncancellable weight/context startup.
        // Check before reservation, and again after any reservation/lane wait.
        guard !residentOnly || (model != nil && vocabulary != nil && context != nil) else {
            throw LlamaError.notLoaded
        }
        return try await withLane(.realtimeAgent) { jobID in
            guard !residentOnly || (model != nil && vocabulary != nil && context != nil) else {
                throw LlamaError.notLoaded
            }
            onAdmitted?()
            if !residentOnly { try await loadIfNeeded(schedulerJobID: jobID) }
'''
assert body.count(old)==1
body=body.replace(old,new,1)
needle='            let context = try ensureContext(promptTokens: tokens.count, maxTokens: maxTokens)\n'
replacement='            guard !residentOnly || contextSize >= tokens.count + maxTokens + Self.contextHeadroom else {\n                throw LlamaError.notLoaded\n            }\n            let context = try ensureContext(promptTokens: tokens.count, maxTokens: maxTokens)\n'
assert body.count(needle)==1
body=body.replace(needle,replacement,1)
s=s[:a]+body+s[b:];p.write_text(s)
