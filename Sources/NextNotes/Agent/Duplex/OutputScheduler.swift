import Foundation

/// Capability for the SAME physical output. Only the scheduler mints its ID.
struct OutputToken: Sendable {
    let output: OutputID
    fileprivate init(_ output: OutputID) { self.output = output }
}
/// A streamed response retains its own capability through later model callbacks.
@MainActor
struct OutputHandle {
    let output: OutputID
    fileprivate let token: OutputToken
    func append(_ text: String) { RealtimeAudioSession.shared.appendSpokenReply(token, text) }
    func finish() { RealtimeAudioSession.shared.finalizeSpokenReply(token) }
    func cancel() { RealtimeAudioSession.shared.cancelSpokenReply(token) }
}

enum AgentDeliveryMode: String, Sendable, Codable { case context, respond, interrupt }
enum OutputPriority: Int, Comparable, Sendable, Codable {
    case turnReply = 0, approvalPrompt = 1, taskQuestion = 2, result = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
enum DeliveryKind: Sendable, Equatable, Codable {
    case result, failure, cancelled, question, approval(requestID: String)
    var priority: OutputPriority {
        switch self {
        case .approval: .approvalPrompt
        case .question: .taskQuestion
        default: .result
        }
    }
}
struct DeliveryItem: Sendable, Equatable, Codable {
    let task: TaskID
    let kind: DeliveryKind
    let title: String
    let facts: String
    let enqueuedAt: Date
    var attempts: Int
    var carriedOver: Bool
}
/// Existing values are work-independent presentation facts, never effect authority.
enum TaskDeliveryAdmission {
    static func permits(from: TaskDelivery?, to: TaskDelivery) -> Bool {
        if from == to { return true }
        switch to {
        case .none: return false // Historical absence cannot reset positive delivery evidence.
        case .pending: return from == nil || from == TaskDelivery.none || from == .delivering || from == .delivered
        case .delivering: return from == .pending
        case .delivered: return from == .delivering
        case .deliveredInContext: return from == .pending || from == .delivering || from == .delivered
        case .consumedByStatus: return from == .pending
        case .silent: return from == nil || from == TaskDelivery.none || from == .pending
        case .failed: return from == .delivering || from == .delivered
        }
    }
}

/// P3-04a bounded owner foundation. The existing capture tick opens opportunities;
/// shadow reducer commands do not drive physical output. One list replaces the old
/// announcement list. Unbound compatibility announcements retain their old policy.
@MainActor
final class OutputScheduler {
    static let shared = OutputScheduler(bridge: nil)
    private let suppliedBridge: TaskBridge?
    private var bridge: TaskBridge { suppliedBridge ?? .shared }
    private struct Entry {
        var item: DeliveryItem?
        let text: String
        var eligibleAt: Date
        var legacyClauses: [String]?
        var question: TaskInputRequest? = nil
        var recipient: UUID? = nil
        var approvalID: String? = nil
        /// SAME retained batch whose heard-context primary transition was refused.
        var contextDeliveryPending = false
        /// Availability recovery alone cannot replay a written-only old update.
        var requiresExplicitReplay = false
    }
    private struct Active {
        var id: OutputID?
        var entries: [Entry]
        var generation: UInt64?
        var queued = 0
        var heard = false
        var byUser = false
        var approvalRemaining: [String] = []
        var approvalMatchesWholePrompt = false
    }
    private var queue: [Entry] = []
    private var active: Active?
    private var lastFloorAt: Date?
    private var lastOutputEndAt: Date?
    private var phraseTask: Task<Void, Never>?
    private var phrasingEntries: [Entry]?
    private var phraseOverrideForTesting: (@MainActor @Sendable ([DeliveryItem]) async -> String?)?
    // Default nil; exact confined diagnostic only. Observes SAME entered Task,
    // before a cancellation can clear its existing owner slot.
    private var phraseTaskObserverForTesting: (@MainActor (Task<Void, Never>) -> Void)?
    @discardableResult
    func observePhraseTaskForTesting(_ observer: (@MainActor (Task<Void, Never>) -> Void)?) -> Bool {
        guard SelfTest.isRunning, ["--selftest-voice-duplex-work", "--selftest-island"].contains(SelfTest.requested ?? ""),
              suppliedBridge?.permitsHarness == true else { return false }
        phraseTaskObserverForTesting = observer; return true
    }
    func setPhraseForTesting(_ phrase: (@MainActor @Sendable ([DeliveryItem]) async -> String?)?) {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island", "--selftest-voice-duplex-work"].contains(SelfTest.requested ?? ""), bridge.permitsHarness else { return }
        phraseOverrideForTesting = phrase
    }
    /// Diagnostic join of the actual existing phrase Task; ordinary flush is
    /// synchronous and no user turn waits on this method.
    func flushAndJoinForTesting(userHasFloor: Bool) async -> Bool {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island"].contains(SelfTest.requested ?? ""), bridge.permitsHarness else { return false }
        let admitted = flush(userHasFloor: userHasFloor)
        let owned = phraseTask
        await owned?.value
        return admitted
    }
    var ownedPhraseTaskForTesting: Task<Void, Never>? {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island"].contains(SelfTest.requested ?? ""), bridge.permitsHarness else { return nil }
        return phraseTask
    }
    private var nowForTesting: Date?
    private init(bridge: TaskBridge?) { suppliedBridge = bridge }
    static func isolatedForTesting(_ bridge: TaskBridge) -> OutputScheduler? {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-work-lifecycle", "--selftest-voice-turn-routing", "--selftest-island", "--selftest-voice-duplex-work"].contains(SelfTest.requested ?? ""), bridge.permitsHarness else { return nil }
        return OutputScheduler(bridge: bridge)
    }
    func setNowForTesting(_ date: Date?) {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island"].contains(SelfTest.requested ?? ""), bridge.permitsHarness else { return }
        nowForTesting = date
    }
    private var now: Date { nowForTesting ?? Date() }
    var permitsHarness: Bool { bridge.permitsHarness }
    var pendingCount: Int { queue.count }
    var activeOutputID: OutputID? { active?.id }

