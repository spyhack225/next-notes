#!/usr/bin/env python3
from pathlib import Path

def edit(file, old, new, count=1):
    p=Path(file);s=p.read_text();assert old in s,(file,old[:80]);p.write_text(s.replace(old,new,count))
r='Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift'
edit(r,'''        residentOnly: Bool = false
    ) -> AsyncThrowingStream<String, Error> {''','''        residentOnly: Bool = false, onAdmitted: (@Sendable () -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {''')
# interactive forwarding, then its existing private stream helper
edit(r,'''            workClass: .realtimeAgent,
            renderSpecial: true,
            grammar: grammar
''','''            workClass: .realtimeAgent,
            renderSpecial: true,
            grammar: grammar, residentOnly: residentOnly, onAdmitted: onAdmitted
''')
edit(r,'''        workClass: WorkClass = .background,
        renderSpecial: Bool = false,
        grammar: GBNFGrammar? = nil
''','''        workClass: WorkClass = .background,
        renderSpecial: Bool = false,
        grammar: GBNFGrammar? = nil,
        residentOnly: Bool = false, onAdmitted: (@Sendable () -> Void)? = nil
''')
edit(r,'''            let task = Task {
                do {
                    try await self.withLane(workClass) { jobID in
''','''            let task = Task {
                do {
                    // Diagnostic resident answers never enter an uncancellable load.
                    // Recheck under the existing reservation after its actor waits.
                    guard !residentOnly || (self.model != nil && self.vocabulary != nil && self.context != nil) else {
                        throw LlamaError.notLoaded
                    }
                    try await self.withLane(workClass) { jobID in
''')
edit(r,'''                            grammar: grammar,
                            yield: { piece in continuation.yield(piece) }
''','''                            grammar: grammar, residentOnly: residentOnly, onAdmitted: onAdmitted,
                            yield: { piece in continuation.yield(piece) }
''')
edit(r,'''        grammar: GBNFGrammar? = nil,
        yield: @escaping @Sendable (String) -> Void
''','''        grammar: GBNFGrammar? = nil,
        residentOnly: Bool = false, onAdmitted: (@Sendable () -> Void)? = nil,
        yield: @escaping @Sendable (String) -> Void
''')
# only streaming body (leave ordinary completion untouched)
p=Path(r);s=p.read_text();start=s.index('    private func streamWhileScheduled(');head=s[:start];body=s[start:]
body=body.replace('''        try await loadIfNeeded(schedulerJobID: jobID)
        Self.reportUsageLoad''','''        guard !residentOnly || (model != nil && vocabulary != nil && context != nil) else {
            throw LlamaError.notLoaded
        }
        if !residentOnly { try await loadIfNeeded(schedulerJobID: jobID) }
        Self.reportUsageLoad''',1)
body=body.replace('''        guard promptTokens.count + maxTokens + Self.contextHeadroom <= contextTokens else {
            throw LlamaError.inputTooLong
        }
''','''        guard maxTokens >= 0, promptTokens.count <= contextTokens - Self.contextHeadroom,
              maxTokens <= contextTokens - promptTokens.count - Self.contextHeadroom else {
            throw LlamaError.inputTooLong
        }
        guard !residentOnly || contextSize >= promptTokens.count + maxTokens + Self.contextHeadroom else {
            throw LlamaError.notLoaded
        }
        onAdmitted?()
''',1)
p.write_text(head+body)
f='Sources/NextNotes/Formatting/LLM/LocalVoiceFrontend.swift'
edit(f,'''    // RED scaffold: external native admission only; the split validator and''','''    // Script external native admission only; the split validator and''')
edit(f,'''    func voiceLatencyAnswerProvider() -> (any LLMProvider)? { latencyAnswerProvider }
    nonisolated func admittedVoiceLatencyAnswerProvider() -> (any LLMProvider)? { nil }
''','''    func voiceLatencyAnswerProvider() -> (any LLMProvider)? { latencyAnswerProvider }
    // Existing stream ownership decides this value before yielding its first text.
    // The coordinator reads it synchronously; no new admission await on the turn.
    nonisolated private let admittedLatencyAnswer = LockedBox<(any LLMProvider)?>(nil)
    nonisolated func admittedVoiceLatencyAnswerProvider() -> (any LLMProvider)? {
        SelfTest.isRunning && SelfTest.requested == "--selftest-voice-latency"
            ? admittedLatencyAnswer.value : nil
    }
    private static var residentAnswerDiagnostic: Bool {
        Self.partialRouteDiagnostic && CommandLine.arguments.contains("--voice-latency-resident-only")
    }
''')
edit(f,'''        if let commitRevision { sealSpeculation(through: commitRevision) }
''','''        if let commitRevision { sealSpeculation(through: commitRevision) }
        admittedLatencyAnswer.value = nil
''')
edit(f,'''        let route: LocalVoiceRoute
''','''        let route: LocalVoiceRoute
        Self.emitTiming(timing, "route_plan_ready scheduler=none provider=appleFM")
''')
edit(f,'''            let routeCollectStarted = ContinuousClock.now
            let routeResponse''','''            let routeCollectStarted = ContinuousClock.now
            Self.emitTiming(timing, "typed_route_collect_started")
            let routeResponse''')
