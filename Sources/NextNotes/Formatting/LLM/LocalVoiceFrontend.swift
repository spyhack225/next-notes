import Foundation
import FoundationModels

/// An on-device conversational lane independent of the notes/planning context.
///
/// Foundation Models owns its own inference state. A tool worker can therefore keep
/// generating with llama.cpp while this lane handles a new spoken turn. The frontend
/// receives only compact conversation and work status; it cannot perform tool effects.
actor LocalVoiceFrontend {
    static let shared = LocalVoiceFrontend()

    enum FrontendError: LocalizedError {
        case unavailable(String)
        case revisedSnapshot
        case emptyResponse
        case typedDecisionIncomplete
        case typedDecisionRevised
        case splitAnswerProtocolViolation

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .revisedSnapshot: "The local voice model revised text already streamed for speech."
            case .emptyResponse: "The local voice model completed without a response."
            case .typedDecisionIncomplete: "The local voice model completed without a valid typed decision."
            case .typedDecisionRevised: "The local voice model revised its typed decision."
            case .splitAnswerProtocolViolation: "The local voice model returned protocol text in an answer."
            }
        }
    }

    private var prepared = false
    private var prepareTask: Task<Void, Error>?
    /// Prepared when user speech begins, then consumed by the committed turn.
    private var stagedSession: LanguageModelSession?
    private var stagingEpoch: UInt64 = 0
    private struct RequestKey: Equatable {
        let system: String
        let roles: [String]
        let contents: [String]
        let maxTokens: Int
        let nativeHistory: Bool
        let typedResponse: Bool
        let splitDecision: Bool

        init(system: String, messages: [LLMChatMessage], maxTokens: Int) {
            self.system = system
            self.roles = messages.map { $0.role.rawValue }
            self.contents = messages.enumerated().map { index, message in
                guard index == messages.count - 1, message.role == .user,
                      let marker = message.content.range(of: "Latest user speech:\n", options: .backwards)
                else { return message.content }
                let prefix = String(message.content[..<marker.upperBound])
                let speech = String(message.content[marker.upperBound...])
                return prefix + VoiceTranscriptCanonical.key(speech)
            }
            self.maxTokens = maxTokens
            self.nativeHistory = LocalVoicePrompt.isEnabled
            self.typedResponse = LocalVoiceTypedResponse.isEnabled
            self.splitDecision = LocalVoiceSplitResponse.isEnabled
        }
    }
    private struct Speculation {
        let key: RequestKey
        let epoch: UInt64
        let startedAt: Date
        let timing: GenerationTiming
        let buffer: SpeculativeVoiceBuffer
        let producer: Task<Void, Never>
    }
    /// Monotonic timing context shared by the actor and its native producer.
    /// It carries only identifiers and durations; prompts and generated text
    /// never enter the diagnostic line.
    private final class GenerationTiming: @unchecked Sendable {
        let id: UInt64
        let revision: UInt64?
        let startedAt = ContinuousClock.now
        private let cancellationLock = NSLock()
        private var cancellationInstant: ContinuousClock.Instant?

        func markCancellation() {
            cancellationLock.withLock {
                if cancellationInstant == nil { cancellationInstant = .now }
            }
        }

        var cancelledAt: ContinuousClock.Instant? {
            cancellationLock.withLock { cancellationInstant }
        }

        init(id: UInt64, revision: UInt64?) {
            self.id = id
            self.revision = revision
        }

        func elapsed() -> Double {
            Self.seconds(startedAt.duration(to: .now))
        }

        static func seconds(_ duration: Duration) -> Double {
            let components = duration.components
            return Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        }
    }
    private var nextGenerationTimingID: UInt64 = 0
    private var speculation: Speculation?
    private var sealedThroughEpoch: UInt64 = 0
    private var drainBarrier: Task<Void, Never>?
    private var nativeGeneration: Task<Void, Never>?
    private var generationForTesting: (@Sendable (String, [LLMChatMessage], Int) -> AsyncThrowingStream<String, Error>)?
    private var schedulerAcquiredObserverForTesting: (@Sendable () -> Void)?

    func setSchedulerAcquiredObserverForTesting(_ observer: (@Sendable () -> Void)?) {
        schedulerAcquiredObserverForTesting = observer
    }

    func setGenerationForTesting(
        _ generator: (@Sendable (String, [LLMChatMessage], Int) -> AsyncThrowingStream<String, Error>)?
    ) {
        cancelSpeculation()
        generationForTesting = generator
    }

    /// Prepare the next request while the person is still talking. Apple's native
    /// prewarm is prompt-specific, so the staged session carries the same instructions
    /// later used for inference. It has no prior conversation transcript.
    func stageNextTurn(system: String) async throws {
        stagingEpoch &+= 1
        let epoch = stagingEpoch
        try await prepare()
        guard epoch == stagingEpoch else { return }
        if LocalVoicePrompt.isEnabled || LocalVoiceTypedResponse.isEnabled
            || LocalVoiceSplitResponse.isEnabled {
            // A static-instructions session cannot be reused for a transcript
            // carrying role-labelled history. Keep preparation for readiness,
            // but relinquish the staged session itself.
            stagedSession = nil
            return
        }
        let session = LanguageModelSession(instructions: system)
        session.prewarm()
        stagedSession = session
    }

    func clearStagedTurn() {
        stagingEpoch &+= 1
        stagedSession = nil
        cancelSpeculation()
    }

    /// Generate against an exact provisional transcript and context snapshot.
    /// Nothing is delivered to speech or tools until a matching committed turn
    /// takes the stream. A revised ASR partial/context replaces the old work.
    func speculate(system: String, messages: [LLMChatMessage], maxTokens: Int,
                   revision: UInt64) {
        guard revision > sealedThroughEpoch else { return }
        if let speculation, speculation.epoch > revision { return }
        let key = RequestKey(system: system, messages: messages, maxTokens: maxTokens)
        if speculation?.key == key, speculation?.epoch == revision { return }
        cancelSpeculation()
        let prior = serialBarrier()
        nextGenerationTimingID &+= 1
        let timing = GenerationTiming(id: nextGenerationTimingID, revision: revision)
        let buffer = SpeculativeVoiceBuffer()
        let producer = Task {
            let barrierStarted = ContinuousClock.now
            guard await Self.waitForPriorInference(prior) else {
                Self.emitTiming(timing, "speculation_barrier_failed", durationFrom: barrierStarted)
                await buffer.complete(error: FrontendError.unavailable("Previous voice inference did not stop."))
                return
            }
            Self.emitTiming(timing, "speculation_barrier_done", durationFrom: barrierStarted)
            let stream = await self.unsharedStream(system: system, messages: messages,
                                                   maxTokens: maxTokens, drain: nil, timing: timing)
            do {
                for try await delta in stream {
                    try Task.checkCancellation()
                    await buffer.append(delta)
                }
                await buffer.complete(error: nil)
            } catch {
                await buffer.complete(error: error)
            }
        }
        speculation = Speculation(key: key, epoch: revision, startedAt: Date(), timing: timing,
                                  buffer: buffer, producer: producer)
        Self.emitTiming(timing, "speculation_started")
        traceSpeculation("started revision=\(revision)")
    }

    func cancelSpeculation() {
        if let speculation {
            traceSpeculation("canceled revision=\(speculation.epoch)")
            let canceledAt = ContinuousClock.now
            speculation.timing.markCancellation()
            Self.emitTiming(speculation.timing, "speculation_cancel_requested")
            let producer = speculation.producer
            producer.cancel()
            Task {
                await producer.value
                Self.emitTiming(speculation.timing, "cancellation_to_speculation_end",
                    durationFrom: canceledAt)
            }
            let previous = drainBarrier
            drainBarrier = Task {
                await previous?.value
                await producer.value
            }
        }
        speculation = nil
    }

    private func serialBarrier() -> Task<Void, Never>? {
        let prior = drainBarrier
        let native = nativeGeneration
        guard prior != nil || native != nil else { return nil }
        return Task {
            await prior?.value
            await native?.value
        }
    }

    /// Final transcript seals all older provisional epochs while preserving
    /// the current slot long enough for exact-message matching at commit.
    func sealSpeculation(through revision: UInt64) {
        sealedThroughEpoch = max(sealedThroughEpoch, revision)
    }

    /// A canceled debounce may arrive after a newer partial. It can only
    /// invalidate its own epoch and older work, never the newer slot.
    func cancelSpeculation(through revision: UInt64) {
        sealedThroughEpoch = max(sealedThroughEpoch, revision)
        if let speculation, speculation.epoch <= revision { cancelSpeculation() }
    }

    var unavailableReason: String? { FoundationModelFormatter.unavailableReason }

    /// Start the system model before the first spoken turn. This discarded decode is
    /// intentionally small; unlike the 4B planner, it does not pin another GGUF in RAM.
    func prepare() async throws {
        if prepared { return }
        if prepareTask == nil {
            prepareTask = Task {
                if let reason = FoundationModelFormatter.unavailableReason {
                    throw FrontendError.unavailable(reason)
                }
                let jobID = await ComputeScheduler.shared.acquire(.realtimeAgent)
                do {
                    let session = LanguageModelSession(instructions: "Answer briefly.")
                    session.prewarm()
                    let response = try await session.respond(
                        to: "Say ready.",
                        options: GenerationOptions(temperature: 0, maximumResponseTokens: 12)
                    )
                    guard !response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FrontendError.emptyResponse
                    }
                    await ComputeScheduler.shared.release(jobID)
                } catch {
                    await ComputeScheduler.shared.release(jobID)
                    throw error
                }
            }
        }
        guard let task = prepareTask else { return }
        do {
            try await task.value
            prepared = true
            prepareTask = nil
        } catch {
            prepareTask = nil
            throw error
        }
    }

    /// Streams cumulative Foundation Models snapshots as append-only deltas. The caller
    /// owns interruption and work lifecycle. Every request gets a fresh session so an
    /// interrupted answer cannot pollute the next turn's context.
    func stream(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        commitRevision: UInt64? = nil
    ) async -> AsyncThrowingStream<String, Error> {
        if let commitRevision { sealSpeculation(through: commitRevision) }
        let key = RequestKey(system: system, messages: messages, maxTokens: maxTokens)
        if let speculation, speculation.key == key {
            self.speculation = nil
            let previous = drainBarrier
            drainBarrier = Task {
                await previous?.value
                await speculation.producer.value
            }
            let lead = Date().timeIntervalSince(speculation.startedAt)
            Self.emitTiming(speculation.timing,
                String(format: "speculation_hit headstart_date_s=%.3f", lead))
            traceSpeculation(String(format: "hit revision=%llu headstart=%.3fs", speculation.epoch, lead))
            return await speculation.buffer.stream(cancelProducer: speculation.producer)
        }
        if speculation != nil { traceSpeculation("miss exact-request mismatch") }
        else { traceSpeculation("miss no-slot") }
        cancelSpeculation()
        let prior = serialBarrier()
        nextGenerationTimingID &+= 1
        let timing = GenerationTiming(id: nextGenerationTimingID, revision: commitRevision)
        Self.emitTiming(timing, "committed_stream_started")
        return await unsharedStream(system: system, messages: messages,
                                    maxTokens: maxTokens, drain: prior, timing: timing)
    }

    private static func waitForPriorInference(_ prior: Task<Void, Never>?) async -> Bool {
        guard let prior else { return true }
        let drained: Void? = await withBoundedWait(.seconds(2)) { await prior.value }
        return drained != nil
    }

    private func traceSpeculation(_ message: String) {
        Log.agent.info("Voice speculation \(message, privacy: .public)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") {
            Task { @MainActor in SelfTest.diagnostic("Voice speculation \(message)") }
        }
    }

    private static func emitTiming(
        _ timing: GenerationTiming,
        _ event: String,
        durationFrom: ContinuousClock.Instant? = nil
    ) {
        guard CommandLine.arguments.contains("--selftest-voice-pipeline") else { return }
        let revision = timing.revision.map(String.init) ?? "none"
        var message = String(format:
            "VOICE_FRONTEND_TIMING gen=%llu revision=%@ event=%@ elapsed_s=%.3f",
            timing.id, revision, event, timing.elapsed())
        if let durationFrom {
            message += String(format: " duration_s=%.3f",
                GenerationTiming.seconds(durationFrom.duration(to: .now)))
        }
        Task { @MainActor in SelfTest.diagnostic(message) }
    }

    private func unsharedStream(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        drain: Task<Void, Never>?,
        timing: GenerationTiming
    ) async -> AsyncThrowingStream<String, Error> {
        let barrierStarted = ContinuousClock.now
        guard await Self.waitForPriorInference(drain) else {
            Self.emitTiming(timing, "drain_barrier_failed", durationFrom: barrierStarted)
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: FrontendError.unavailable(
                    "Previous voice inference did not stop."))
            }
        }
        if drain != nil {
            Self.emitTiming(timing, "drain_barrier_done", durationFrom: barrierStarted)
        }
        if let generationForTesting {
            Self.emitTiming(timing, "testing_generator_returned")
            return generationForTesting(system, messages, maxTokens)
        }
        let acquiredObserver = schedulerAcquiredObserverForTesting
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task {
                defer {
                    Self.emitTiming(timing, "native_task_end", durationFrom: timing.cancelledAt)
                }
                do {
                    // A live turn cannot race an unfinished warmup in Foundation
                    // Models. Both operations share one local inference service.
                    let warmupStarted = ContinuousClock.now
                    try await self.prepare()
                    Self.emitTiming(timing, "native_warmup_done", durationFrom: warmupStarted)
                    try Task.checkCancellation()
                    let useNativeHistory = LocalVoicePrompt.isEnabled
                    let useTypedResponse = LocalVoiceTypedResponse.isEnabled
                    let useSplitDecision = LocalVoiceSplitResponse.isEnabled
                    let staged: LanguageModelSession?
                    if useNativeHistory || useTypedResponse || useSplitDecision {
                        _ = self.takeStagedSession()
                        staged = nil
                    } else {
                        staged = self.takeStagedSession()
                    }
                    let schedulerStarted = ContinuousClock.now
                    let jobID = await ComputeScheduler.shared.acquire(.realtimeAgent)
                    Self.emitTiming(timing, "scheduler_acquire_done", durationFrom: schedulerStarted)
                    acquiredObserver?()
                    do {
                        try Task.checkCancellation()
                        if let reason = FoundationModelFormatter.unavailableReason {
                            throw FrontendError.unavailable(reason)
                        }
                        let session: LanguageModelSession?
                        let prompt: String
                        let responseInstructions = useTypedResponse
                            ? LocalVoiceTypedResponse.instructions : system
                        if useSplitDecision {
                            session = nil
                            prompt = ""
                        } else if useNativeHistory {
                            guard let plan = LocalVoicePrompt.plan(system: responseInstructions, messages: messages) else {
                                throw FrontendError.unavailable("native_history_missing_latest_user")
                            }
                            session = LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: plan))
                            prompt = plan.latestUser
                        } else {
                            prompt = messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }
                                .joined(separator: "\n\n")
                            session = staged ?? LanguageModelSession(instructions: responseInstructions)
                        }
                        var produced = false
                        if useSplitDecision {
                            produced = try await Self.streamSplitDecision(
                                system: system, messages: messages, maxTokens: maxTokens, continuation: continuation,
                                timing: timing
                            )
                        } else if useTypedResponse {
                            guard let session else { throw FrontendError.typedDecisionIncomplete }
                            produced = try await Self.streamTypedResponse(
                                session: session, prompt: prompt, maxTokens: maxTokens,
                                continuation: continuation, timing: timing
                            )
                        } else {
                            guard let session else { throw FrontendError.emptyResponse }
                            let response = session.streamResponse(
                                to: prompt,
                                options: GenerationOptions(
                                    temperature: 0.2,
                                    maximumResponseTokens: maxTokens
                                )
                            )
                            var previous = ""
                            var reportedFirstAnswerText = false
                            for try await snapshot in response {
                                try Task.checkCancellation()
                                let current = snapshot.content
                                guard current.hasPrefix(previous) else {
                                    throw FrontendError.revisedSnapshot
                                }
                                // A control tag ends the generation immediately, even if
                                // Foundation Models bundled unused prose in this snapshot.
                                let stoppingPrefix = Self.controlEnvelopePrefix(current)
                                let delivered = stoppingPrefix ?? current
                                let delta = String(delivered.dropFirst(previous.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                                if !delta.isEmpty, stoppingPrefix == nil, !reportedFirstAnswerText {
                                    reportedFirstAnswerText = true
                                    Self.emitTiming(timing, "first_answer_text")
                                }
                                if !delivered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    produced = true
                                }
                                if stoppingPrefix != nil { break }
                                previous = current
                            }
                        }
                        guard produced else {
                            throw FrontendError.emptyResponse
                        }
                        await ComputeScheduler.shared.release(jobID)
                        continuation.finish()
                    } catch {
                        await ComputeScheduler.shared.release(jobID)
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
        }
        nativeGeneration = task
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination { timing.markCancellation() }
            task.cancel()
        }
        return stream
    }

    /// Resolve the two-stage route. The route is collected as a complete
    /// value before any answer text or control envelope is delivered.
    private static func streamSplitDecision(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming
    ) async throws -> Bool {
        guard let routePlan = LocalVoiceSplitResponse.routePlan(messages: messages) else {
            throw FrontendError.unavailable("split_route_missing_latest_user")
        }
        let routeSession = LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: routePlan))
        let routeStream = routeSession.streamResponse(
            to: routePlan.latestUser,
            generating: LocalVoiceRoute.self,
            options: GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: LocalVoiceSplitResponse.routeMaximumResponseTokens
            )
        )
        // `collect()` drains the stream and materializes the non-partial
        // Generable value. Partial snapshots are intentionally never routed.
        let routeCollectStarted = ContinuousClock.now
        let routeResponse = try await routeStream.collect()
        emitTiming(timing, "typed_route_collect_done", durationFrom: routeCollectStarted)
        try Task.checkCancellation()
        let route = routeResponse.content
        // Log the decision boundary, not private conversation content. A live
        // routing failure must be distinguishable from an answer-stage failure.
        Log.agent.info("voice route · \(String(describing: route.intent), privacy: .public)")
        if SelfTest.isRunning {
            print("VOICE_SPLIT_ROUTE intent=\(route.intent) task=\(route.taskNumber.map(String.init) ?? "none")")
        }

        switch route.intent {
        case .describeCapabilities:
            continuation.yield("<capabilities/>")
            return true
        case .startExternalTask:
            continuation.yield("<use_tools/>")
            return true
        case .reviseRunningTask:
            guard let taskNumber = route.taskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            continuation.yield("<revise id=\"\(taskNumber)\"/>")
            return true
        case .cancelRunningTask:
            guard let taskNumber = route.taskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            continuation.yield("<cancel id=\"\(taskNumber)\"/>")
            return true
        case .answerQuestion:
            try Task.checkCancellation()
            guard let answerPlan = LocalVoiceSplitResponse.answerPlan(
                system: system, messages: messages
            ) else {
                throw FrontendError.unavailable("split_answer_missing_latest_user")
            }
            let answerSession = LanguageModelSession(
                transcript: LocalVoicePrompt.transcript(for: answerPlan)
            )
            return try await streamSplitAnswer(
                session: answerSession, prompt: answerPlan.latestUser,
                maxTokens: maxTokens,
                continuation: continuation, timing: timing
            )
        }
    }

    /// Stream only the answer-stage prose. The envelope is owned by this
    /// frontend, so an answer-stage model cannot request an effect.
    private static func streamSplitAnswer(
        session: LanguageModelSession,
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming
    ) async throws -> Bool {
        let response = session.streamResponse(
            to: prompt,
            options: GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: maxTokens
            )
        )
        var previous = ""
        var started = false
        for try await snapshot in response {
            try Task.checkCancellation()
            let current = snapshot.content
            guard current.hasPrefix(previous) else {
                throw FrontendError.revisedSnapshot
            }
            if current.contains("<answer/>") || current.contains("<capabilities/>")
                || current.contains("<use_tools/>") || current.contains("<revise ")
                || current.contains("<cancel ") {
                throw FrontendError.splitAnswerProtocolViolation
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !started {
                    continuation.yield("<answer/>")
                    started = true
                    emitTiming(timing, "first_answer_text")
                }
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty { continuation.yield(delta) }
            }
            previous = current
        }
        guard started else { throw FrontendError.emptyResponse }
        return true
    }

    /// Consume structured snapshots without exposing the model's partial object
    /// to the coordinator. Only an answer's monotonic speech field is streamed;
    /// controls are emitted once the final intent and required task number exist.
    private static func streamTypedResponse(
        session: LanguageModelSession,
        prompt: String,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming
    ) async throws -> Bool {
        let response = session.streamResponse(
            to: prompt,
            generating: LocalVoiceDecision.self,
            options: GenerationOptions(
                temperature: 0.2,
                maximumResponseTokens: maxTokens
            )
        )
        var selectedIntent: LocalVoiceDecision.Intent?
        var latestTaskNumber: Int?
        var previousSpeech = ""
        var emittedSpeech = ""
        var reportedFirstAnswerText = false

        for try await snapshot in response {
            try Task.checkCancellation()
            let partial = snapshot.content
            if let intent = partial.intent {
                if let selectedIntent, selectedIntent != intent {
                    throw FrontendError.typedDecisionRevised
                }
                selectedIntent = intent
            }
            if let taskNumber = partial.taskNumber {
                latestTaskNumber = taskNumber
            }
            if let speech = partial.speech {
                guard speech.hasPrefix(previousSpeech) else {
                    throw FrontendError.typedDecisionRevised
                }
                previousSpeech = speech
                if selectedIntent == .answer, !speech.isEmpty {
                    if !reportedFirstAnswerText {
                        reportedFirstAnswerText = true
                        Self.emitTiming(timing, "first_answer_text")
                    }
                    if emittedSpeech.isEmpty {
                        continuation.yield("<answer/>")
                    }
                    let delta = String(speech.dropFirst(emittedSpeech.count))
                    if !delta.isEmpty { continuation.yield(delta) }
                    emittedSpeech = speech
                }
            }
        }

        guard let selectedIntent else { throw FrontendError.typedDecisionIncomplete }
        if SelfTest.isRunning {
            print("VOICE_TYPED_DECISION intent=\(selectedIntent) task=\(latestTaskNumber.map(String.init) ?? "none") speech_chars=\(previousSpeech.count)")
        }
        switch selectedIntent {
        case .answer:
            guard !previousSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FrontendError.typedDecisionIncomplete
            }
            return !emittedSpeech.isEmpty
        case .capabilities:
            continuation.yield("<capabilities/>")
            return true
        case .newWork:
            continuation.yield("<use_tools/>")
            return true
        case .revise:
            guard let taskNumber = latestTaskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            continuation.yield("<revise id=\"\(taskNumber)\"/>")
            return true
        case .cancel:
            guard let taskNumber = latestTaskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            continuation.yield("<cancel id=\"\(taskNumber)\"/>")
            return true
        }
    }

    private func takeStagedSession() -> LanguageModelSession? {
        defer { stagedSession = nil }
        return stagedSession
    }

    private static func controlEnvelopePrefix(_ text: String) -> String? {
        switch VoiceFrontendEnvelope.parse(text) {
        case .newWork, .revise, .cancel:
            guard let end = text.range(of: "/>") else { return nil }
            return String(text[..<end.upperBound])
        default:
            return nil
        }
    }
}