    /// One audio-start owner for pre-rendered committed-turn acknowledgements too.
    func acknowledgeCommitted(_ turn: TurnID, text: String, interaction: Bool) {
        VoiceAcknowledgement.shared.commit(turn, text: text, interaction: interaction)
    }

    /// Starts the existing streaming buffer synchronously; no model or audio wait.
    func beginAnswer(turn: TurnID?) -> OutputHandle {
        // Decide delivery priority before the SAME buffer's clear emits stop
        // callbacks. Phrasing restores unheard entries through its existing seam.
        cancelPhrasing()
        if let current = active,
           current.id == RealtimeAudioSession.shared.retainedOutputID,
           current.generation == AgentSpeechSynthesizer.shared.outputGeneration,
           current.entries.allSatisfy({ $0.item?.kind.priority == .result }) {
            let committed = turn.map {
                AgentCaptureController.shared.isSessionActive
                    && VoiceSession.shared.state.phase == .open
                    && VoiceSession.shared.state.lastCommittedTurn == $0
                    && VoiceSession.shared.currentTurn() == $0
            } ?? false
            if !current.heard || committed {
                active = nil
                lastOutputEndAt = now
                if current.heard {
                    // UI visibility, a reserved ID or a nil-turn stream supplies
                    // no committed-turn authority. This branch has the real turn.
                    if !bridge.setDelivery(current.entries.compactMap { $0.item?.task }, .deliveredInContext) {
                        queue.insert(contentsOf: current.entries.map { entry in
                            var held = entry; held.contextDeliveryPending = true; return held
                        }, at: 0)
                    }
                } else {
                    // Preserve every retained entry, including a refused primary
                    // pending transition. No attempt/backoff is produced here.
                    restoreUnheardPhrase(current.entries)
                }
            }
        }
        let token = OutputToken(VoiceIDMint.shared.nextOutput())
        RealtimeAudioSession.shared.beginSpokenReply(token, turn: turn)
        return OutputHandle(output: token.output, token: token)
    }
    @discardableResult
    func speakFixed(_ text: String, turn: TurnID?, agent: RealtimeAgent, owner: Int) -> OutputID? {
        guard agent.isCurrent(owner),
              !AgentSpeechPolicy.spokenClauses(text).isEmpty else { return nil }
        let token = OutputToken(VoiceIDMint.shared.nextOutput())
        RealtimeAudioSession.shared.speak(token, text, kind: turn.map(OutputKind.fixed))
        return token.output
    }
    /// Existing scheduled read-aloud and voice preview have no conversational turn.
    /// They retain that behavior without opening capture or inventing a TurnID.
    @discardableResult
    func speakSessionless(_ text: String) -> OutputHandle? {
        guard !AgentSpeechPolicy.spokenClauses(text).isEmpty else { return nil }
        let token = OutputToken(VoiceIDMint.shared.nextOutput())
        RealtimeAudioSession.shared.speak(token, text, kind: .delivery([]))
        return OutputHandle(output: token.output, token: token)
    }
    static func tokenForTesting() -> OutputToken {
        precondition(SelfTest.isRunning)
        return OutputToken(VoiceIDMint.shared.nextOutput())
    }
    static func currentTokenForTesting() -> OutputToken {
        precondition(SelfTest.isRunning)
        guard let output = RealtimeAudioSession.shared.retainedOutputID else {
            preconditionFailure("No current output for this stream fixture")
        }
        return OutputToken(output)
    }