edit(f,'''        if routeOnly {
            // End this same''','''        Self.emitTiming(timing, "typed_route_validated")
        if routeOnly {
            // End this same''')
edit(f,'''            timing.id, revision, event, timing.elapsed())
''','''            timing.id, revision, event, timing.elapsed())
        message += " at_nanos=\\(VoiceLatencyTimeline.nowNanos())"
''')
p=Path(f);s=p.read_text();start=s.index('        let provider = latencyAnswerProvider ?? FoundationModelLLMProvider()',s.index('    private func streamSplitAnswer('));end=s.index('    private func streamSplitAnswerBody(',start)
s=s[:start]+'''        let requested = latencyAnswerProvider ?? FoundationModelLLMProvider()
        let started = LockedBox(false)
        func attempt(_ provider: any LLMProvider, session: LanguageModelSession?) async throws -> Bool {
            let recorder = ModelPassRecorder(
                feature: .agentVoice, pass: "frontend-answer", provider: provider,
                ids: ModelPassRecorder.correlation ?? UsageCorrelation(), requestedRole: nil)
            if timing.id == nextGenerationTimingID { admittedLatencyAnswer.value = provider }
            Self.emitTiming(timing, "answer_entry provider=\\(provider.id.rawValue)")
            do {
                let produced = try await streamSplitAnswerBody(
                    session: session, plan: plan, provider: provider, maxTokens: maxTokens,
                    continuation: continuation, timing: timing, recorder: recorder,
                    onText: { started.value = true })
                recorder.finish(reason: "stop")
                return produced
            } catch {
                recorder.fail(error)
                recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
                throw error
            }
        }
        do {
            return try await attempt(requested, session: session)
        } catch LlamaError.notLoaded where Self.residentAnswerDiagnostic
            && requested is LlamaLLMProvider && !started.value && !Task.isCancelled {
            // A refusal before any native text is not an answer failure. The route
            // stays validated; use Apple's independent answer session without loading.
            Self.emitTiming(timing, "answer_fallback_not_resident")
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("resident_answer", "apple_not_resident")
            }
            let apple = LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: plan))
            return try await attempt(FoundationModelLLMProvider(), session: apple)
        }
    }

'''+s[end:];p.write_text(s)
edit(f,'''        recorder: ModelPassRecorder
    ) async throws -> Bool {''','''        recorder: ModelPassRecorder, onText: @Sendable () -> Void
    ) async throws -> Bool {''')
edit(f,'''                if !started {
                    recorder.noteFirstToken()''','''                if !started {
                    onText()
                    recorder.noteFirstToken()''')
edit(f,'''        if partialRouteForTesting != nil, let generationForTesting {
''','''        if Self.residentAnswerDiagnostic, provider is LlamaLLMProvider, let residentAnswerForTesting {
            var current = ""
            let response = try await residentAnswerForTesting()
            for try await delta in response {
                current += delta
                try consume(current)
            }
        } else if partialRouteForTesting != nil, let generationForTesting {
''')
edit(f,'''                await local.streamInteractiveConversation(
                    system: plan.instructions, messages: messages, maxTokens: maxTokens)
''','''                await local.runtime.streamInteractiveConversation(
                    system: plan.instructions, messages: messages, maxTokens: maxTokens,
                    residentOnly: Self.residentAnswerDiagnostic,
                    onAdmitted: { Self.emitTiming(timing, "answer_native_admitted") })
''')
c='Sources/NextNotes/Agent/VoiceConversationCoordinator.swift'
edit(c, 'private func resolveAnswerRoute(id: UUID, epoch: UInt64, userMessageID: UUID, userWords: String)', 'private func resolveAnswerRoute(id: UUID, epoch: UInt64, userMessageID: UUID, userWords: String, tracker: AgentToolSpeechTracker)')
edit(c, '        guard responseID == id, !Task.isCancelled else { return }\n        resolveClassified(epoch: epoch, userMessageID: userMessageID, userWords: userWords)', '        guard responseID == id, !Task.isCancelled else { return }\n        if let actual = FrontendResponder.shared.admittedVoiceLatencyAnswerProvider() { tracker.noteModel(actual) }\n        resolveClassified(epoch: epoch, userMessageID: userMessageID, userWords: userWords)')
edit(c, 'await self.resolveAnswerRoute(id: id, epoch: inputEpoch, userMessageID: userMessageID, userWords: text)', 'await self.resolveAnswerRoute(id: id, epoch: inputEpoch, userMessageID: userMessageID, userWords: text, tracker: tracker)')
Path('Sources/NextNotes/Agent/Voice/VoiceDiagnosticSpeech.swift').write_text(Path('Tests/Reports/voice-mini/green-speech-source.txt').read_text())
l='Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift'
edit(l, '''        SelfTest.diagnostic("VOICE_LATENCY_TTS_READY=pocket")''','''        guard let speechProof = await VoiceDiagnosticSpeech.preparePocket() else {
            return absent("Pocket playback could not prepare; no alternate voice was used")
        }
        defer { _ = speechProof.finish() }
        SelfTest.diagnostic("VOICE_LATENCY_TTS_READY=pocket")''')
