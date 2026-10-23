import Foundation

/// Pure policy, shared by live capture and paced replay. Silence alone cannot
/// overrule a current incomplete verdict at an ordinary mid-sentence pause.
enum SmartTurnEndpointPolicy {
    enum Decision: String, Sendable { case wait, complete, fallback }
    static func decide(quiet: Double, probability: Float?, inferencePending: Bool,
                       modelAvailable: Bool, transcriptReady: Bool, legacyEligible: Bool) -> Decision {
        guard transcriptReady, quiet >= 0.2 else { return .wait }
        if let probability {
            if probability >= 0.5 { return .complete }
            return quiet >= 5 ? .fallback : .wait
        }
        // Native prediction may finish after its authority deadline; it is still
        // joined before model reuse. Waiting for it never blocks capture or ASR.
        if modelAvailable && inferencePending { return .wait }
        return legacyEligible ? .fallback : .wait
    }
}

/// One capture's last eight seconds, actual decoder progress and latest semantic
/// verdict. The capture producer revokes old authority synchronously on new speech.
/// One native prediction plus one replaceable pending snapshot; no task per buffer.
final class SmartTurnEndpoint: @unchecked Sendable {
    struct Token: Equatable, Sendable {
        let captureID: UUID
        let epoch: Int
        let revision: UInt64
        let speechEnd: Int64
    }
    struct Request: Sendable {
        let token: Token
        let samples: [Float]
        let endSample: Int64
        let requestedAt: UInt64
    }
    struct Result: Sendable {
        let request: Request
        let probability: Float
        let completedAt: UInt64
        let inferenceMS: Double
    }
    struct Evaluation: Sendable {
        let decision: SmartTurnEndpointPolicy.Decision
        let token: Token
        let quiet: Double
        let probability: Float?
        let reason: String
        let endSample: Int64
        let decoderStamp: VoiceDecoderProgress.Stamp?
    }
    struct Successor: Sendable {
        let samples: [Float]
        let endSample: Int64
        let sequence: Int
        let capturedAtNanos: UInt64
    }
    private let lock = NSLock()
    let captureID: UUID
    private var epoch: Int
    private var revision: UInt64 = 0
    private var endSample: Int64 = 0
    private var speechEnd: Int64 = 0
    private var hasSpeech = false
    private var turnStartSample: Int64 = 0
    private var latestSequence = 0
    private var capturedAtNanos: UInt64 = 0
    private var decoder: VoiceDecoderProgress?
    private var ring = [Float](repeating: 0, count: 128_000)
    private var writeIndex = 0
    private var count = 0
    private var closed = false
    private var model: SmartTurnModel?
    private var failure: String?
    private var result: Result?
    private var pending: Request?
    private var busy = false
    private var requestedAt: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?