    /// Only the actual committed Gate/Bridge proposal can mint an approval entry.
    /// Approval playback never consumes or writes the task's result delivery fields.
    @discardableResult
    func enqueueApproval(requestID: String) -> Bool {
        guard let state = bridge.pendingApproval(sessionID: AgentCaptureController.shared.sessionID),
              state.request.id == requestID, !state.prompt.text.isEmpty else { return false }
        cancelPhrasing()
        queue.removeAll { $0.approvalID == requestID }
        queue.append(Entry(item: nil, text: state.prompt.text, eligibleAt: now,
            legacyClauses: nil, recipient: state.recipient, approvalID: requestID))
        return true
    }
    func withdrawApproval(requestID: String) {
        queue.removeAll { $0.approvalID == requestID }
        if let current = active, current.entries.contains(where: { $0.approvalID == requestID }) {
            active = nil
            if current.generation == AgentSpeechSynthesizer.shared.outputGeneration {
                RealtimeAudioSession.shared.noteUserSpeech()
            }
        }
    }
    private func approvalStillCurrent(_ entry: Entry) -> Bool {
        guard let request = entry.approvalID,
              let state = bridge.pendingApproval(sessionID: AgentCaptureController.shared.sessionID),
              state.request.id == request, state.recipient == entry.recipient,
              state.prompt.text == entry.text else { return false }
        return true
    }