/// ASR may revise casing or sentence punctuation at the final transcript.
/// Keep word order, apostrophes, symbols and decimal points significant.
enum VoiceTranscriptCanonical {
    static func key(_ speech: String) -> String {
        let characters = Array(speech)
        var normalized = ""
        normalized.reserveCapacity(speech.count)
        for index in characters.indices {
            let character = characters[index]
            if character == "." || character == "?" || character == "!" {
                let decimal = character == "." && index > 0 && index + 1 < characters.count
                    && characters[index - 1].isNumber && characters[index + 1].isNumber
                normalized.append(decimal ? character : " ")
            } else {
                normalized.append(character)
            }
        }
        return normalized.lowercased().split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

/// One bounded generation's append-only deltas. At most one speculative buffer
/// exists per frontend. Registration and replay are serialized by this actor,
/// so a commit cannot miss a delta at the replay/live boundary.
private actor SpeculativeVoiceBuffer {
    private var chunks: [String] = []
    private var subscribers: [UUID: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var ended = false
    private var failure: Error?

    func append(_ chunk: String) {
        guard !ended else { return }
        chunks.append(chunk)
        for subscriber in subscribers.values { subscriber.yield(chunk) }
    }

    func complete(error: Error?) {
        guard !ended else { return }
        ended = true
        failure = error
        for subscriber in subscribers.values { subscriber.finish(throwing: error) }
        subscribers.removeAll()
    }

    func stream(cancelProducer: Task<Void, Never>) -> AsyncThrowingStream<String, Error> {
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            cancelProducer.cancel()
            Task { await self?.detach(id) }
        }
        for chunk in chunks { continuation.yield(chunk) }
        if ended {
            continuation.finish(throwing: failure)
        } else {
            subscribers[id] = continuation
        }
        return stream
    }

    private func detach(_ id: UUID) { subscribers.removeValue(forKey: id) }
}
