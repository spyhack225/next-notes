import Foundation
import FoundationModels

/// An on-device conversational lane independent of the notes/planning context.
///
/// Foundation Models owns its own inference state. A tool worker can therefore keep
/// generating with llama.cpp while this lane handles a new spoken turn. The frontend
/// receives only compact conversation and work status; it cannot perform tool effects.
actor FrontendResponder {
    static let shared = FrontendResponder()

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

    /// Exact diagnostic subprocess only. Capture once before any voice generation;
    /// the process ends after this flag, so no live model/role choice is changed.
    private var latencyAnswerProvider: (any LLMProvider)?
    func installVoiceLatencyAnswerProvider(_ provider: any LLMProvider) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency",
              LocalVoiceSplitResponse.isEnabled, latencyAnswerProvider == nil,
              nativeGeneration == nil, speculation == nil,
              provider is LlamaLLMProvider || provider is FoundationModelLLMProvider else { return false }
        latencyAnswerProvider = provider
        return true
    }
    func voiceLatencyAnswerProvider() -> (any LLMProvider)? { latencyAnswerProvider }
    nonisolated func admittedVoiceLatencyAnswerProvider() -> (any LLMProvider)? { nil }

    // RED scaffold: external native admission only; the split validator and
    // coordinator remain real. Installed only by the isolated contract flag.
    private var residentAnswerForTesting: (@Sendable () async throws -> AsyncThrowingStream<String, Error>)?
    func setResidentAnswerForTesting(
        _ answer: (@Sendable () async throws -> AsyncThrowingStream<String, Error>)?
    ) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency",
              CommandLine.arguments.contains("--voice-latency-resident-contract") else { return false }
        residentAnswerForTesting = answer
        return true
    }

    // Script only the external SDK route; validation, split answer, slot and
    // committed coordinator consumers still run through their actual seams.
    private var partialRouteForTesting: (@Sendable ([LLMChatMessage]) async throws -> LocalVoiceRoute)?
    @discardableResult
    func setPartialRouteForTesting(
        _ route: (@Sendable ([LLMChatMessage]) async throws -> LocalVoiceRoute)?
    ) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-latency",
              CommandLine.arguments.contains("--voice-latency-partials"),
              CommandLine.arguments.contains("--voice-latency-partial-route") else { return false }
        partialRouteForTesting = route
        return true
    }

    private static var partialRouteDiagnostic: Bool {
        SelfTest.isRunning && SelfTest.requested == "--selftest-voice-latency"
            && CommandLine.arguments.contains("--voice-latency-partial-route")
            && LocalVoiceSplitResponse.isEnabled
    }

    private var prepared = false
    private var prepareTask: Task<Void, Error>?
    /// Prepared when user speech begins, then consumed by the committed turn.
    private var stagedSession: LanguageModelSession?
    private var stagingEpoch: UInt64 = 0
    private struct StagedSplitTurn {
        let epoch: UInt64
        let createdAt: ContinuousClock.Instant
        let routePlan: LocalVoicePrompt.Plan
        let answerPlan: LocalVoicePrompt.Plan
        var route: LanguageModelSession?
        var answer: LanguageModelSession?
        var generation: UInt64?
    }
    private var stagedSplitTurn: StagedSplitTurn?
    enum StagedSessionKind: String, Sendable { case route, answer }
    struct StagingObservation: Sendable {
        let kind: StagedSessionKind
        let consumed: Bool
        let session: ObjectIdentifier
    }
    private var stagingObserverForTesting: (@Sendable (StagingObservation) -> Void)?
    func setStagingObserverForTesting(
        _ observer: (@Sendable (StagingObservation) -> Void)?
    ) -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-frontend",
              CommandLine.arguments.contains("--voice-frontend-stage-contract")
                || CommandLine.arguments.contains("--voice-frontend-stage-split") else { return false }
        stagingObserverForTesting = observer
        return true
    }
    /// Inspect the same take used by the SDK consumer, without starting a response.
    func takeStagedSplitSessionForTesting(
        _ kind: StagedSessionKind, system: String, messages: [LLMChatMessage],
        generation: UInt64 = 1, advancingBy duration: Duration = .zero
    ) -> ObjectIdentifier? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-frontend",
              CommandLine.arguments.contains("--voice-frontend-stage-contract") else { return nil }
        let plan = kind == .route ? LocalVoiceSplitResponse.routePlan(messages: messages)
            : LocalVoiceSplitResponse.answerPlan(system: system, messages: messages)
        guard let plan else { return nil }
        return takeStagedSplitSession(kind, plan: plan, generation: generation,
            at: .now.advanced(by: duration)).map(ObjectIdentifier.init)
    }
    private func takeStagedSplitSession(
        _ kind: StagedSessionKind, plan: LocalVoicePrompt.Plan, generation: UInt64,
        at now: ContinuousClock.Instant = .now
    ) -> LanguageModelSession? {
        guard var staged = stagedSplitTurn else { return nil }
        guard staged.epoch == stagingEpoch,
              staged.createdAt.duration(to: now) < .seconds(60),
              staged.generation == nil || staged.generation == generation else {
            stagedSplitTurn = nil
            return nil
        }
        let expected = kind == .route ? staged.routePlan : staged.answerPlan
        let session = kind == .route ? staged.route : staged.answer
        if kind == .route { staged.route = nil } else { staged.answer = nil }
        // Empty latest speech at staging is the complete application-owned prefix.
        // Only append the user's words; instructions, role history and work/approval
        // prefix must still match the plan the SDK will actually consume.
        let marker = "Latest user speech:\n"
        let prefix = plan.latestUser.range(of: marker, options: .backwards).map {
            String(plan.latestUser[..<$0.upperBound])
        }
        guard expected.instructions == plan.instructions, expected.history == plan.history,
              prefix == expected.latestUser, let session else {
            stagedSplitTurn = staged
            return nil
        }
        staged.generation = generation
        stagedSplitTurn = staged
        stagingObserverForTesting?(.init(kind: kind, consumed: true, session: ObjectIdentifier(session)))
        return session
    }
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

        /// The entire request remains exact except for a terminal courtesy.
        /// This reuses the existing complete buffer, never a route-only result.
        func matchesCommitted(_ final: RequestKey) -> Bool {
            if self == final { return true }
            guard system == final.system, roles == final.roles,
                  maxTokens == final.maxTokens, nativeHistory == final.nativeHistory,
                  typedResponse == final.typedResponse, splitDecision == final.splitDecision,
                  roles.last == LLMChatMessage.Role.user.rawValue,
                  contents.dropLast().elementsEqual(final.contents.dropLast()),
                  let before = contents.last, let after = final.contents.last,
                  before.contains("Latest user speech:\n"), after.hasPrefix(before + " ") else { return false }
            let tail = String(after.dropFirst(before.count + 1)).split(separator: " ").map(String.init)
            return tail == ["please"] || tail == ["thanks"] || tail == ["thank", "you"]
        }
    }
    private struct Speculation {
        let key: RequestKey
        let epoch: UInt64
        let startedAt: Date
        let timing: GenerationTiming
        let buffer: SpeculativeVoiceBuffer
        let producer: Task<Void, Never>
        let correlation: UsageCorrelation?
        let routeOnly: Bool
        let answerPlan: LocalVoicePrompt.Plan?
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
    /// The newest generation a later turn detached from. A producer whose own
    /// `GenerationTiming.id` is older must stop delivering text: the turn that
    /// owned it has moved on, and its consumer may not have been cancelled (a
    /// speculation buffer's reader survives the detach).
    private var abandonedGeneration: UInt64 = 0
    private var generationForTesting: (@Sendable (String, [LLMChatMessage], Int) -> AsyncThrowingStream<String, Error>)?
    private var schedulerAcquiredObserverForTesting: (@Sendable () -> Void)?
    private var retainingGenerationOwnerForTesting = false
    private var generationCaptureForTesting: (@Sendable (String) -> Void)?
    func ownedGenerationForTesting() -> Task<Void, Never>? {
        guard retainingGenerationOwnerForTesting else { return nil }
        return nativeGeneration
    }

    func setSchedulerAcquiredObserverForTesting(_ observer: (@Sendable () -> Void)?) {
        schedulerAcquiredObserverForTesting = observer
    }

    func setGenerationForTesting(
        _ generator: (@Sendable (String, [LLMChatMessage], Int) -> AsyncThrowingStream<String, Error>)?
    ) {
        cancelSpeculation()
        generationForTesting = generator
        retainingGenerationOwnerForTesting = false
        generationCaptureForTesting = nil
    }
    @discardableResult
    func setGenerationForTesting(
        _ generator: (@Sendable (String, [LLMChatMessage], Int) -> AsyncThrowingStream<String, Error>)?,
        retainingTaskOwner: Bool, fixtureRoot: URL? = nil,
        onGenerationCapture: (@Sendable (String) -> Void)? = nil
    ) -> Bool {
        if retainingTaskOwner || onGenerationCapture != nil {
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
                  let fixtureRoot, UUID(uuidString: fixtureRoot.lastPathComponent) != nil,
                  fixtureRoot.deletingLastPathComponent().standardizedFileURL.path == temp.path,
                  fixtureRoot.standardizedFileURL.path == fixtureRoot.resolvingSymlinksInPath().standardizedFileURL.path,
                  let metadata = try? fixtureRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  metadata.isDirectory == true, metadata.isSymbolicLink != true else { return false }
        }
        setGenerationForTesting(generator)
        retainingGenerationOwnerForTesting = retainingTaskOwner
        generationCaptureForTesting = onGenerationCapture
        return true
    }

    /// Prepare the complete application-owned context while the person is still
    /// talking. Split routing and answering retain separate exact transcript/prefix
    /// sessions. Legacy callers without messages retain their original static prewarm.
    func stageNextTurn(system: String, messages: [LLMChatMessage]? = nil) async throws {
        try Task.checkCancellation()
        stagingEpoch &+= 1
        let epoch = stagingEpoch
        stagedSplitTurn = nil
        if LocalVoiceSplitResponse.isEnabled, let messages {
            stagedSession = nil
            guard let routePlan = LocalVoiceSplitResponse.routePlan(messages: messages),
                  let answerPlan = LocalVoiceSplitResponse.answerPlan(system: system, messages: messages),
                  routePlan.latestUser.hasSuffix("Latest user speech:\n"),
                  answerPlan.latestUser.hasSuffix("Latest user speech:\n") else { return }
            if let reason = FoundationModelFormatter.unavailableReason {
                throw FrontendError.unavailable(reason)
            }
            // SDK prewarm builds only these exact transcript/prompt prefixes. It
            // starts no app inference, compute ticket, answer stream or tool effect.
            let route = LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: routePlan))
            route.prewarm(promptPrefix: Prompt(routePlan.latestUser))
            let answer: LanguageModelSession?
            if latencyAnswerProvider is LlamaLLMProvider {
                answer = nil
            } else {
                let session = LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: answerPlan))
                session.prewarm(promptPrefix: Prompt(answerPlan.latestUser))
                answer = session
            }
            try Task.checkCancellation()
            guard epoch == stagingEpoch else { return }
            stagedSplitTurn = StagedSplitTurn(epoch: epoch, createdAt: .now,
                routePlan: routePlan, answerPlan: answerPlan, route: route, answer: answer)
            stagingObserverForTesting?(.init(kind: .route, consumed: false, session: ObjectIdentifier(route)))
            if let answer {
                stagingObserverForTesting?(.init(kind: .answer, consumed: false, session: ObjectIdentifier(answer)))
            }
            return
        }
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
        stagedSplitTurn = nil
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
        if speculation?.key == key, speculation?.epoch == revision,
           speculation?.correlation == ModelPassRecorder.correlation { return }
        cancelSpeculation()
        let prior = serialBarrier()
        nextGenerationTimingID &+= 1
        let timing = GenerationTiming(id: nextGenerationTimingID, revision: revision)
        let buffer = SpeculativeVoiceBuffer()
        let routeOnly = Self.partialRouteDiagnostic
        let correlation = ModelPassRecorder.correlation
        let producer = Task {
            let barrierStarted = ContinuousClock.now
            guard await Self.waitForPriorInference(prior) else {
                Self.emitTiming(timing, "speculation_barrier_failed", durationFrom: barrierStarted)
                await buffer.complete(error: FrontendError.unavailable("Previous voice inference did not stop."))
                return
            }
            Self.emitTiming(timing, "speculation_barrier_done", durationFrom: barrierStarted)
            if routeOnly, CommandLine.arguments.contains("--voice-latency-prefill"),
               self.latencyAnswerProvider is LlamaLLMProvider {
                // Diagnostic-only child of this same producer. Complete its route
                // buffer before joining preparation; commit never waits on this join.
                async let prefilling: Void = self.preparePartialAnswer(
                    system: system, messages: messages, maxTokens: maxTokens, timing: timing)
                await self.fillSpeculativeBuffer(buffer, system: system, messages: messages,
                    maxTokens: maxTokens, timing: timing, routeOnly: routeOnly)
                _ = await prefilling
            } else {
                await self.fillSpeculativeBuffer(buffer, system: system, messages: messages,
                    maxTokens: maxTokens, timing: timing, routeOnly: routeOnly)
            }
        }
        speculation = Speculation(key: key, epoch: revision, startedAt: Date(), timing: timing,
                                  buffer: buffer, producer: producer, correlation: correlation, routeOnly: routeOnly,
                                  answerPlan: routeOnly ? LocalVoiceSplitResponse.answerPlan(system: system, messages: messages) : nil)
        Self.emitTiming(timing, "speculation_started")
        traceSpeculation("started revision=\(revision)")
    }

    func cancelSpeculation() {
        if let speculation {
            // The cancelled route was used with provisional speech. Its independent
            // answer has only been prewarmed, unless it was actually taken. Retain
            // that untouched session; the final take still checks exact context,
            // epoch and age. Never reuse a session whose answer inference started.
            if var staged = stagedSplitTurn, staged.generation == speculation.timing.id {
                staged.route = nil
                staged.generation = nil
                stagedSplitTurn = staged.answer == nil ? nil : staged
            }
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
                guard let jobID = await ComputeScheduler.shared.acquireCancellable(.realtimeAgent) else {
                    throw CancellationError()
                }
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

    /// Fresh result-only session on this SAME inference owner. Capture before
    /// even the prompt hop: a newer request during any await keeps its generation.
    func phrase(_ batch: [DeliveryItem], carriedOver: Bool) async -> String? {
        guard !batch.isEmpty, batch.allSatisfy({ $0.kind.priority == .result }),
              generationForTesting != nil || FoundationModelFormatter.unavailableReason == nil else { return nil }
        let prior = serialBarrier()
        nextGenerationTimingID &+= 1
        let timing = GenerationTiming(id: nextGenerationTimingID, revision: nil)
        generationCaptureForTesting?("phrase")
        let request = await MainActor.run {
            (AgentDeliveryPrompts.resultInstructions(carriedOver: carriedOver), AgentDeliveryPrompts.facts(batch))
        }
        // No turn routing, speculative slot or staged conversation is consumed.
        guard !Task.isCancelled, timing.id == nextGenerationTimingID,
              await Self.waitForPriorInference(prior), !Task.isCancelled,
              timing.id == nextGenerationTimingID else { return nil }
        let stream = await unsharedStream(system: request.0, messages: [.init(role: .user, content: request.1)],
            maxTokens: 120, drain: nil, timing: timing, deliveryPhrase: true)
        do {
            var raw = ""
            for try await delta in stream {
                try Task.checkCancellation()
                raw += delta
            }
            try Task.checkCancellation()
            return await MainActor.run { AgentDeliveryPrompts.acceptedPhrase(raw) }
        } catch { return nil }
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
        if let speculation, (speculation.routeOnly ? speculation.key == key : speculation.key.matchesCommitted(key)),
           speculation.correlation == ModelPassRecorder.correlation {
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
            VoiceLatencyTimeline.shared.note("speculation",
                String(format: "hit headstart=%.3f", lead))
            let buffered = await speculation.buffer.stream(cancelProducer: speculation.producer)
            if speculation.routeOnly {
                return resumePreparedRoute(buffered, speculation: speculation, maxTokens: maxTokens)
            }
            return buffered
        }
        if let speculation {
            let reason = speculation.key == key ? "correlation" : "mismatch"
            traceSpeculation("miss request/identity \(reason)")
            VoiceLatencyTimeline.shared.note("speculation", "miss reason=\(reason)")
        } else {
            traceSpeculation("miss no-slot")
            VoiceLatencyTimeline.shared.note("speculation", "miss reason=no-slot")
        }
        cancelSpeculation()
        let prior = serialBarrier()
        nextGenerationTimingID &+= 1
        let timing = GenerationTiming(id: nextGenerationTimingID, revision: commitRevision)
        generationCaptureForTesting?("request")
        Self.emitTiming(timing, "committed_stream_started")
        return await unsharedStream(system: system, messages: messages,
                                    maxTokens: maxTokens, drain: prior, timing: timing)
    }

    /// A matching commit consumes the existing route buffer asynchronously. A
    /// pending route continues once; no speculative-task join is added to commit.
    /// The same nativeGeneration/drain owner now tracks the committed answer.
    private func resumePreparedRoute(
        _ buffered: AsyncThrowingStream<String, Error>, speculation: Speculation,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let timing = speculation.timing
        let producer = speculation.producer
        let answerPlan = speculation.answerPlan
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task {
            defer { Self.emitTiming(timing, "prepared_route_consumer_end", durationFrom: timing.cancelledAt) }
            do {
                var received = false
                for try await chunk in buffered {
                    try Task.checkCancellation()
                    guard !received, mayDeliver(timing) else { throw FrontendError.typedDecisionIncomplete }
                    received = true
                    if case .answer(let tail) = VoiceFrontendEnvelope.parse(chunk), tail.isEmpty {
                        guard let plan = answerPlan else {
                            throw FrontendError.unavailable("split_answer_missing_latest_user")
                        }
                        let staged = latencyAnswerProvider is LlamaLLMProvider ? nil
                            : takeStagedSplitSession(.answer, plan: plan, generation: timing.id)
                        let session = latencyAnswerProvider is LlamaLLMProvider ? nil
                            : (staged ?? LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: plan)))
                        VoiceLatencyTimeline.shared.note("answer_staging", latencyAnswerProvider is LlamaLLMProvider ? "native" : staged == nil ? "fresh" : "staged")
                        Self.emitTiming(timing, "partial_route_committed_answer")
                        guard try await streamSplitAnswer(session: session, plan: plan, maxTokens: maxTokens,
                            continuation: continuation, timing: timing) else { throw FrontendError.emptyResponse }
                    } else {
                        switch VoiceFrontendEnvelope.parse(chunk) {
                        case .capabilities, .newWork, .decision, .revise, .cancel, .status, .notAddressed:
                            continuation.yield(chunk)
                        default: throw FrontendError.typedDecisionIncomplete
                        }
                    }
                }
                guard received else { throw FrontendError.typedDecisionIncomplete }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        nativeGeneration = task
        continuation.onTermination = { @Sendable termination in
            if case .cancelled = termination { timing.markCancellation() }
            task.cancel()
            producer.cancel()
        }
        return stream
    }

    private func fillSpeculativeBuffer(
        _ buffer: SpeculativeVoiceBuffer, system: String, messages: [LLMChatMessage],
        maxTokens: Int, timing: GenerationTiming, routeOnly: Bool
    ) async {
        let stream = await unsharedStream(system: system, messages: messages,
            maxTokens: maxTokens, drain: nil, timing: timing, routeOnly: routeOnly)
        do {
            for try await delta in stream {
                try Task.checkCancellation()
                guard timing.id >= abandonedGeneration else { break }
                await buffer.append(delta)
            }
            await buffer.complete(error: nil)
        } catch {
            await buffer.complete(error: error)
        }
    }

    private func preparePartialAnswer(
        system: String, messages: [LLMChatMessage], maxTokens: Int, timing: GenerationTiming
    ) async {
        guard Self.partialRouteDiagnostic,
              CommandLine.arguments.contains("--voice-latency-prefill"),
              let local = latencyAnswerProvider as? LlamaLLMProvider,
              let plan = LocalVoiceSplitResponse.answerPlan(system: system, messages: messages) else { return }
        let answerMessages = plan.history.map { LLMChatMessage(role: $0.role, content: $0.content) }
            + [LLMChatMessage(role: .user, content: plan.latestUser)]
        Self.emitTiming(timing, "prefill_handoff")
        do {
            let stats = try await local.runtime.prepareInteractiveConversation(
                system: plan.instructions, messages: answerMessages, maxTokens: maxTokens,
                residentOnly: true, onAdmitted: { Self.emitTiming(timing, "prefill_native_admitted") })
            Self.emitTiming(timing, "prefill_done prompt=\(stats.promptTokens) reused=\(stats.reused) decoded=\(stats.decoded) native_s=\(stats.seconds)")
        } catch LlamaError.notLoaded {
            Self.emitTiming(timing, "prefill_skip_not_prepared")
        } catch {
            // Failed/cancelled preparation is never an answer or routing success.
            // The committed stream revalidates through its original runtime entry.
            Self.emitTiming(timing, error is CancellationError ? "prefill_cancelled" : "prefill_failed")
        }
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
        guard CommandLine.arguments.contains("--selftest-voice-pipeline")
                || SelfTest.requested == "--selftest-voice-latency" else { return }
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
        timing: GenerationTiming,
        deliveryPhrase: Bool = false, routeOnly: Bool = false
    ) async -> AsyncThrowingStream<String, Error> {
        let barrierStarted = ContinuousClock.now
        let drained = await Self.waitForPriorInference(drain)
        // Cancellation is not a drain timeout: retain the actual entered owner
        // and do not create inference for a request whose consumer has gone.
        guard !Task.isCancelled else {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        if drained {
            if drain != nil {
                Self.emitTiming(timing, "drain_barrier_done", durationFrom: barrierStarted)
            }
        } else {
            // The prior inference did not stop inside the barrier. A live turn cannot
            // wait for it: detach rather than fail. Nothing the abandoned producer
            // yields from here on is delivered, and this turn runs on a fresh session
            // — Apple FM sessions share no inference state, so the old one is never
            // reused and the old native task is never awaited.
            abandonedGeneration = timing.id
            Self.emitTiming(timing, "drain_barrier_detached", durationFrom: barrierStarted)
            drainBarrier = nil
            nativeGeneration = nil
        }
        if deliveryPhrase, timing.id != nextGenerationTimingID {
            return AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
        }
        if let generationForTesting, !retainingGenerationOwnerForTesting, partialRouteForTesting == nil {
            Self.emitTiming(timing, "testing_generator_returned")
            return generationForTesting(system, messages, maxTokens)
        }
        let acquiredObserver = schedulerAcquiredObserverForTesting
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let ownedTestingGenerator = retainingGenerationOwnerForTesting ? generationForTesting : nil
        let task = Task {
                defer {
                    Self.emitTiming(timing, "native_task_end", durationFrom: timing.cancelledAt)
                }
                do {
                    // A live turn cannot race an unfinished warmup in Foundation
                    // Models. Both operations share one local inference service.
                    let warmupStarted = ContinuousClock.now
                    if ownedTestingGenerator == nil, partialRouteForTesting == nil {
                        if deliveryPhrase {
                            // Join an already-owned warmup, but do not add a discarded
                            // preparation inference to a delivery phrase.
                            try await self.prepareTask?.value
                        } else { try await self.prepare() }
                    }
                    Self.emitTiming(timing, "native_warmup_done", durationFrom: warmupStarted)
                    try Task.checkCancellation()
                    if deliveryPhrase, timing.id != nextGenerationTimingID { throw CancellationError() }
                    let useNativeHistory = !deliveryPhrase && LocalVoicePrompt.isEnabled
                    let useTypedResponse = !deliveryPhrase && LocalVoiceTypedResponse.isEnabled
                    let useSplitDecision = !deliveryPhrase && LocalVoiceSplitResponse.isEnabled
                    let staged: LanguageModelSession?
                    if deliveryPhrase {
                        staged = nil
                    } else if useNativeHistory || useTypedResponse || useSplitDecision {
                        _ = self.takeStagedSession()
                        staged = nil
                    } else {
                        staged = self.takeStagedSession()
                    }
                    let schedulerStarted = ContinuousClock.now
                    // Split routing is an independent Apple session. It owns no
                    // llama context and must not park local work while Apple collects.
                    // Legacy/phrase modes keep their existing compute policy.
                    let jobID: UUID?
                    if useSplitDecision {
                        jobID = nil
                    } else {
                        guard let acquired = await ComputeScheduler.shared.acquireCancellable(.realtimeAgent) else {
                            throw CancellationError()
                        }
                        jobID = acquired
                        Self.emitTiming(timing, "scheduler_acquire_done", durationFrom: schedulerStarted)
                        VoiceLatencyTimeline.shared.mark(.schedulerAcquired)
                        acquiredObserver?()
                    }
                    do {
                        try Task.checkCancellation()
                        if deliveryPhrase, timing.id != nextGenerationTimingID { throw CancellationError() }
                        // Replace only the external generator AFTER the actual
                        // frontend admission, inside its retained/cancelable Task.
                        // Authored streams are not Apple kernel or timing evidence.
                        if let ownedTestingGenerator {
                            if useSplitDecision, timing.id == nextGenerationTimingID {
                                VoiceLatencyTimeline.shared.mark(.routeStarted)
                            }
                            for try await delta in ownedTestingGenerator(system, messages, maxTokens) {
                                try Task.checkCancellation()
                                if mayDeliver(timing) { continuation.yield(delta) }
                            }
                            if let jobID { await ComputeScheduler.shared.release(jobID) }
                            if useSplitDecision, timing.id == nextGenerationTimingID {
                                VoiceLatencyTimeline.shared.mark(.routeDone)
                            }
                            continuation.finish()
                            return
                        }
                        if partialRouteForTesting == nil, let reason = FoundationModelFormatter.unavailableReason {
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
                            produced = try await self.streamSplitDecision(
                                system: system, messages: messages, maxTokens: maxTokens, continuation: continuation,
                                timing: timing, schedulerJob: jobID, routeOnly: routeOnly
                            )
                        } else if useTypedResponse {
                            guard let session else { throw FrontendError.typedDecisionIncomplete }
                            produced = try await self.streamTypedResponse(
                                session: session, prompt: prompt, maxTokens: maxTokens,
                                continuation: continuation, timing: timing
                            )
                        } else {
                            guard let session else { throw FrontendError.emptyResponse }
                            let response = session.streamResponse(
                                to: prompt,
                                options: GenerationOptions(
                                    temperature: deliveryPhrase ? 0.3 : 0.2,
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
                                if !delta.isEmpty, mayDeliver(timing) { continuation.yield(delta) }
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
                        if let jobID { await ComputeScheduler.shared.release(jobID) }
                        continuation.finish()
                    } catch {
                        if let jobID { await ComputeScheduler.shared.release(jobID) }
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
    ///
    /// P0-20a: one `agent.voice`/`frontend-route` row per route pass.
    private func streamSplitDecision(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming, schedulerJob: UUID?, routeOnly: Bool = false
    ) async throws -> Bool {
        let recorder = ModelPassRecorder(
            feature: .agentVoice, pass: "frontend-route",
            provider: FoundationModelLLMProvider(),
            ids: ModelPassRecorder.correlation ?? UsageCorrelation(),
            requestedRole: nil)
        do {
            let produced = try await streamSplitDecisionBody(
                system: system, messages: messages, maxTokens: maxTokens,
                continuation: continuation, timing: timing, schedulerJob: schedulerJob, routeOnly: routeOnly)
            recorder.finish(reason: "stop")
            return produced
        } catch {
            recorder.fail(error)
            recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
            throw error
        }
    }

    private func streamSplitDecisionBody(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming, schedulerJob: UUID?, routeOnly: Bool = false
    ) async throws -> Bool {
        guard let routePlan = LocalVoiceSplitResponse.routePlan(messages: messages) else {
            throw FrontendError.unavailable("split_route_missing_latest_user")
        }
        let route: LocalVoiceRoute
        if let partialRouteForTesting {
            if timing.id == nextGenerationTimingID { VoiceLatencyTimeline.shared.mark(.routeStarted) }
            route = try await partialRouteForTesting(messages)
            try Task.checkCancellation()
            if timing.id == nextGenerationTimingID { VoiceLatencyTimeline.shared.mark(.routeDone) }
        } else {
            let stagedRoute = takeStagedSplitSession(.route, plan: routePlan, generation: timing.id)
            let routeSession = stagedRoute ?? LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: routePlan))
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("route_staging", stagedRoute == nil ? "fresh" : "staged")
                VoiceLatencyTimeline.shared.note("answer_staging", "not_requested")
            }
            Self.emitTiming(timing, stagedRoute == nil ? "route_session_fresh" : "route_session_staged")
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.mark(.routeStarted)
            }
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
            Self.emitTiming(timing, "typed_route_collect_done", durationFrom: routeCollectStarted)
            try Task.checkCancellation()
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.mark(.routeDone)
            }
            route = routeResponse.content
        }
        // Log the decision boundary, not private conversation content. A live
        // routing failure must be distinguishable from an answer-stage failure.
        Log.agent.info("voice route · \(String(describing: route.intent), privacy: .public)")
        if SelfTest.isRunning {
            print("VOICE_SPLIT_ROUTE intent=\(route.intent) task=\(route.taskNumber.map(String.init) ?? "none")")
        }

        let payload: FrontendDecisionPayload
        switch route.intent {
        case .describeCapabilities: payload = FrontendDecisionPayload(intent: "capabilities")
        case .startExternalTask:
            guard let value = FrontendToolContract.payload(.spawn, arguments: .init(objective: route.objective), acknowledgement: route.acknowledgement) else { throw FrontendError.typedDecisionIncomplete }
            payload = value
        case .reviseRunningTask:
            guard let number = route.taskNumber, number > 0 else { throw FrontendError.typedDecisionIncomplete }
            payload = FrontendDecisionPayload(intent: "revise", taskNumber: number, objective: route.objective)
        case .cancelRunningTask:
            guard let value = FrontendToolContract.payload(.cancel, arguments: .init(task: route.taskNumber)) else { throw FrontendError.typedDecisionIncomplete }
            payload = value
        case .checkTaskStatus:
            guard let value = FrontendToolContract.payload(.status, arguments: .init(task: route.taskNumber)) else { throw FrontendError.typedDecisionIncomplete }
            payload = value
        case .answerApproval:
            let change = route.approvalChange.isEmpty ? nil : route.approvalChange
            guard let value = FrontendToolContract.payload(.approval, arguments: .init(decision: route.approvalDecision, change: change)) else { throw FrontendError.typedDecisionIncomplete }
            payload = value
        case .notAddressedToMe: payload = FrontendDecisionPayload(intent: "not_addressed")
        case .answerQuestion: payload = FrontendDecisionPayload(intent: "answer")
        }
        if routeOnly {
            // End this same native producer with one COMPLETE validated route in
            // the existing buffer. Hold no task/ticket/reservation waiting for EOU.
            Self.emitTiming(timing, "partial_route_ready")
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("partial_route_ready_nanos", String(VoiceLatencyTimeline.nowNanos()))
            }
            if mayDeliver(timing) { continuation.yield(try payload.controlChunk()) }
            return true
        }
        switch route.intent {
        case .describeCapabilities, .startExternalTask, .reviseRunningTask, .cancelRunningTask, .checkTaskStatus, .answerApproval, .notAddressedToMe:
            if mayDeliver(timing) { continuation.yield(try payload.controlChunk()) }
            return true
        case .answerQuestion:
            try Task.checkCancellation()
            guard let answerPlan = LocalVoiceSplitResponse.answerPlan(
                system: system, messages: messages
            ) else {
                throw FrontendError.unavailable("split_answer_missing_latest_user")
            }
            if latencyAnswerProvider is LlamaLLMProvider, let schedulerJob {
                // Defensive for a caller retaining a legacy ticket: native answers
                // acquire their own existing context reservation and compute lane.
                await ComputeScheduler.shared.release(schedulerJob)
            }
            let stagedAnswer = latencyAnswerProvider is LlamaLLMProvider ? nil
                : takeStagedSplitSession(.answer, plan: answerPlan, generation: timing.id)
            let answerSession = latencyAnswerProvider is LlamaLLMProvider ? nil
                : (stagedAnswer ?? LanguageModelSession(transcript: LocalVoicePrompt.transcript(for: answerPlan)))
            let answerStaging = latencyAnswerProvider is LlamaLLMProvider ? "native"
                : stagedAnswer == nil ? "fresh" : "staged"
            if timing.id == nextGenerationTimingID {
                VoiceLatencyTimeline.shared.note("answer_staging", answerStaging)
            }
            Self.emitTiming(timing, "answer_session_" + answerStaging)
            return try await streamSplitAnswer(
                session: answerSession, plan: answerPlan,
                maxTokens: maxTokens,
                continuation: continuation, timing: timing
            )
        }
    }

    /// Stream only the answer-stage prose. The envelope is owned by this
    /// frontend, so an answer-stage model cannot request an effect.
    ///
    /// P0-20a: one `agent.voice`/`frontend-answer` row per answer pass.
    private func streamSplitAnswer(
        session: LanguageModelSession?, plan: LocalVoicePrompt.Plan,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming
    ) async throws -> Bool {
        let provider = latencyAnswerProvider ?? FoundationModelLLMProvider()
        let recorder = ModelPassRecorder(
            feature: .agentVoice, pass: "frontend-answer",
            provider: provider,
            ids: ModelPassRecorder.correlation ?? UsageCorrelation(),
            requestedRole: nil)
        do {
            let produced = try await streamSplitAnswerBody(
                session: session, plan: plan, provider: provider, maxTokens: maxTokens,
                continuation: continuation, timing: timing, recorder: recorder)
            recorder.finish(reason: "stop")
            return produced
        } catch {
            recorder.fail(error)
            recorder.finish(reason: error is CancellationError ? "cancelled" : "error")
            throw error
        }
    }

    private func streamSplitAnswerBody(
        session: LanguageModelSession?, plan: LocalVoicePrompt.Plan,
        provider: any LLMProvider,
        maxTokens: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation,
        timing: GenerationTiming,
        recorder: ModelPassRecorder
    ) async throws -> Bool {
        var previous = ""
        var started = false
        func consume(_ current: String) throws {
            try Task.checkCancellation()
            guard current.hasPrefix(previous) else {
                throw FrontendError.revisedSnapshot
            }
            if current.contains("<decision>") || current.contains("</decision>") || current.contains("<status") || current.contains("<answer/>") || current.contains("<capabilities/>")
                || current.contains("<use_tools/>") || current.contains("<revise ")
                || current.contains("<cancel ") {
                throw FrontendError.splitAnswerProtocolViolation
            }
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !started {
                    recorder.noteFirstToken()
                    if mayDeliver(timing) { continuation.yield(try FrontendDecisionPayload(intent: "answer").controlChunk()) }
                    started = true
                    Self.emitTiming(timing, "first_answer_text")
                }
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty, mayDeliver(timing) { continuation.yield(delta) }
            }
            previous = current
        }
        if partialRouteForTesting != nil, let generationForTesting {
            let messages = plan.history.map { LLMChatMessage(role: $0.role, content: $0.content) }
                + [LLMChatMessage(role: .user, content: plan.latestUser)]
            var current = ""
            for try await delta in generationForTesting(plan.instructions, messages, maxTokens) {
                current += delta
                try consume(current)
            }
        } else if let local = provider as? LlamaLLMProvider {
            let messages = plan.history.map { LLMChatMessage(role: $0.role, content: $0.content) }
                + [LLMChatMessage(role: .user, content: plan.latestUser)]
            // The runtime's producer Task inherits this recorder at stream creation,
            // as in the existing tool loop. Consume text on this same actor afterwards.
            let response = await ModelPassRecorder.$current.withValue(recorder) {
                await local.streamInteractiveConversation(
                    system: plan.instructions, messages: messages, maxTokens: maxTokens)
            }
            var current = ""
            for try await delta in response {
                current += delta
                try consume(current)
            }
        } else {
            guard let session else { throw FrontendError.emptyResponse }
            let response = session.streamResponse(
                to: plan.latestUser,
                options: GenerationOptions(temperature: 0.2, maximumResponseTokens: maxTokens))
            for try await snapshot in response { try consume(snapshot.content) }
            guard started else { throw FrontendError.emptyResponse }
            recorder.report(
                promptTokens: max(1, plan.latestUser.count / 4),
                cachedTokens: nil,
                completionTokens: max(1, previous.count / 4),
                reasoningTokens: nil,
                finishReason: nil,
                estimated: true)
        }
        guard started else { throw FrontendError.emptyResponse }
        return true
    }

    /// Consume structured snapshots without exposing the model's partial object
    /// to the coordinator. Only an answer's monotonic speech field is streamed;
    /// controls are emitted once the final intent and required task number exist.
    private func streamTypedResponse(
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
                        if mayDeliver(timing) { continuation.yield("<answer/>") }
                    }
                    let delta = String(speech.dropFirst(emittedSpeech.count))
                    if !delta.isEmpty, mayDeliver(timing) { continuation.yield(delta) }
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
            if mayDeliver(timing) { continuation.yield("<capabilities/>") }
            return true
        case .newWork:
            if mayDeliver(timing) { continuation.yield("<use_tools/>") }
            return true
        case .revise:
            guard let taskNumber = latestTaskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            if mayDeliver(timing) { continuation.yield("<revise id=\"\(taskNumber)\"/>") }
            return true
        case .cancel:
            guard let taskNumber = latestTaskNumber, taskNumber > 0 else {
                throw FrontendError.typedDecisionIncomplete
            }
            if mayDeliver(timing) { continuation.yield("<cancel id=\"\(taskNumber)\"/>") }
            return true
        }
    }

    /// False once a later turn has detached from this generation: the producer
    /// must stop delivering text, because the turn that owned it has moved on.
    private func mayDeliver(_ timing: GenerationTiming) -> Bool {
        timing.id >= abandonedGeneration
    }

    private func takeStagedSession() -> LanguageModelSession? {
        defer { stagedSession = nil }
        return stagedSession
    }

    private static func controlEnvelopePrefix(_ text: String) -> String? {
        switch VoiceFrontendEnvelope.parse(text) {
        case .newWork, .revise, .cancel, .status:
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