    /// Compatibility view for callers not yet carrying a canonical task identity.
    /// It shares this one list; it cannot write delivery state or invent task ownership.
    func enqueue(_ text: String) {
        guard AgentCaptureController.shared.isSessionActive else { return }
        queue.append(Entry(item: nil, text: text, eligibleAt: now, legacyClauses: nil))
    }
    @discardableResult
    func enqueue(_ item: DeliveryItem, mode: AgentDeliveryMode = .respond) -> Bool {
        guard item.attempts >= 0, !item.facts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.facts.count <= 1_200, let row = bridge.record(item.task),
              [.completed, .failed, .cancelled, .waitingForInput].contains(row.status),
              row.delivery == nil || row.delivery == TaskDelivery.none || row.delivery == .pending else { return false }
        // A kind is never permission to invent a question or approval.
        let question: TaskInputRequest?
        let recipient: UUID?
        switch item.kind {
        case .question: return false // Only enqueueQuestion owns an exact request identity.
        case .approval: return false // P3-08 must supply its own real request producer.
        case .result: guard row.status == .completed else { return false }; question = nil; recipient = nil
        case .failure: guard row.status == .failed else { return false }; question = nil; recipient = nil
        case .cancelled: guard row.status == .cancelled else { return false }; question = nil; recipient = nil
        }
        if mode == .context { return bridge.setDelivery([item.task], .silent) }
        guard bridge.setDelivery([item.task], .pending, attempts: item.attempts) else { return false }
        queue.removeAll { $0.item?.task == item.task }
        queue.append(Entry(item: item, text: item.facts, eligibleAt: now.addingTimeInterval(0.120), legacyClauses: nil,
            question: question, recipient: recipient))
        return true
    }
    /// The existing completion caller supplies only task identity; facts come from
    /// the SAME committed Manager row and cannot be minted by assistant prose.
    @discardableResult
    func enqueueCompletion(_ id: TaskID) -> Bool {
        guard let row = bridge.record(id), row.status == .completed,
              let facts = row.result, case .voice? = row.origin else { return false }
        let item = DeliveryItem(task: id, kind: .result, title: TaskStatusRenderer.title(row.objective),
            facts: String(facts.prefix(1_200)), enqueuedAt: row.finishedAt ?? now,
            attempts: row.deliveryAttempts, carriedOver: !AgentCaptureController.shared.isSessionActive)
        return enqueue(item)
    }
    /// The committed question and original session are the only admission source.
    @discardableResult
    func enqueueQuestion(_ id: TaskID) -> Bool {
        guard let row = bridge.record(id), row.source == "voice", row.status == .waitingForInput,
              case .input(let request) = row.pendingInteraction, request.taskID == row.id,
              !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.question.count <= 1_200,
              row.delivery == nil || row.delivery == TaskDelivery.none || row.delivery == .pending,
              case .voice(let session, _)? = row.origin,
              AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == session,
              bridge.setDelivery([id], .pending, attempts: row.deliveryAttempts) else { return false }
        cancelPhrasing()
        let item = DeliveryItem(task: id, kind: .question,
            title: TaskStatusRenderer.title(row.objective), facts: request.question,
            enqueuedAt: request.createdAt, attempts: row.deliveryAttempts, carriedOver: false)
        queue.removeAll { $0.item?.task == id }
        queue.append(Entry(item: item, text: request.question,
            eligibleAt: now.addingTimeInterval(0.120), legacyClauses: nil,
            question: request, recipient: session))
        return true
    }
    /// Explicit answer/cancel withdraws exactly one request, even if saving cancel failed.
    /// Clear the active owner before the SAME generation emits stop callbacks.
    func withdrawQuestion(_ id: TaskID, requestID: String) {
        func matches(_ entry: Entry) -> Bool { entry.item?.task == id && entry.question?.id == requestID }
        queue.removeAll(where: matches)
        if let current = active, current.entries.contains(where: matches) {
            active = nil
            if current.generation == AgentSpeechSynthesizer.shared.outputGeneration {
                RealtimeAudioSession.shared.noteUserSpeech()
            }
        }
    }
    private func questionStillCurrent(_ entry: Entry) -> Bool {
        guard let request = entry.question, let id = entry.item?.task,
              let row = bridge.record(id), row.status == .waitingForInput,
              case .input(let current) = row.pendingInteraction,
              current == request, current.taskID == row.id,
              case .voice(let session, _)? = row.origin else { return false }
        return session == entry.recipient
            && AgentCaptureController.shared.isSessionActive
            && AgentCaptureController.shared.sessionID == entry.recipient
    }
    func sessionOpened() {
        if let session = AgentCaptureController.shared.sessionID { bridge.reofferApproval(sessionID: session) }
        lastFloorAt = now
        // Expire the SAME queued rows before duplicate detection. A failed commit
        // retains the item; missing/future dates never imply an expired result.
        queue.removeAll { entry in
            guard let id = entry.item?.task, let row = bridge.record(id),
                  row.delivery == .pending, let finished = row.finishedAt,
                  now.timeIntervalSince(finished) > 43_200 else { return false }
            return bridge.setDelivery([id], .silent)
        }
        for index in queue.indices where queue[index].item != nil { queue[index].item?.carriedOver = true }
        // Carry from the SAME primary task rows, never another payload store.
        // Only the completion producer currently supplies admitted delivery facts.
        for row in bridge.pendingDeliveryRows() {
            guard !queue.contains(where: { $0.item?.task.raw == row.id }),
                  row.status == .completed, case .voice? = row.origin,
                  let finished = row.finishedAt, let result = row.result else { continue }
            let age = now.timeIntervalSince(finished)
            guard age >= 0 else { continue }
            guard let rawID = UUID(uuidString: row.id) else { continue }
            let id = TaskID(rawID)
            if age > 43_200 { _ = bridge.setDelivery([id], .silent); continue }
            guard bridge.setDelivery([id], .pending) else { continue }
            let item = DeliveryItem(task: id, kind: .result, title: TaskStatusRenderer.title(row.objective),
                facts: String(result.prefix(1_200)), enqueuedAt: finished,
                attempts: row.deliveryAttempts, carriedOver: true)
            queue.append(Entry(item: item, text: item.facts,
                eligibleAt: now.addingTimeInterval(0.120), legacyClauses: nil))
        }
    }
    func sessionClosed() {
        PermissionGate.shared.resetPendingVoiceApprovalPlayback()
        cancelPhrasing()
        if let current = active {
            for request in current.entries.compactMap(\.approvalID) { bridge.resetApprovalPlayback(request) }
            let ids = current.entries.compactMap { $0.item?.task }
            if !ids.isEmpty {
                if current.heard { _ = bridge.setDelivery(ids, .delivered) }
                else if bridge.setDelivery(ids, .pending) {
                    queue.insert(contentsOf: current.entries.map { entry in
                        var copy = entry; copy.item?.carriedOver = true; copy.eligibleAt = now.addingTimeInterval(0.120); return copy
                    }, at: 0)
                }
            }
        }
        active = nil
        queue.removeAll { $0.item == nil }
    }
    /// Legacy clear is session close; canonical pending rows are never erased here.
    func clear() { sessionClosed() }
    func noteUserBargeIn() { cancelPhrasing(); active?.byUser = true; lastFloorAt = now }

