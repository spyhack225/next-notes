import AVFoundation
import Darwin
import FluidAudio
import Observation

/// The default voice prepares at normal launch; Settings joins the same owned task.
@MainActor
@Observable
final class PocketAgentVoice {
    static let shared = PocketAgentVoice()

    // Shared by the model-backed session probe to avoid loading a second
    // Pocket model on a 16 GB machine.
    let manager: PocketTtsManager
    private let terminationFixtureRoot: URL?
    private let terminationFixtureTrace: StartupTerminationTrace?

    init() {
        manager = PocketTtsManager(precision: .int8)
        terminationFixtureRoot = nil
        terminationFixtureTrace = nil
    }

    init(terminationFixtureRoot: URL, trace: StartupTerminationTrace) throws {
        let root = try NativeStartupTerminationSelfTest.validateAssets(terminationFixtureRoot, pocket: true)
        self.terminationFixtureRoot = root
        self.terminationFixtureTrace = trace
        manager = PocketTtsManager(defaultVoice: "alba", language: .english, directory: root,
                                   precision: .int8, placement: .gpu)
    }
    private(set) var speechSynthesisCallsForTesting = 0
    func noteSynthesisRequestForTesting() {
        if SelfTest.isRunning { speechSynthesisCallsForTesting += 1 }
    }
    private(set) var isReady = false
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    private var prepareTask: Task<Void, Never>?
    private var terminationRequested = false
    private var terminationPrepareTask: Task<Void, Never>?
    private weak var replyPlayback: PocketSpeechBacking?
    private var replyTask: Task<Void, Never>?
    private var replyGeneration: UInt64 = 0

    // Same model owner, one current native reply handle. The predecessor is
    // captured only until its cancellation/native join returns; never a list.
    func startReplyPlayback(_ playback: PocketSpeechBacking,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !terminationRequested else { return nil }
        let previous = replyTask
        if let priorBacking = replyPlayback, priorBacking !== playback { priorBacking.stop() }
        previous?.cancel()
        replyGeneration &+= 1
        let generation = replyGeneration
        replyPlayback = playback
        let pending = Task { @MainActor [weak self] in
            // Even a canceled successor must drain its captured predecessor.
            await previous?.value
            guard let self else { return }
            if !Task.isCancelled && !terminationRequested && replyGeneration == generation {
                await operation()
            }
            if replyGeneration == generation {
                replyTask = nil
                if replyPlayback?.isSpeaking == false { replyPlayback = nil }
            }
        }
        replyTask = pending
        return pending
    }

    func replyPlaybackDrained(_ playback: PocketSpeechBacking) {
        if replyPlayback === playback && replyTask == nil { replyPlayback = nil }
    }

    /// Snapshot before cancel; prepare() may clear its ordinary slot across an await.
    func beginTermination() {
        guard !terminationRequested else { return }
        terminationRequested = true
        automaticPreparationDeferred = false
        if let pressureObserver { NotificationCenter.default.removeObserver(pressureObserver) }
        pressureObserver = nil
        if prepareTask == nil { isPreparing = false }
        terminationPrepareTask = prepareTask
        terminationPrepareTask?.cancel()
        replyPlayback?.stop()
        replyTask?.cancel()
    }

    /// Join preparation and the reply-scoped playback producer. File render
    /// callers retain their own existing CatchUp/LongForm termination joins.
    func finishTermination() async {
        beginTermination()
        await terminationPrepareTask?.value
        await replyTask?.value
        terminationPrepareTask = nil
        replyTask = nil
        replyPlayback = nil
    }

