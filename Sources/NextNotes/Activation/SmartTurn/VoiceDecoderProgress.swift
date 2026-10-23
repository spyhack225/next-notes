import Foundation

/// Decoder metadata only: a native reset generation, conservative sample frontier
/// and ordered cumulative transcript publications. No PCM, task, queue or store.
final class VoiceDecoderProgress: @unchecked Sendable {
    /// Same400ms freshness window as the existing startup drain. A recent tail
    /// timestamp alone says nothing about how far its decoder has advanced.
    static func replayCaughtUp(processedEnd: Int64, capturedEnd: Int64) -> Bool {
        processedEnd >= capturedEnd - 6_400
    }
    struct Scope: Equatable, Sendable {
        let sessionID: UUID?
        let epoch: Int
        let generation: UInt64
    }
    struct Stamp: Equatable, Sendable {
        let scope: Scope
        let revision: UInt64
    }
    struct Snapshot: Sendable {
        let scope: Scope
        let resetBoundary: Int64
        let processedEnd: Int64
        let produced: UInt64
        let applied: UInt64
    }
    private let lock = NSLock()
    private var scope = Scope(sessionID: nil, epoch: 0, generation: 0)
    private var resetBoundary: Int64 = 0
    private var processedEnd: Int64 = 0
    private var produced: UInt64 = 0
    private var applied: UInt64 = 0

    @discardableResult
    func invalidate(sessionID: UUID?, epoch: Int, through boundary: Int64 = 0) -> Scope {
        lock.lock(); defer { lock.unlock() }
        return advance(sessionID: sessionID, epoch: epoch, through: boundary)
    }
    private func advance(sessionID: UUID?, epoch: Int, through boundary: Int64) -> Scope {
        scope = Scope(sessionID: sessionID, epoch: epoch, generation: scope.generation &+ 1)
        resetBoundary = boundary
        // An old decoder may already have looked beyond the selected commit.
        // Its successor must actually decode that PCM again before owning text.
        processedEnd = boundary
        produced = 0; applied = 0
        return scope
    }
    /// Atomically claim the applied snapshot and publish its successor reset.
    func commit(ifPublished stamp: Stamp?, sessionID: UUID, fromEpoch: Int,
                toEpoch: Int, through boundary: Int64, install: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard scope.sessionID == sessionID, scope.epoch == fromEpoch else { return false }
        if let stamp {
            guard stamp.scope == scope, stamp.revision == applied, applied == produced else { return false }
        }
        _ = advance(sessionID: sessionID, epoch: toEpoch, through: boundary)
        install()
        return true
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(scope: scope, resetBoundary: resetBoundary,
            processedEnd: processedEnd, produced: produced, applied: applied)
    }
    func isCurrent(_ candidate: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }; return candidate == scope
    }
    /// Called synchronously by the SDK callback, before any MainActor hop.
    func produced(in candidate: Scope) -> Stamp? {
        lock.lock(); defer { lock.unlock() }
        guard candidate == scope else { return nil }
        produced &+= 1
        return Stamp(scope: scope, revision: produced)
    }
    /// MainActor applies a whole snapshot only after this order/generation check.
    func apply(_ stamp: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard stamp.scope == scope, stamp.revision > applied, stamp.revision <= produced else { return false }
        applied = stamp.revision
        return true
    }
    func processed(through sample: Int64, in candidate: Scope) {
        lock.lock(); defer { lock.unlock() }
        guard candidate == scope else { return }
        processedEnd = max(processedEnd, sample)
    }
    func readyStamp(sessionID: UUID, epoch: Int, through sample: Int64) -> Stamp? {
        lock.lock(); defer { lock.unlock() }
        guard scope.sessionID == sessionID, scope.epoch == epoch, processedEnd >= sample,
              produced > 0, applied == produced else { return nil }
        return Stamp(scope: scope, revision: applied)
    }
    func publishedStamp(sessionID: UUID, epoch: Int) -> Stamp? {
        lock.lock(); defer { lock.unlock() }
        guard scope.sessionID == sessionID, scope.epoch == epoch,
              produced > 0, applied == produced else { return nil }
        return Stamp(scope: scope, revision: applied)
    }
    func stillPublished(_ stamp: Stamp) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stamp.scope == scope && stamp.revision == applied && applied == produced
    }
}

enum VoiceDecoderProgressSelfTest {
    static func failures() -> [String] {
        let state = VoiceDecoderProgress(), session = UUID()
        var failures: [String] = []
        func expect(_ value: Bool, _ reason: String) { if !value { failures.append(reason) } }
        let first = state.invalidate(sessionID: session, epoch: 1)
        state.processed(through: 10_000, in: first)
        let a = state.produced(in: first)!
        expect(state.apply(a), "first publication rejected")
        expect(state.readyStamp(sessionID: session, epoch: 1, through: 8_000) != nil, "current decoded transcript not ready")
        let b = state.produced(in: first)!
        expect(state.readyStamp(sessionID: session, epoch: 1, through: 8_000) == nil,
            "SDK emission held before process return allowed stale text")
        expect(!state.stillPublished(a), "commit retained authority after new native emission")
        let c = state.produced(in: first)!
        expect(state.apply(c), "newest cumulative snapshot rejected")
        expect(!state.apply(b), "older callback overwrote newer text")
        expect(state.stillPublished(c), "dropping old revision revoked newest snapshot")
        let second = state.invalidate(sessionID: session, epoch: 2, through: 6_000)
        state.processed(through: 20_000, in: first)
        expect(state.snapshot().processedEnd == 6_000, "retired in-flight native pass restored stale frontier")
        expect(!state.apply(c), "prior-turn callback regained authority")
        let d = state.produced(in: second)!
        expect(state.apply(d), "successor text rejected")
        expect(state.readyStamp(sessionID: session, epoch: 2, through: 7_000) == nil,
            "successor used retiring decoder's sample frontier")
        state.processed(through: 7_000, in: second)
        expect(state.readyStamp(sessionID: session, epoch: 2, through: 7_000) != nil,
            "new decoder did not gain authority after native coverage")
        let gap = state.invalidate(sessionID: session, epoch: 2)
        expect(!state.apply(d), "pre-gap same-turn callback regained authority")
        expect(state.produced(in: second) == nil, "retired callback created new-generation emission")
        state.processed(through: 90_000, in: second)
        expect(state.snapshot().processedEnd == 0, "pre-gap process restored coverage")
        expect(gap.generation > second.generation, "discontinuity did not advance native generation")
        expect(!VoiceDecoderProgress.replayCaughtUp(processedEnd: 1_280, capturedEnd: 80_000),
            "first old replay shift claimed current speech ownership")
        expect(VoiceDecoderProgress.replayCaughtUp(processedEnd: 78_720, capturedEnd: 80_000),
            "completed native replay did not reach existing freshness window")
        return failures
    }
}