    func receive(_ event: AgentSpeechSynthesizer.PlaybackEvent) {
        if case .began(let generation) = event {
            if active?.generation == nil { active?.generation = generation }
            return
        }
        guard var current = active,
              current.generation == AgentSpeechSynthesizer.shared.outputGeneration else {
            if case .completed = event { lastOutputEndAt = now }
            return
        }
        switch event {
        case .enqueued: current.queued += 1; active = current
        case .startAcknowledged:
            guard !current.heard else { return }
            if let entry = current.entries.first, let request = entry.approvalID {
                guard approvalStillCurrent(entry), let id = current.id, let generation = current.generation,
                      RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id == id else { return }
                bridge.noteApprovalPlayback(request, id: id, generation: generation, fully: false)
            }
            // Only this existing speak's retained identity and exact current
            // request may publish a positive question receipt.
            if current.entries.contains(where: { $0.question != nil }) {
                guard let id = current.id,
                      RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id == id,
                      current.entries.allSatisfy({ $0.question == nil || questionStillCurrent($0) }) else { return }
            }
            current.heard = true; active = current
            let ids = current.entries.compactMap { $0.item?.task }
            if !ids.isEmpty { _ = bridge.setDelivery(ids, .delivered) }
        case .completed(let clause):
            if let entry = current.entries.first, let request = entry.approvalID {
                if current.approvalRemaining.first == clause { current.approvalRemaining.removeFirst() }
                else { current.approvalMatchesWholePrompt = false }
                if current.heard, current.approvalRemaining.isEmpty, current.approvalMatchesWholePrompt,
                   approvalStillCurrent(entry), let id = current.id, let generation = current.generation {
                    bridge.noteApprovalPlayback(request, id: id, generation: generation, fully: true)
                }
            }
            current.queued = max(0, current.queued - 1)
            for index in current.entries.indices where current.entries[index].item == nil {
                if current.entries[index].legacyClauses?.first == clause { current.entries[index].legacyClauses?.removeFirst() }
            }
            if current.queued == 0 {
                active = current
                if !current.heard, current.entries.contains(where: { $0.item != nil }) {
                    receive(.interrupted(clause, wasRendered: false))
                } else { active = nil; lastOutputEndAt = now }
            } else { active = current }
        case .interrupted:
            active = nil; lastOutputEndAt = now
            for var entry in current.entries {
                if AgentSpeechSynthesizer.shared.outputAvailability != nil {
                    entry.requiresExplicitReplay = true
                }
                if let request = entry.approvalID {
                    // A barge never replays or approves the old incomplete prompt.
                    if !current.byUser, approvalStillCurrent(entry) {
                        bridge.resetApprovalPlayback(request)
                        entry.eligibleAt = now.addingTimeInterval(0.120)
                        queue.insert(entry, at: 0)
                    }
                    continue
                }
                if let item = entry.item {
                    if current.byUser { _ = bridge.setDelivery([item.task], .deliveredInContext); continue }
                    if AgentSpeechSynthesizer.shared.outputAvailability != nil {
                        // A written answer is retained for explicit replay. No retry
                        // attempt or spoken approval is earned by absent audio.
                        guard bridge.setDelivery([item.task], .pending) else { continue }
                        queue.insert(entry, at: 0)
                        continue
                    }
                    entry.item?.attempts += 1
                    let attempts = entry.item!.attempts
                    if attempts >= 8 { _ = bridge.setDelivery([item.task], .failed, attempts: attempts); continue }
                    guard bridge.setDelivery([item.task], .pending, attempts: attempts) else { continue }
                    entry.eligibleAt = now.addingTimeInterval(min(pow(2, Double(attempts - 1)), 10))
                    queue.insert(entry, at: 0)
                } else if let remaining = entry.legacyClauses, !remaining.isEmpty {
                    queue.insert(Entry(item: nil, text: remaining.joined(separator: " "), eligibleAt: now,
                                       legacyClauses: nil, requiresExplicitReplay: entry.requiresExplicitReplay), at: 0)
                }
            }
        default: break
        }
    }
    @discardableResult
    func flush(userHasFloor: Bool) -> Bool {
        if SelfTest.isRunning, ["--selftest-voice-conversation", "--selftest-voice-session-reducer"].contains(SelfTest.requested ?? "") {
            print("OUTPUT_SCHEDULER_LEGACY_FLUSH phase=entry queueCount=\(queue.count) legacyCount=\(queue.filter { $0.item == nil }.count) activePresent=\(active != nil) activeIDPresent=\(active?.id != nil) synthGeneration=\(AgentSpeechSynthesizer.shared.outputGeneration) audioSpeaking=\(RealtimeAudioSession.shared.isSpeaking) synthSpeaking=\(AgentSpeechSynthesizer.shared.isSpeaking) inputActive=\(RealtimeAgent.shared.voiceInputActive) thinking=\(RealtimeAgent.shared.isThinking) sessionActive=\(AgentCaptureController.shared.isSessionActive) userFloor=\(userHasFloor)")
        }
        if userHasFloor { cancelPhrasing(); lastFloorAt = now }
        guard AgentCaptureController.shared.isSessionActive, !userHasFloor,
              !RealtimeAgent.shared.voiceInputActive, !RealtimeAgent.shared.isThinking,
              !RealtimeAudioSession.shared.isSpeaking, !AgentSpeechSynthesizer.shared.isSpeaking,
              active == nil, phraseTask == nil, !queue.isEmpty else { return false }
        guard AgentSpeechSynthesizer.shared.canSpeak else {
            for index in queue.indices { queue[index].requiresExplicitReplay = true }
            return false
        }
        // Status consumption/expiration is already committed by the SAME row
        // owner. Remove only positive terminal delivery evidence, never absence.
        queue.removeAll { entry in
            if entry.approvalID != nil { return !approvalStillCurrent(entry) }
            if entry.question != nil {
                guard let id = entry.item?.task, bridge.record(id) != nil else { return false }
                return !questionStillCurrent(entry)
            }
            guard let id = entry.item?.task, let row = bridge.record(id) else { return false }
            guard let delivery = row.delivery else { return false }
            if entry.contextDeliveryPending {
                // Refused heard retirement retains the SAME entry, never replay
                // authority. Only positive later context/terminal evidence clears it.
                return [.consumedByStatus, .silent, .deliveredInContext, .failed].contains(delivery)
            }
            return [.consumedByStatus, .silent, .deliveredInContext, .failed, .delivered].contains(delivery)
        }
        // A canonical row is eligible only inside its own quiet/interaction
        // window. An ineligible retained row must not block a legacy update that
        // already satisfies the existing conversational/audio guards above.
        let canonicalWindowOpen = !queue.contains(where: { $0.item != nil }) || (
            PermissionGate.shared.pending == nil
                && !VoiceConversationCoordinator.shared.inputPending
                && AgentCaptureController.shared.voiceShadowQueuedTurn == nil
                && max(lastFloorAt ?? .distantPast, lastOutputEndAt ?? .distantPast).addingTimeInterval(0.350) <= now)
        if SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery", permitsHarness,
           queue.contains(where: { $0.approvalID != nil }) {
            SelfTest.diagnostic("APPROVAL_WINDOW_METADATA quietSeconds=\(now.timeIntervalSince(max(lastFloorAt ?? .distantPast, lastOutputEndAt ?? .distantPast))) canonicalWindow=\(canonicalWindowOpen) inputPending=\(VoiceConversationCoordinator.shared.inputPending) queuedInput=\(AgentCaptureController.shared.voiceShadowQueuedTurn != nil)")
        }
        let eligible = queue.enumerated().filter {
            !$0.element.contextDeliveryPending && !$0.element.requiresExplicitReplay
                && $0.element.eligibleAt <= now && ($0.element.item == nil || (canonicalWindowOpen
                && $0.element.item.map { self.bridge.record($0.task)?.delivery == .pending } == true))
                && ($0.element.approvalID == nil || (approvalStillCurrent($0.element)
                    && !VoiceConversationCoordinator.shared.inputPending
                    && AgentCaptureController.shared.voiceShadowQueuedTurn == nil
                    && max(lastFloorAt ?? .distantPast, lastOutputEndAt ?? .distantPast).addingTimeInterval(0.350) <= now))
                && ($0.element.question == nil || questionStillCurrent($0.element))
        }.sorted { lhs, rhs in
            let left: OutputPriority = lhs.element.approvalID != nil ? .approvalPrompt : (lhs.element.item?.kind.priority ?? .result)
            let right: OutputPriority = rhs.element.approvalID != nil ? .approvalPrompt : (rhs.element.item?.kind.priority ?? .result)
            if left != right { return left < right }
            if let leftDate = lhs.element.item?.enqueuedAt, let rightDate = rhs.element.item?.enqueuedAt,
               leftDate != rightDate { return leftDate < rightDate }
            return lhs.offset < rhs.offset
        }
        guard let first = eligible.first else { return false }
        var selected: [Int] = []
        var characters = 0
        for (index, entry) in eligible {
            if first.element.question != nil || first.element.approvalID != nil { selected = [first.offset]; break }
            if entry.question != nil || entry.approvalID != nil { continue }
            if selected.count >= 8 { break }
            if first.element.item == nil { selected = [first.offset]; break }
            guard entry.item != nil else { continue }
            if !selected.isEmpty, characters + entry.text.count > 2_400 { break }
            selected.append(index); characters += entry.text.count
        }
        let entries = selected.map { queue[$0] }
        let ids = entries.compactMap { $0.item?.task }
        if SelfTest.isRunning, ["--selftest-voice-conversation", "--selftest-voice-session-reducer"].contains(SelfTest.requested ?? "") {
            print("OUTPUT_SCHEDULER_LEGACY_FLUSH phase=selected canonicalCount=\(ids.count) entryCount=\(entries.count) firstLegacy=\(entries.first?.item == nil) pendingApproval=\(PermissionGate.shared.pending != nil) inputPending=\(VoiceConversationCoordinator.shared.inputPending) queuedTurn=\(AgentCaptureController.shared.voiceShadowQueuedTurn != nil) quietElapsed=\(max(lastFloorAt ?? .distantPast, lastOutputEndAt ?? .distantPast).addingTimeInterval(0.350) <= now)")
        }
        if !ids.isEmpty {
            guard PermissionGate.shared.pending == nil,
                  !VoiceConversationCoordinator.shared.inputPending,
                  AgentCaptureController.shared.voiceShadowQueuedTurn == nil,
                  max(lastFloorAt ?? .distantPast, lastOutputEndAt ?? .distantPast).addingTimeInterval(0.350) <= now else { return false }
        }
        let batch = entries.compactMap(\.item)
        if !batch.isEmpty, batch.allSatisfy({ $0.kind.priority == .result }) {
            guard bridge.setDelivery(ids, .delivering) else { return false }
            for index in selected.sorted(by: >) { queue.remove(at: index) }
            let session = AgentCaptureController.shared.sessionID
            let floor = lastFloorAt
            phrasingEntries = entries
            let override = phraseOverrideForTesting
            phraseTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await withBoundedWait(.seconds(1.5)) {
                    if let override { return await override(batch) }
                    return await FrontendResponder.shared.phrase(batch, carriedOver: batch.contains(where: \.carriedOver))
                }
                guard !Task.isCancelled else { return }
                // Cancellation has already restored the SAME entries. A late
                // native return cannot take a newer phrase's owner slot.
                guard self.phrasingEntries != nil else { return }
                self.phraseTask = nil; self.phrasingEntries = nil
                guard AgentCaptureController.shared.isSessionActive,
                      AgentCaptureController.shared.sessionID == session,
                      self.lastFloorAt == floor,
                      max(self.lastFloorAt ?? .distantPast, self.lastOutputEndAt ?? .distantPast).addingTimeInterval(0.350) <= self.now,
                      !RealtimeAgent.shared.voiceInputActive, !RealtimeAgent.shared.isThinking,
                      !RealtimeAudioSession.shared.isSpeaking, !AgentSpeechSynthesizer.shared.isSpeaking,
                      PermissionGate.shared.pending == nil, !VoiceConversationCoordinator.shared.inputPending,
                      AgentCaptureController.shared.voiceShadowQueuedTurn == nil,
                      entries.allSatisfy({ entry in
                          guard let id = entry.item?.task, let row = self.bridge.record(id) else { return false }
                          return row.delivery == .delivering
                      }) else {
                    self.restoreUnheardPhrase(entries)
                    return
                }
                let candidate = response.flatMap { $0 }.flatMap(AgentDeliveryPrompts.acceptedPhrase)
                self.speakEntries(entries, spoken: candidate ?? DeliveryFallbackRenderer.spoken(batch))
            }
            if SelfTest.isRunning, ["--selftest-voice-duplex-work", "--selftest-island"].contains(SelfTest.requested ?? ""),
               suppliedBridge?.permitsHarness == true, let owned = phraseTask {
                phraseTaskObserverForTesting?(owned)
            }
            return true
        }
        let spoken: String
        if entries.first?.approvalID != nil { spoken = entries[0].text }
        else if entries.first?.item != nil {
            let batch = entries.compactMap(\.item)
            spoken = DeliveryFallbackRenderer.spoken(batch)
        } else {
            let brief = AgentSpeechPolicy.spokenClauses(entries[0].text).prefix(2).joined(separator: " ")
            spoken = !brief.isEmpty && brief.count <= 300 ? brief : "There's an update from your background task. The details are in the conversation."
        }
        guard !AgentSpeechPolicy.spokenClauses(spoken).isEmpty else { return false }
        if !ids.isEmpty, !bridge.setDelivery(ids, .delivering) { return false }
        for index in selected.sorted(by: >) { queue.remove(at: index) }
        speakEntries(entries, spoken: spoken)
        return true
    }
    private func restoreUnheardPhrase(_ entries: [Entry]) {
        // Revoke no input/result ownership and count no interruption attempt.
        // If primary refusal retains delivering, preserve the entry but keep it
        // ineligible until a positive pending state is admitted by the row owner.
        let ids = entries.compactMap { $0.item?.task }
        _ = bridge.setDelivery(ids, .pending)
        queue.insert(contentsOf: entries, at: 0)
    }
    private func cancelPhrasing() {
        guard let entries = phrasingEntries else { return }
        phrasingEntries = nil
        phraseTask?.cancel(); phraseTask = nil
        restoreUnheardPhrase(entries)
    }
    private func speakEntries(_ entries: [Entry], spoken: String) {
        var outgoing = entries
        for index in outgoing.indices where outgoing[index].item == nil && outgoing[index].approvalID == nil { outgoing[index].legacyClauses = AgentSpeechPolicy.spokenClauses(spoken) }
        let token = OutputToken(VoiceIDMint.shared.nextOutput())
        var current = Active(id: token.output, entries: outgoing)
        if outgoing.first?.approvalID != nil {
            current.approvalRemaining = AgentSpeechPolicy.speakableClauses(spoken)
            current.approvalMatchesWholePrompt = VoiceTranscriptCanonical.key(current.approvalRemaining.joined(separator: " ")) == VoiceTranscriptCanonical.key(spoken)
        }
        active = current
        let ids = outgoing.compactMap { $0.item?.task }
        RealtimeAudioSession.shared.speak(token, spoken, kind: .delivery(ids))
        // The SAME scheduler-issued capability is reused by the audio owner.
        // Its existing snapshot requires the retained native generation to match.
        // This observed identity does not execute a shadow command or prove sound.
        if active?.generation == AgentSpeechSynthesizer.shared.outputGeneration {
            active?.id = RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id
            if let request = active?.entries.first?.approvalID, let id = active?.id,
               let generation = active?.generation {
                bridge.noteApprovalOutput(request, id: id, generation: generation)
            }
        }
    }
}

@MainActor
enum DeliveryFallbackRenderer {
    static func spoken(_ batch: [DeliveryItem]) -> String {
        let facts = batch.map { item in
            let first = AgentSpeechPolicy.spokenClauses(item.facts).first ?? item.facts
            switch item.kind {
            case .result: return item.title + " is done: " + String(first.prefix(160))
            case .failure: return item.title + " didn't work: " + String(first.prefix(160))
            case .cancelled: return item.title + " was stopped."
            case .question, .approval: return String(item.facts.prefix(1_200))
            }
        }.joined(separator: " Also, ")
        return RealtimeAgent.voiceSafeReply((batch.contains(where: \.carriedOver) ? "While you were away, " : "") + facts)
    }
}