    init(captureID: UUID, epoch: Int, cachedOnly: Bool, directory: URL? = nil,
         retiring: Task<Void, Never>? = nil,
         skipModelForTesting: Bool = false) {
        self.captureID = captureID; self.epoch = epoch
        if skipModelForTesting { return }
        loadTask = Task.detached(priority: .utility) { [self] in
            await retiring?.value
            do {
                let modelDirectory: URL
                if let supplied = directory { modelDirectory = supplied }
                else { modelDirectory = try await VoiceTurnAssets.prepare(.smartTurn, cachedOnly: cachedOnly) }
                try Task.checkCancellation()
                let loaded = try SmartTurnModel(directory: modelDirectory)
                try Task.checkCancellation()
                finishLoad(loaded, failure: nil)
            } catch { finishLoad(nil, failure: error.localizedDescription) }
        }
    }
    private func finishLoad(_ model: SmartTurnModel?, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        self.model = model; self.failure = failure
    }
    func waitUntilLoaded() async { await loadTask?.value }
    func modelFailure() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return model != nil && !closed }

    @discardableResult
    func append(_ samples: UnsafeBufferPointer<Float>, nearSpeech: Bool,
                sequence: Int = 0, at: UInt64? = nil) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return endSample }
        for value in samples {
            ring[writeIndex] = value.isFinite ? value : 0
            writeIndex = (writeIndex + 1) % ring.count
        }
        count = min(ring.count, count + samples.count)
        endSample += Int64(samples.count)
        latestSequence = sequence
        capturedAtNanos = at ?? DispatchTime.now().uptimeNanoseconds
        if nearSpeech {
            hasSpeech = true
            revision &+= 1; speechEnd = endSample
            result = nil; pending = nil
        }
        return endSample
    }
    func attachDecoder(_ decoder: VoiceDecoderProgress) {
        lock.lock(); defer { lock.unlock() }
        self.decoder = decoder
    }
    func discontinuity() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1; result = nil; pending = nil
    }
    /// A low-energy voiced frame may be found by Silero after the energy producer.
    /// Convert its capture age to the same sample clock, not callback arrival time.
    @discardableResult
    func voiced(at: UInt64, now: UInt64, sampleEnd: Int64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, now >= at, now - at <= 256_000_000 else { return false }
        let position = min(endSample, sampleEnd ?? max(0, endSample - Int64((now - at) / 62_500)))
        guard position > max(speechEnd, turnStartSample) else { return false }
        speechEnd = position; revision &+= 1; result = nil; pending = nil
        hasSpeech = true
        return true
    }
    private func token() -> Token {
        Token(captureID: captureID, epoch: epoch, revision: revision, speechEnd: speechEnd)
    }
    private func snapshot(at: UInt64) -> Request {
        let start = (writeIndex - count + ring.count) % ring.count
        let tail = (0..<count).map { ring[(start + $0) % ring.count] }
        return Request(token: token(), samples: tail, endSample: endSample, requestedAt: at)
    }
    func stillCurrent(_ token: Token, decoderStamp: VoiceDecoderProgress.Stamp? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && token == self.token()
            && (decoderStamp.map { decoder?.stillPublished($0) == true } ?? true)
    }
    /// Recover ALL post-cutoff PCM from the existing ring, even when multiple
    /// chunks finished on the retiring decoder. Capture cannot append/enqueue
    /// successor audio until the reset/replay marker has been installed.
    func claimCommit(_ selected: Token, boundary: Int64,
                     install: (Successor) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let frames = endSample - boundary
        guard !closed, selected == token(), frames >= 0,
              frames <= min(Int64(count), 96_000) else { return false }
        let start = (writeIndex - Int(frames) + ring.count) % ring.count
        let tail = (0..<Int(frames)).map { ring[(start + $0) % ring.count] }
        return install(Successor(samples: tail, endSample: endSample,
            sequence: latestSequence, capturedAtNanos: capturedAtNanos))
    }
    func evaluate(now: UInt64, usableText: Bool, transcriptStable: Bool,
                  localText: Bool, legacyEligible: Bool, appleAudioThrough: Int64? = nil) -> Evaluation {
        lock.lock(); defer { lock.unlock() }
        let current = token()
        let quiet = Double(endSample - speechEnd) / 16_000
        let valid = result.flatMap { $0.request.token == current ? $0 : nil }
        let decoderStamp = decoder?.readyStamp(sessionID: captureID, epoch: epoch, through: speechEnd)
        let publishedStamp = decoder?.publishedStamp(sessionID: captureID, epoch: epoch)
        let covered = localText ? decoderStamp != nil : (appleAudioThrough.map { $0 >= speechEnd } ?? false)
        let transcriptReady = usableText && transcriptStable && covered
        let predictionCurrent = requestedAt > 0 && now >= requestedAt && now - requestedAt < 1_000_000_000
        if !closed, hasSpeech, model != nil, speechEnd > 0, quiet >= 0.2,
           (requestedAt == 0 || now - requestedAt >= 200_000_000) {
            let request = snapshot(at: now)
            requestedAt = now
            if busy { pending = request }
            else {
                busy = true
                workerTask = Task.detached(priority: .userInitiated) { [self] in run(request) }
            }
        }
        // A hung model cannot renew its authority by merely receiving new requests.
        let activeAge = activeRequestAt.map { now >= $0 ? now - $0 : UInt64.max }
        let inTime = busy && (activeAge ?? 0) < 1_000_000_000
        var decision = SmartTurnEndpointPolicy.decide(quiet: quiet,
            probability: valid?.probability, inferencePending: inTime || (!busy && predictionCurrent),
            modelAvailable: model != nil, transcriptReady: transcriptReady, legacyEligible: legacyEligible)
        let coverageFallback = !covered && usableText && transcriptStable && legacyEligible
            && (!localText || publishedStamp != nil)
            && quiet >= (valid.map { $0.probability < 0.5 } == true ? 5 : 2.5)
        if coverageFallback { decision = .fallback }
        return Evaluation(decision: decision, token: current, quiet: quiet,
            probability: valid?.probability,
            reason: coverageFallback ? "recognizer-coverage-unavailable" : (decision == .complete ? "smart-turn-v3.2" :
                (valid != nil ? "incomplete-maximum-quiet" : (failure ?? "semantic-result-unavailable"))),
            endSample: endSample,
            decoderStamp: localText ? (decoderStamp ?? (coverageFallback ? publishedStamp : nil)) : nil)
    }
    private var activeRequestAt: UInt64?
    private func run(_ first: Request) {
        var next: Request? = first
        while let request = next {
            lock.lock()
            let loaded = closed ? nil : model
            activeRequestAt = request.requestedAt
            lock.unlock()
            if let loaded, !Task.isCancelled {
                let started = DispatchTime.now().uptimeNanoseconds
                do {
                    let probability = try loaded.probability(request.samples)
                    let completed = DispatchTime.now().uptimeNanoseconds
                    publish(Result(request: request, probability: probability, completedAt: completed,
                        inferenceMS: Double(completed - started) / 1_000_000))
                } catch { disable(error.localizedDescription) }
            }
            lock.lock()
            next = closed || Task.isCancelled ? nil : pending
            pending = nil
            if next == nil { busy = false; activeRequestAt = nil }
            lock.unlock()
        }
    }
    private func publish(_ value: Result) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, value.request.token == token(),
              value.completedAt >= value.request.requestedAt,
              value.completedAt - value.request.requestedAt < 1_000_000_000 else { return }
        result = value
    }
    private func disable(_ reason: String) {
        lock.lock(); defer { lock.unlock() }
        model = nil; failure = reason; result = nil; pending = nil
    }
    func reset(epoch: Int, through boundary: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.epoch = epoch; revision &+= 1
        let cutoff = min(endSample, max(0, boundary ?? endSample))
        turnStartSample = cutoff
        count = min(count, Int(endSample - cutoff))
        hasSpeech = speechEnd > cutoff
        if !hasSpeech { speechEnd = endSample }
        result = nil; pending = nil; requestedAt = 0
    }
    /// Revocation is synchronous. Cancellation does not imply Core ML stopped;
    /// the returned drain joins both native handles before releasing weights.
    func close() -> Task<Void, Never> {
        lock.lock()
        closed = true; revision &+= 1; pending = nil; result = nil; count = 0
        let loading = loadTask, working = workerTask
        lock.unlock()
        loading?.cancel(); working?.cancel()
        return Task.detached(priority: .utility) { [self] in
            await loading?.value; await working?.value
            releaseModel()
        }
    }
    private func releaseModel() { lock.lock(); model = nil; lock.unlock() }
}