edit(l, '''        // --- The table, the absent case, the store and the probe, before any measurement''','''        if CommandLine.arguments.contains("--voice-latency-resident-prepare") {
            guard CommandLine.arguments.contains("--voice-latency-resident-only"),
                  let local = await FrontendResponder.shared.voiceLatencyAnswerProvider() as? LlamaLLMProvider else {
                return absent("resident preparation requires the explicit isolated local answerer")
            }
            let request = VoiceConversationCoordinator.shared.stagingRequest()
            guard let plan = LocalVoiceSplitResponse.answerPlan(system: request.system, messages: request.messages) else {
                return absent("the resident answer preparation plan is missing")
            }
            let messages = plan.history.map { LLMChatMessage(role: $0.role, content: $0.content) }
                + [LLMChatMessage(role: .user, content: plan.latestUser)]
            let began = ContinuousClock.now
            do {
                _ = try await local.runtime.prepareInteractiveConversation(
                    system: plan.instructions, messages: messages,
                    maxTokens: 256) // Same unchanged coordinator response budget.
            } catch { return absent("resident answer preparation failed before any measured turn") }
            let duration = began.duration(to: .now).components
            SelfTest.diagnostic("VOICE_RESIDENT_PREPARATION seconds=\\(Double(duration.seconds) + Double(duration.attoseconds) / 1e18) scope=before-all-spoken-turns")
        }

        // --- The table, the absent case, the store and the probe, before any measurement''')
edit(l,'''        return finish(wrong)
    }

    private typealias FloorPressureHistory''','''        wrong += speechProof.finish()
        return finish(wrong)
    }

    private typealias FloorPressureHistory''')
edit(l,'''            if summary.provider != "llama" || summary.modelID != name
                || answers.isEmpty || !nativeAnswer
                || answers.contains(where: { $0.provider != "llama" || $0.modelID != name }) {
                wrong.append("run \\(index): explicit answering file pin did not reach the committed consumer and joined native answer pass")
            }''','''            if CommandLine.arguments.contains("--voice-latency-resident-only"),
               turn.notes["resident_answer"] == "apple_not_resident" {
                // New diagnostic explicitly requests resident-only admission. Bind
                // the actual fallback, retaining every failed native admission row.
                let apple = FoundationModelLLMProvider()
                let completed = answers.filter { $0.errorClass == nil && $0.finishReason == "stop" }
                if summary.provider != "appleFM" || summary.modelID != apple.displayModelName
                    || completed.count != 1 || completed[0].provider != "appleFM"
                    || completed[0].countsEstimated != true || (completed[0].completionTokens ?? 0) <= 0 {
                    wrong.append("run \\(index): resident refusal did not reach exactly one joined Apple answer and actual consumer")
                }
            } else if summary.provider != "llama" || summary.modelID != name
                || answers.isEmpty || !nativeAnswer
                || answers.contains(where: { $0.provider != "llama" || $0.modelID != name }) {
                wrong.append("run \\(index): explicit answering file pin did not reach the committed consumer and joined native answer pass")
            }''')
p='Sources/NextNotes/Activation/AgentCaptureController.swift'
edit(p,'''    static func runVoicePipelineSelfTest(wav: URL,
        appleFastResults: Bool = true) async -> [String] {
        let capture''','''    static func runVoicePipelineSelfTest(wav: URL,
        appleFastResults: Bool = true) async -> [String] {
        guard let speechProof = await VoiceDiagnosticSpeech.preparePocket() else {
            return ["Pocket is unavailable; no alternate voice was used"]
        }
        defer { _ = speechProof.finish() }
        let capture''')