    private func checkTerminationAdmission() throws {
        guard !terminationRequested else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static var isPreparationVoiceFixture: Bool {
        SelfTest.requested == "--selftest-tts-pocket"
            && CommandLine.arguments.contains("--tts-pocket-cached-prepare")
            && CommandLine.arguments.contains("--pocket-prepare-voice-only")
    }
    private var preparationVoiceForTesting: String?
    private var preparationLoadedForTesting: (@MainActor () async -> Void)?
    private var preparationWarmVoiceForTesting: (@MainActor (String) -> Void)?

    private var selectedPreparationVoice: String {
        if Self.isPreparationVoiceFixture, let preparationVoiceForTesting { return preparationVoiceForTesting }
        return terminationFixtureRoot != nil ? "alba" : Settings.shared.agentPocketVoice
    }

    // Isolated actual-owner fixtures substitute only expensive native entries.
    var assetsForTesting: (@MainActor () async throws -> Void)?
    var initializeForTesting: (@MainActor () async throws -> Void)?
    var warmForTesting: (@MainActor () async throws -> Void)?
    var schedulerForTesting: ComputeScheduler?
    var pressureForTesting: (() -> ModelResidencyPolicy.PressureSnapshot)?
    var recordingForTesting: (() -> Bool)?
    private var automaticPreparationDeferred = false
    private var pressureObserver: NSObjectProtocol?
    private var preparationScheduler: ComputeScheduler {
        SelfTest.isRunning ? schedulerForTesting ?? .shared : .shared
    }
    private var preparationPressure: ModelResidencyPolicy.PressureSnapshot {
        if SelfTest.isRunning, let pressureForTesting { return pressureForTesting() }
        return ModelResidencyPolicy.pressureSnapshot
    }
    private var preparationRecording: Bool {
        if SelfTest.isRunning { return recordingForTesting?() ?? false }
        return LiveLongFormEnvironment().isRecording
    }
    private func deferAutomaticPreparation() {
        automaticPreparationDeferred = true; isPreparing = true
        guard !SelfTest.isRunning, preparationRecording else { return }
        // One-shot observation of the existing meeting/dictation activity;
        // ending it retries this same owned preparation, without a timer.
        withObservationTracking { _ = LiveLongFormEnvironment().isRecording } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, automaticPreparationDeferred, !terminationRequested else { return }
                await prepareAutomatically()
            }
        }
    }
    func prepareAutomatically() async { await prepare(automatic: true) }

    private func checkPreparationResources(automatic: Bool, lane: UUID?) async throws {
        guard automatic else { try checkTerminationAdmission(); return }
        if let lane { await preparationScheduler.checkpoint(lane) }
        try checkTerminationAdmission()
        guard preparationPressure.allowsOptionalWork, !preparationRecording else {
            deferAutomaticPreparation()
            throw CancellationError()
        }
    }

    func prepare(automatic: Bool = false) async {
        guard !terminationRequested, !Task.isCancelled else { return }
        if isReady { return }
        if let prepareTask {
            await prepareTask.value
            // A normal/idle event can join just before the old deferred task
            // releases its lane. Its slot is cleared before completion, so the
            // joining trigger can now admit this same owner without losing it.
            if automaticPreparationDeferred && (!automatic ||
                (preparationPressure.allowsOptionalWork && !preparationRecording)) {
                await prepare(automatic: automatic)
            }
            return
        }
        if automatic {
            ModelResidencyPolicy.installPressureObserver()
            if pressureObserver == nil {
                pressureObserver = NotificationCenter.default.addObserver(
                    forName: ModelResidencyPolicy.admissionChanged, object: nil, queue: nil
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, automaticPreparationDeferred, !terminationRequested else { return }
                        await prepareAutomatically()
                    }
                }
            }
            guard errorMessage == nil else { return } // events never retry a failure
            if !preparationPressure.allowsOptionalWork || preparationRecording {
                deferAutomaticPreparation()
                return
            }
        }
        automaticPreparationDeferred = false
        let voice = selectedPreparationVoice
        isPreparing = true
        errorMessage = nil
        let pending = Task { @MainActor in
            // Native diagnostics may use cached assets or report absence. They
            // never start the normal first-launch download.
            let priorOffline = ModelHub.offlineMode
            if SelfTest.isRunning { ModelHub.offlineMode = true }
            defer { if SelfTest.isRunning { ModelHub.offlineMode = priorOffline } }
            defer {
                terminationFixtureTrace?.taskEnded()
                isPreparing = automaticPreparationDeferred && !terminationRequested
                prepareTask = nil // clear the owned slot before its waiters resume
            }
            let lane: UUID?
            if automatic { lane = await preparationScheduler.acquireCancellable(.background) }
            else { lane = nil }
            if automatic && lane == nil { return }
            do {
                try await checkPreparationResources(automatic: automatic, lane: lane)
                // Same public downloader as the manager, inside this owned task.
                // Recheck after the cold network wait before native allocation.
                if automatic {
                    if SelfTest.isRunning, let assetsForTesting { try await assetsForTesting() }
                    else if !SelfTest.isRunning || initializeForTesting == nil {
                        _ = try await PocketTtsResourceDownloader.ensureModels(
                            language: manager.language, directory: terminationFixtureRoot,
                            precision: .int8, placement: .gpu)
                    }
                    try await checkPreparationResources(automatic: automatic, lane: lane)
                }
                do {
                    terminationFixtureTrace?.loadEntered(pocket: true)
                    defer { terminationFixtureTrace?.loadReturned() }
                    if SelfTest.isRunning, let initializeForTesting { try await initializeForTesting() }
                    else { try await manager.initialize() }
                }
                try await checkPreparationResources(automatic: automatic, lane: lane)
                if Self.isPreparationVoiceFixture { await preparationLoadedForTesting?() }
                try await checkPreparationResources(automatic: automatic, lane: lane)
                if SelfTest.isRunning, let warmForTesting { try await warmForTesting() }
                else { try await warmFirstPrediction(voice: voice) }
                try checkTerminationAdmission()
                isReady = true
                terminationFixtureTrace?.readyPublished()
            } catch is CancellationError {
                // Quit has no new readiness or failure announcement.
            } catch {
                // Some native failures are not CancellationError. Closing still
                // forbids a late load-failure announcement; cleanup below remains.
                if !terminationRequested && !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    Log.agent.error("Pocket TTS load failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            if let lane { await preparationScheduler.release(lane) }
        }
        prepareTask = pending
        terminationFixtureTrace?.assigned()
        await pending.value
    }

    /// Loading CoreML models does not run their first prediction. The first
    /// actual Pocket frame otherwise arrives about 0.55 s after a clause is
    /// submitted, versus about 0.08 s after this warmup on this machine.
    /// No generated frame reaches the speaker or the playback ledger.
    private func warmFirstPrediction(voice: String) async throws {
        try checkTerminationAdmission()
        terminationFixtureTrace?.warmEntered()
        if Self.isPreparationVoiceFixture { preparationWarmVoiceForTesting?(voice) }
        let session = try await manager.makeSession(voice: voice)
        if terminationRequested || Task.isCancelled {
            await session.cancel()
            throw CancellationError()
        }
        session.enqueue("Ready.")
        let produced: Bool? = await withBoundedWait(.seconds(8)) {
            do {
                for try await frame in session.frames {
                    if frame.samples.contains(where: { abs($0) > 0.0001 }) { return true }
                }
            } catch { return false }
            return false
        }
        // cancel() waits for the native generator to stop using CoreML; a
        // real clause can never overlap this synthetic, unheard warmup.
        await session.cancel()
        guard produced == true else {
            throw PocketPlaybackError.emptyOutput
        }
    }

    private func prepareForSynthesis() async throws {
        try checkTerminationAdmission()
        // The one-time native warmup can be draining a cancelled CoreML call.
        // If it exceeds this caller's budget, leave this reply written while
        // the prepare task keeps exclusive ownership until cancel() returns.
        let prepared: Void? = await withBoundedWait(.seconds(10)) { if let task = self.prepareTask { await task.value } }
        try checkTerminationAdmission()
        guard prepared != nil else { throw PocketPlaybackError.modelUnavailable("Pocket TTS is still preparing.") }
        guard errorMessage == nil, isReady else { throw PocketPlaybackError.modelUnavailable(errorMessage) }
    }

    func frames(for text: String, voice: String)
        async throws -> AsyncThrowingStream<PocketTtsSynthesizer.AudioFrame, Error> {
        noteSynthesisRequestForTesting()
        try await prepareForSynthesis()
        return try await manager.synthesizeStreaming(text: text, voice: voice)
    }

    func makeReplySession(voice: String) async throws -> PocketTtsSession {
        let observe = SelfTest.requested == "--selftest-tts-pocket"
            && CommandLine.arguments.contains("--tts-pocket-pipeline")
        let observedGeneration = replyGeneration
        if observe {
            SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=prepare_enter owner_generation=\(observedGeneration) host=\(mach_absolute_time())")
        }
        try await prepareForSynthesis()
        if observe {
            SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=prepare_ready owner_generation=\(observedGeneration) host=\(mach_absolute_time())")
            SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=session_enter owner_generation=\(observedGeneration) host=\(mach_absolute_time())")
        }
        let session = try await manager.makeSession(voice: voice)
        if observe {
            SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=session_return owner_generation=\(observedGeneration) host=\(mach_absolute_time())")
        }
        do { try checkTerminationAdmission() }
        catch { await session.cancel(); throw error }
        return session
    }

    /// Actual ordinary private preparation, not cache-only initialization.
    private static func runPreparationVoiceSelfTest() async -> Bool {
        guard isPreparationVoiceFixture,
              let i = CommandLine.arguments.firstIndex(of: "--pocket-cached-assets"),
              CommandLine.arguments.indices.contains(i + 1) else {
            SelfTest.diagnostic("POCKET_PREPARATION_VOICE_INPUT_INVALID: temporary assets required")
            return false
        }
        let owner: PocketAgentVoice
        let trace = StartupTerminationTrace(autoQuit: false)
        do {
            let root = try NativeStartupTerminationSelfTest.validateAssets(
                URL(fileURLWithPath: CommandLine.arguments[i + 1]), pocket: true)
            let alternate = root.appendingPathComponent("Models/" + Repo.pocketTts.folderName + "/"
                + PocketTtsLanguage.english.repoSubdirectory + "/constants_bin/michael.safetensors")
            guard let values = try? alternate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                SelfTest.diagnostic("POCKET_PREPARATION_VOICE_INPUT_INVALID: alternate conditioning required")
                return false
            }
            owner = try PocketAgentVoice(terminationFixtureRoot: root, trace: trace)
        } catch {
            SelfTest.diagnostic("POCKET_PREPARATION_VOICE_INPUT_INVALID: refused fixture assets")
            return false
        }
        let oldOffline = ModelHub.offlineMode
        ModelHub.offlineMode = true // Exact isolated diagnostic, never production.
        defer { ModelHub.offlineMode = oldOffline }
        owner.preparationVoiceForTesting = "alba"
        var loadedVoice: String?
        var warmVoice: String?
        // Real initialize() has returned here. The supplied choice changes
        // across that await; no Settings write or model/provider fake.
        owner.preparationLoadedForTesting = {
            loadedVoice = owner.preparationVoiceForTesting
            owner.preparationVoiceForTesting = "michael"
        }
        owner.preparationWarmVoiceForTesting = { warmVoice = $0 }
        await owner.prepare()
        let ready = owner.isReady
        let observed = trace.snapshot()
        await owner.finishTermination()
        owner.preparationLoadedForTesting = nil
        owner.preparationWarmVoiceForTesting = nil
        let failures: [String] = [
            loadedVoice != "alba" ? "chosen voice was not supplied at actual load checkpoint" : nil,
            warmVoice != "alba" ? "chosen voice was reread after native initialization await" : nil,
            !ready ? "actual unheard nonzero prediction did not complete" : nil,
            observed.loadStarts != 1 || observed.loadEnds != 1 || observed.warmStarts != 1
                || observed.readyPublications != 1 || observed.ownedTaskEnds != 1
                ? "actual preparation/readiness/join counts differ" : nil,
            owner.isPreparing || trace.snapshot().ownedTaskPending ? "owner remained pending after join" : nil,
        ].compactMap { $0 }
        SelfTest.diagnostic("POCKET_PREPARATION_VOICE chosen=alba observed_warm=\(warmVoice ?? "none") "
            + "loads=\(observed.loadStarts) primes=\(observed.warmStarts) ready=\(ready) joined=\(!trace.snapshot().ownedTaskPending)")
        for failure in failures { SelfTest.diagnostic("POCKET_PREPARATION_VOICE_ASSERT_FAILED: " + failure) }
        SelfTest.diagnostic(failures.isEmpty ? "POCKET_PREPARATION_VOICE_OK" : "POCKET_PREPARATION_VOICE_FAILED")
        return failures.isEmpty
    }

    static func runSelfTest() async -> Bool {
        if isPreparationVoiceFixture { return await runPreparationVoiceSelfTest() }
        if CommandLine.arguments.contains("--tts-pocket-pipeline") {
            return await PocketReplyPipelineSelfTest.run()
        }
        let voice = PocketAgentVoice.shared
        await voice.prepare()
        guard voice.isReady else {
            print("POCKET_TTS_FAILED: \(voice.errorMessage ?? "model did not load")")
            return false
        }
        do {
            let data = try await voice.manager.synthesize(
                text: "Hi, I'm Next. I can help you plan your day and find what matters.",
                voice: "alba"
            )
            guard data.count > 10_000, data.dropFirst(44).contains(where: { $0 != 0 }) else {
                print("POCKET_TTS_FAILED: no generated speech")
                return false
            }
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/NextNotesTTS", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sample = directory.appendingPathComponent("pocket-preview.wav")
            try data.write(to: sample, options: .atomic)
            let playback = PocketSpeechBacking()
            var started = 0
            var finished = 0
            var beganAt: Date?
            var finishedAt: Date?
            playback.onUtteranceStarted = { _ in
                started += 1
                if beganAt == nil { beganAt = Date() }
            }
            playback.onUtteranceFinished = { _ in
                finished += 1
                if finishedAt == nil { finishedAt = Date() }
            }
            playback.speak("Here is the first sentence.", volume: 0, token: 1)
            for _ in 0..<200 where finished == 0 {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard started == 1, finished == 1, !playback.isPlaybackEngineRunning,
                  let beganAt, let finishedAt,
                  finishedAt.timeIntervalSince(beganAt) > 0.25 else {
                playback.stop()
                print("POCKET_TTS_FAILED: first clause did not drain and stop its output engine")
                return false
            }
            playback.speak("Here is the next sentence.", volume: 0, token: 1)
            for _ in 0..<150 where started < 2 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let stoppedAt = ContinuousClock.now
            playback.stop()
            guard started == 2, !playback.isSpeaking,
                  stoppedAt.duration(to: .now) < .milliseconds(100) else {
                print("POCKET_TTS_FAILED: second clause did not start or stop promptly")
                return false
            }
            print("Pocket TTS generated \(data.count) bytes at \(sample.path)")
            print("POCKET_TTS_OK")
            return true
        } catch {
            print("POCKET_TTS_FAILED: \(error.localizedDescription)")
            return false
        }
    }
}

/// Fixture-only numeric playback observations captured before any MainActor hop.
struct PocketPlayedBufferObservation: Sendable {
    let token: UInt64
    let ordinal: Int
    let samples: Int
    let nonzero: Bool
    let scheduledHostTime: UInt64
    let playedHostTime: UInt64
}

/// Playback-only engine. One native session belongs to one reply; a stopped
/// generation cannot schedule another frame or complete a successor clause.
@MainActor
final class PocketSpeechBacking: AgentReplySpeechBacking {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private let voiceForTesting: String?
    private let voiceOwner: PocketAgentVoice
    private var replyWork: (@MainActor @Sendable () async throws -> Void)?
    var replyWorkForTesting: (@MainActor @Sendable () async throws -> Void)? {
        get { replyWork }
        set {
            if SelfTest.requested == "--selftest-tts-pocket"
                && CommandLine.arguments.contains("--tts-pocket-pipeline") { replyWork = newValue }
        }
    }
    private(set) var engineStartsForTesting = 0
    private var playedBufferObserver: (@Sendable (PocketPlayedBufferObservation) -> Void)?
    var playedBufferObserverForTesting: (@Sendable (PocketPlayedBufferObservation) -> Void)? {
        get { playedBufferObserver }
        set { if SelfTest.isRunning { playedBufferObserver = newValue } }
    }
    // Text exists here only while the asynchronous native session is being
    // created or its existing output has reached the bounded playback window.
    // After enqueue the native session owns text; this retains callback metadata.
    private struct Clause {
        let token: UInt64
        var text: String?
        let submittedAt: Date
        var firstProducedAt: Date?
        var pendingFrames = 0
        var ordinal = 0
        var produced = false
        var sealed = false
        var firstPlayed = false
        var startReported = false
        var firstPlayedHostTime: UInt64?
        var firstPlayedSamples = 0
        var lastPlayedHostTime: UInt64 = 0
        var gapReported = false
    }
    private var clauses: [Clause] = []
    private var completed = 0
    private var lastProducedIndex: Int?
    private var replyCorrelation: LatencyCorrelation?
    private var replyStartedAt = Date()
    private var replyStartedHostTime: UInt64 = 0
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var nativeSession: PocketTtsSession?
    private var inputFinished = false
    private var nativeInputFinished = false
    private var producerFinished = false
    private var pendingSamples = 0
    private let maximumPendingSamples = 72_000 // Three seconds, 24kHz mono.
    private var capacityWaiter: CheckedContinuation<Void, Never>?
    private var speaking = false
    private var pausedForListening = false
    private var volume: Float = 1
    var onUtteranceStarted: ((UInt64) -> Void)?
    var onUtteranceFinished: ((UInt64) -> Void)?
    var onFailure: ((String, Float, UInt64) -> Void)?