edit(p,'''        speech.onPlaybackEvent = priorPlaybackEvent
        return failures
    }

    /// Real TTS plays''','''        speech.onPlaybackEvent = priorPlaybackEvent
        failures += speechProof.finish()
        return failures
    }

    /// Real TTS plays''')
print('VOICE_MINI_PRODUCER_PATCH_APPLIED')
edit(l, '''        let swapAfter = floor ? MeetingResourceHealth.swapBytes().used : nil''', '''        if CommandLine.arguments.contains("--voice-latency-resident-only"),
           let local = await FrontendResponder.shared.voiceLatencyAnswerProvider() as? LlamaLLMProvider {
            SelfTest.diagnostic("VOICE_RESIDENT_STATE loaded=\\(await local.runtime.isLoaded) scope=after-all-turns")
        }
        let swapAfter = floor ? MeetingResourceHealth.swapBytes().used : nil''')
edit(f, '''            Self.emitTiming(timing, "typed_route_collect_started")
            let routeResponse''', '''            Self.emitTiming(timing, "typed_route_collect_started")
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("route_collect_started_nanos", String(VoiceLatencyTimeline.nowNanos()))
                VoiceLatencyTimeline.shared.note("route_provider", "appleFM")
                VoiceLatencyTimeline.shared.note("route_scheduler", "none")
            }
            let routeResponse''')
edit(f, '''            Self.emitTiming(timing, "typed_route_collect_done", durationFrom: routeCollectStarted)
            try Task.checkCancellation()''', '''            Self.emitTiming(timing, "typed_route_collect_done", durationFrom: routeCollectStarted)
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("route_collect_done_nanos", String(VoiceLatencyTimeline.nowNanos()))
            }
            try Task.checkCancellation()''')
edit(f, '''        Self.emitTiming(timing, "typed_route_validated")
        if routeOnly''', '''        Self.emitTiming(timing, "typed_route_validated")
        if timing.id == nextGenerationTimingID {
            VoiceLatencyTimeline.shared.note("route_validated_nanos", String(VoiceLatencyTimeline.nowNanos()))
        }
        if routeOnly''')
edit(l, '''        parts.append("main_stall_max=\\(Self.format(turn.mainStallSeconds))")''', '''        if let collect = turn.notes["route_collect_started_nanos"].flatMap(UInt64.init),
           let done = turn.notes["route_collect_done_nanos"].flatMap(UInt64.init), done >= collect {
            parts.append("route_collect_s=\\(Self.format(Double(done - collect) / 1e9))")
            if let validated = turn.notes["route_validated_nanos"].flatMap(UInt64.init), validated >= done {
                parts.append("route_validate_s=\\(Self.format(Double(validated - done) / 1e9))")
            }
        }
        parts.append("resident_answer=\\(turn.notes["resident_answer"] ?? "none")")
        parts.append("main_stall_max=\\(Self.format(turn.mainStallSeconds))")''')
t='Sources/NextNotes/Agent/VoiceCapabilityConversationSelfTest.swift'
edit(t, '''        print("FRONTEND_REVISION_CHECKS count=\\(revisionContract.checks) problems=\\(revisionContract.failures.count)")
        let coordinator''', '''        print("FRONTEND_REVISION_CHECKS count=\\(revisionContract.checks) problems=\\(revisionContract.failures.count)")
        // Nested contracts restore their own backing. Install the corpus recorder
        // after them so these real spoken turns never select an Apple voice.
        let speech = AgentSpeechSynthesizer.shared
        let appleCallsBefore = AgentSpeechSynthesizer.appleSynthesisCallsForTesting
        speech.useTestingBacking(RecordingSpeechBacking())
        defer {
            speech.restoreSystemBacking()
        }
        let coordinator''')
edit(t, '''        for failure in failures {
            print("VOICE_TURN_ROUTING_WRONG:''', '''        let applePlaybackCalls = AgentSpeechSynthesizer.appleSynthesisCallsForTesting - appleCallsBefore
        print("VOICE_TURN_ROUTING_APPLE_CALLS=\\(applePlaybackCalls)")
        if applePlaybackCalls != 0 { failures.append("scripted voice routing reached Apple playback") }
        for failure in failures {
            print("VOICE_TURN_ROUTING_WRONG:''')

edit(l, '        let floor = CommandLine.arguments.contains("--voice-latency-floor")', '        if CommandLine.arguments.contains("--voice-latency-resident-only"),\n           !CommandLine.arguments.contains("--voice-latency-partial-route") {\n            return absent("resident-only answering requires the split partial-route diagnostic")\n        }\n        let floor = CommandLine.arguments.contains("--voice-latency-floor")')