    init(voiceForTesting: String? = nil, voiceOwnerForTesting: PocketAgentVoice? = nil) {
        let fixture = SelfTest.requested == "--selftest-tts-pocket"
            && CommandLine.arguments.contains("--tts-pocket-pipeline")
        self.voiceForTesting = fixture ? voiceForTesting : nil
        voiceOwner = fixture ? (voiceOwnerForTesting ?? .shared) : .shared
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        VoicePlaybackReference.install(on: engine)
    }

    var isSpeaking: Bool { speaking }
    var outputGain: Float { player.volume }
    func setOutputGain(_ gain: Float) { player.volume = max(0, min(1, gain)) }
    var isPlaybackEngineRunning: Bool { engine.isRunning }

    // Non-streaming callers use the identical reply lifecycle and native join.
    func speak(_ text: String, volume: Float, token: UInt64) {
        beginReply(volume: volume)
        enqueue(text, token: token)
        finishReply()
    }

    func beginReply(volume: Float) {
        stop()
        self.volume = max(0, min(1, volume))
        speaking = true
        producerFinished = false
        inputFinished = false
        nativeInputFinished = false
        let reply = generation
        replyCorrelation = LatencyCorrelation.current
        replyStartedAt = Date()
        replyStartedHostTime = mach_absolute_time()
        if SelfTest.requested == "--selftest-tts-pocket",
           CommandLine.arguments.contains("--tts-pocket-pipeline") {
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=begin_reply reply=\(reply) host=\(replyStartedHostTime) numer=\(timebase.numer) denom=\(timebase.denom)")
        }
        let voice = voiceForTesting ?? Settings.shared.agentPocketVoice
        task = voiceOwner.startReplyPlayback(self) { [weak self] in
            guard let self, generation == reply else { return }
            await generateReply(voice: voice, reply: reply)
        }
        if task == nil { speaking = false }
    }

    func enqueue(_ text: String, token: UInt64) {
        guard speaking, !inputFinished, !text.isEmpty,
              !clauses.contains(where: { $0.token == token }) else { return }
        voiceOwner.noteSynthesisRequestForTesting()
        let submittedAt = Date()
        clauses.append(Clause(token: token, text: text, submittedAt: submittedAt))
        let submitted = String(format: "Pocket TTS clause submitted %.3f token=%llu characters=%d",
                               submittedAt.timeIntervalSince1970, token, text.count)
        Log.agent.info("\(submitted, privacy: .public)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(submitted) }
        flushSubmittedText()
    }

    func finishReply() {
        guard speaking, !inputFinished else { return }
        inputFinished = true
        flushSubmittedText()
    }

    private func flushSubmittedText() {
        guard speaking, let nativeSession, !nativeInputFinished,
              pendingSamples < maximumPendingSamples else { return }
        for index in clauses.indices {
            if let text = clauses[index].text {
                nativeSession.enqueue(text)
                if SelfTest.requested == "--selftest-tts-pocket",
                   CommandLine.arguments.contains("--tts-pocket-pipeline") {
                    SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=submitted reply=\(generation) token=\(clauses[index].token) host=\(mach_absolute_time())")
                }
                clauses[index].text = nil
            }
        }
        if inputFinished && clauses.allSatisfy({ $0.text == nil }) {
            nativeInputFinished = true
            nativeSession.finish()
        }
    }

    private func generateReply(voice: String, reply: UInt64) async {
        var session: PocketTtsSession?
        var failure: Error?
        do {
            try Task.checkCancellation()
            if let work = replyWork {
                try await work()
                try Task.checkCancellation()
                return
            }
            // Activate output while the model prepares, as the original one-shot
            // path did. Starting at first PCM puts device startup on audible latency.
            engine.mainMixerNode.outputVolume = volume
            if !engine.isRunning {
                try engine.start()
                if SelfTest.isRunning { engineStartsForTesting += 1 }
            }
            if !pausedForListening && !player.isPlaying { player.play() }
            let created = try await voiceOwner.makeReplySession(voice: voice)
            session = created
            try Task.checkCancellation()
            guard generation == reply else { throw CancellationError() }
            nativeSession = created
            flushSubmittedText()
            for try await frame in created.frames {
                // Actual stream receipt, before clause callbacks/actor-side logging.
                var firstPCMReceivedHostTime: UInt64 = 0
                if SelfTest.requested == "--selftest-tts-pocket",
                   CommandLine.arguments.contains("--tts-pocket-pipeline"),
                   let index = frame.utteranceIndex, clauses.indices.contains(index),
                   !clauses[index].produced { firstPCMReceivedHostTime = mach_absolute_time() }
                try Task.checkCancellation()
                guard generation == reply else { throw CancellationError() }
                guard let index = frame.utteranceIndex, clauses.indices.contains(index),
                      !clauses[index].sealed else { throw PocketPlaybackError.emptyOutput }
                if lastProducedIndex != index {
                    if let previous = lastProducedIndex {
                        guard index == previous + 1 else { throw PocketPlaybackError.emptyOutput }
                        clauses[previous].sealed = true
                        publishPlayedClauses(reply: reply)
                        // Synth callbacks can synchronously stop or replace this reply.
                        guard generation == reply else { throw CancellationError() }
                    } else if index != 0 { throw PocketPlaybackError.emptyOutput }
                    lastProducedIndex = index
                }
                if !clauses[index].produced {
                    clauses[index].produced = true
                    if SelfTest.requested == "--selftest-tts-pocket",
                       CommandLine.arguments.contains("--tts-pocket-pipeline") {
                        SelfTest.diagnostic("POCKET_REPLY_PREPARATION stage=first_pcm_received reply=\(reply) token=\(clauses[index].token) samples=\(frame.samples.count) host=\(firstPCMReceivedHostTime)")
                    }
                    let producedAt = Date()
                    clauses[index].firstProducedAt = producedAt
                    let detail = String(format: "Pocket TTS first PCM %.3f token=%llu synthesis=%.3fs samples=%d",
                        producedAt.timeIntervalSince1970, clauses[index].token,
                        producedAt.timeIntervalSince(clauses[index].submittedAt), frame.samples.count)
                    Log.agent.info("\(detail, privacy: .public)")
                    if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
                    VoiceLatencyTimeline.shared.mark(.ttsFirstPCM)
                }
                try await schedule(frame.samples, index: index, reply: reply)
            }
            try Task.checkCancellation()
            guard generation == reply, inputFinished, !clauses.isEmpty,
                  clauses.allSatisfy(\.produced) else { throw PocketPlaybackError.emptyOutput }
        } catch { failure = error }
        // Stream iteration cancellation alone can return before the native
        // session's onTermination cancellation task joins its CoreML prediction.
        // Retain and explicitly join this SAME session before releasing ownership.
        await session?.cancel()
        guard generation == reply else { return }
        nativeSession = nil
        if let failure {
            if failure is CancellationError { return }
            let head = clauses.indices.contains(completed) ? clauses[completed] : nil
            let failedVolume = volume
            Log.agent.error("Pocket TTS synthesis failed: \(failure.localizedDescription, privacy: .public)")
            stop()
            if let head { onFailure?("", failedVolume, head.token) }
        } else {
            producerFinished = true
            for index in clauses.indices { clauses[index].sealed = true }
            publishPlayedClauses(reply: reply)
        }
    }

    private func schedule(_ frame: [Float], index: Int, reply: UInt64) async throws {
        guard !frame.isEmpty, frame.count <= maximumPendingSamples else { throw PocketPlaybackError.emptyOutput }
        // 10ms first-playback acknowledgement. All PCM is retained: native80ms
        // frames/generation stay unchanged; only each utterance's first frame
        // is scheduled as240samples plus its exact remainder.
        let head = min(240, frame.count)
        let ranges = clauses[index].ordinal == 0 && head < frame.count
            ? [0..<head, head..<frame.count] : [0..<frame.count]
        for range in ranges {
            while pendingSamples + range.count > maximumPendingSamples {
                await withCheckedContinuation { capacityWaiter = $0 }
                try Task.checkCancellation()
                guard generation == reply else { throw CancellationError() }
            }
            try Task.checkCancellation()
            guard generation == reply else { throw CancellationError() }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(range.count)),
                let samples = buffer.floatChannelData?[0] else { throw PocketPlaybackError.emptyOutput }
            buffer.frameLength = buffer.frameCapacity
            for (offset, sample) in frame[range].enumerated() { samples[offset] = sample }
            if !engine.isRunning {
                engine.mainMixerNode.outputVolume = volume
                try engine.start()
                if SelfTest.isRunning { engineStartsForTesting += 1 }
            }
            let token = clauses[index].token
            let ordinal = clauses[index].ordinal
            clauses[index].ordinal += 1
            clauses[index].pendingFrames += 1
            pendingSamples += range.count
            let observer = playedBufferObserver
            let count = range.count
            let nonzero = observer != nil && frame[range].contains { abs($0) > 0.0001 }
            let scheduledHostTime = observer == nil ? 0 : mach_absolute_time()
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                let playedHostTime = mach_absolute_time()
                observer?(.init(token: token, ordinal: ordinal, samples: count,
                    nonzero: nonzero, scheduledHostTime: scheduledHostTime,
                    playedHostTime: playedHostTime))
                Task { @MainActor in self?.framePlayed(reply: reply, index: index, samples: count,
                                                     ordinal: ordinal, playedHostTime: playedHostTime) }
            }
            if !pausedForListening && !player.isPlaying { player.play() }
        }
    }

    // Caller does not wait; output stops synchronously, native ownership stays
    // retained until this task's explicit cancel/join path has returned.
    func stop() {
        generation &+= 1
        task?.cancel()
        player.stop()
        engine.stop()
        MainActorSection.run("echo.stopped") { VoicePlaybackReference.stopped() }
        speaking = false
        pausedForListening = false
        clauses.removeAll()
        completed = 0
        lastProducedIndex = nil
        replyCorrelation = nil
        replyStartedHostTime = 0
        nativeSession = nil
        pendingSamples = 0
        inputFinished = true
        nativeInputFinished = true
        producerFinished = false
        capacityWaiter?.resume()
        capacityWaiter = nil
    }

    func finishStoppedPlayback() async {
        let owned = task
        let stoppedGeneration = generation
        await owned?.value
        if generation == stoppedGeneration && !speaking { task = nil }
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        if pendingSamples > 0 && !player.isPlaying { player.play() }
        capacityWaiter?.resume()
        capacityWaiter = nil
        flushSubmittedText()
    }

    private func framePlayed(reply: UInt64, index: Int, samples: Int,
                             ordinal: Int, playedHostTime: UInt64) {
        MainActorSection.run("tts.played") {
            guard generation == reply, speaking, clauses.indices.contains(index),
                  clauses[index].pendingFrames > 0 else { return }
            clauses[index].pendingFrames -= 1
            if ordinal == 0 {
                clauses[index].firstPlayedHostTime = playedHostTime
                clauses[index].firstPlayedSamples = samples
            }
            clauses[index].lastPlayedHostTime = max(clauses[index].lastPlayedHostTime, playedHostTime)
            if !clauses[index].firstPlayed {
                clauses[index].firstPlayed = true
                let playedAt = Date()
                let clause = clauses[index]
                let synthesis = clause.firstProducedAt?.timeIntervalSince(clause.submittedAt) ?? -1
                let render = clause.firstProducedAt.map { playedAt.timeIntervalSince($0) } ?? -1
                let detail = String(format: "Pocket TTS first played %.3f token=%llu synthesis=%.3fs render=%.3fs firstSamples=%d",
                    playedAt.timeIntervalSince1970, clause.token, synthesis, render, samples)
                Log.agent.info("\(detail, privacy: .public)")
                if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
            }
            pendingSamples -= samples
            capacityWaiter?.resume()
            capacityWaiter = nil
            flushSubmittedText()
            publishPlayedClauses(reply: reply)
        }
    }

    /// Same native callback formula as the playback probe. Negative values are
    /// retained software estimates, not evidence of physical overlap or silence.
    private func recordPlayedGaps(reply: UInt64) {
        guard generation == reply, speaking, clauses.count > 1 else { return }
        for index in 1..<clauses.count {
            guard !clauses[index].gapReported,
                  clauses[index - 1].sealed, clauses[index - 1].pendingFrames == 0,
                  let head = clauses[index].firstPlayedHostTime else { continue }
            let tail = clauses[index - 1].lastPlayedHostTime
            guard tail > 0, head >= tail, head >= replyStartedHostTime else { continue }
            let seconds = AVAudioTime.seconds(forHostTime: head - tail)
                - Double(clauses[index].firstPlayedSamples) / 24_000
            let endedAt = replyStartedAt.addingTimeInterval(
                AVAudioTime.seconds(forHostTime: head - replyStartedHostTime))
            let correlation = replyCorrelation
            clauses[index].gapReported = true
            MetricsStore.shared.recordAsync {
                LatencySpan(name: .voiceInterClauseGap,
                    startedAt: endedAt.addingTimeInterval(-seconds), endedAt: endedAt,
                    durationSeconds: seconds,
                    note: "boundary=\(index) software_playback_estimate",
                    correlation: correlation, source: "voice")
            }
        }
    }

    private func publishPlayedClauses(reply: UInt64) {
        recordPlayedGaps(reply: reply)
        while generation == reply, speaking, clauses.indices.contains(completed) {
            let index = completed
            if clauses[index].firstPlayed && !clauses[index].startReported {
                clauses[index].startReported = true
                onUtteranceStarted?(clauses[index].token)
                guard generation == reply, speaking else { return }
            }
            guard clauses[index].sealed, clauses[index].pendingFrames == 0 else { return }
            let token = clauses[index].token
            completed += 1
            onUtteranceFinished?(token)
        }
        guard generation == reply, speaking, producerFinished,
              completed == clauses.count, pendingSamples == 0 else { return }
        speaking = false
        pausedForListening = false
        player.stop()
        engine.stop()
        MainActorSection.run("echo.stopped") { VoicePlaybackReference.stopped() }
        voiceOwner.replyPlaybackDrained(self)
    }
}
private enum PocketPlaybackError: LocalizedError {
    case emptyOutput
    case modelUnavailable(String?)

    var errorDescription: String? {
        switch self {
        case .emptyOutput: "Pocket TTS generated no playable audio frames."
        case .modelUnavailable(let reason): reason ?? "Pocket TTS model did not load."
        }
    }
}
