import AVFoundation
import Foundation

/// Agent duplex I/O façade: capture stays on `AudioCaptureHub`, TTS plays out,
/// and user speech interrupts playback without waiting for the utterance to end.
///
/// ## Echo / AEC
/// The agent's output mixer supplies a render reference to
/// `AcousticEchoProcessor`, which cleans the 16 kHz mic stream before ASR,
/// local end-of-utterance detection and VAD. The reference is unavailable for
/// some output paths, so transcript evidence still protects the turn. This
/// session does:
///
/// 1. **Reversible provisional listening** — a novel ASR hypothesis pauses the
///    current clause and preserves queued clauses; an echo or empty endpoint
///    resumes that same token. A committed novel turn then stops TTS and clears
///    the queue.
/// 2. **Optional output ducking** — while speaking, utterance volume is lowered
///    so speaker→mic bleed is less likely to false-trigger VAD.
/// 3. **Recent playback echo filtering** — reflected words are removed from
///    cumulative ASR, including a real interruption mixed with speaker bleed.
///
/// ## Streaming spoken replies
/// Prefer `beginSpokenReply` / `appendSpokenReply` / `finalizeSpokenReply` when
/// tokens arrive while generation is in flight. `speak(_:)` is the convenience
/// for a finished string: one append + finalize through the same buffer.
/// Producers with no token stream yet must still go through that path so the
/// seam is exercised; the normal model-led tool loop now calls `append` as
/// answer tokens arrive.
///
/// Dictation never opens this session and never speaks. The agent tool loop
/// does not await utterance completion — `speak` / first `append` that yields
/// a clause returns at once after enqueueing.
///
/// Turn boundaries, tools and harness stay on `RealtimeAgent` /
/// `AgentCaptureController`. A fuller `RealtimeRuntime` can absorb those later;
/// this type is the duplex audio start (roadmap §24).
@MainActor
final class RealtimeAudioSession {
    static let shared = RealtimeAudioSession()

    enum Phase: String, Sendable {
        case idle
        case listening
        case speaking
    }

    /// Lowered playback while the agent is speaking. Best-effort ducking only.
    static let duckedVolume: Float = 0.65
    static let fullVolume: Float = 1.0

    private(set) var phase: Phase = .idle
    private(set) var isActive = false
    /// True between first spoken clause and the next `stop` / barge-in / natural
    /// end of the last clause.
    private(set) var isSpeaking = false
    /// When false, speak uses full volume (tests / Settings later).
    var duckingEnabled = true

    /// Last barge-in → TTS stopped interval, for metrics / self-test.
    private(set) var lastBargeInStopSeconds: TimeInterval?
    private(set) var lastListeningPauseAt: Date?
    private struct ListeningHold {
        let captureID: UUID
        let outputGeneration: UInt64
        let beganAt: Date
        var lastNearAt: Date
    }
    private var listeningHold: ListeningHold?
    private static let listeningQuietRelease: TimeInterval = 0.25
    private static let listeningMaximumUnrecognizedHold: TimeInterval = 2.5

    /// Clause-by-clause flush while reply text is still growing.
    private let speechBuffer = StreamingSpeechBuffer()
    struct EchoRecognitionState: Sendable {
        fileprivate var words: [String] = []
        fileprivate var echoMask: [Bool] = []

        mutating func reset() {
            words.removeAll()
            echoMask.removeAll()
        }
    }

    struct EchoRecognitionResult: Sendable {
        let text: String
        let words: [String]
        let echoMask: [Bool]
    }

    private struct OutputReference {
        var text: String
        var at: Date
        var active: Bool
    }
    private struct Word {
        var value: String
        var range: Range<String.Index>
    }
    private var recentOutputs: [OutputReference] = []
    private static let echoWindow: TimeInterval = 15
    private static let maxEchoReferences = 6
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    private init() {}

    // MARK: - Session lifecycle

    /// Agent listen opened. Capture still starts on the hub via
    /// `AgentCaptureController` — this only tracks duplex phase.
    func begin() {
        AcousticEchoProcessor.shared.reset()
        AgentSpeechSynthesizer.shared.onPlaybackEvent = { [weak self] event in
            self?.receivePlaybackEvent(event)
            VoicePlaybackDelivery.shared.receive(event)
        }
        isActive = true
        isSpeaking = false
        phase = .listening
        speechBuffer.cancel()
        recentOutputs.removeAll()
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
        lastBargeInStopSeconds = nil
        lastListeningPauseAt = nil
        listeningHold = nil
        Log.agent.info("duplex · begin")
    }

    /// Session closed. Stops any in-flight utterance and clears pending clauses.
    func end() {
        listeningHold = nil
        stopOutput()
        AgentSpeechSynthesizer.shared.endPersistentPocketPlayback()
        AcousticEchoProcessor.shared.reset()
        VoicePlaybackDelivery.shared.endSession()
        isActive = false
        phase = .idle
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
        Log.agent.info("duplex · end")
    }

    // MARK: - Output

    /// Start a streamed spoken reply. Clears any prior utterance.
    /// Call `appendSpokenReply` as text grows, then `finalizeSpokenReply`.
    func beginSpokenReply() {
        listeningHold = nil
        speechBuffer.begin()
        applySpeakingVolumeIfActive()
    }

    /// Feed partial reply text. Completed clauses enqueue immediately when
    /// policy allows; silent forms (URL / listing / …) enqueue nothing.
    func appendSpokenReply(_ chunk: String) {
        speechBuffer.append(chunk)
        noteEnqueueIfNeeded()
    }

    /// Flush any trailing incomplete clause. Safe to call after a single
    /// full-string `appendSpokenReply`.
    func finalizeSpokenReply() {
        speechBuffer.finalize()
        noteEnqueueIfNeeded()
    }

    /// Speak a finished reply without blocking. Routes through the streaming
    /// buffer (begin → append → finalize) so one-shot and token-stream paths
    /// share the same queue. Empty spoken forms are a no-op and do not
    /// interrupt whatever is already playing.
    func speak(_ reply: String) {
        guard !AgentSpeechPolicy.spokenClauses(reply).isEmpty else { return }
        beginSpokenReply()
        appendSpokenReply(reply)
        finalizeSpokenReply()
    }

    /// Keep recent replies across barge-in: SpeechAnalyzer can deliver a delayed
    /// cumulative revision after the speaker stops. This is transcript-level
    /// isolation; the mic stays live so a person can interrupt the reply.
    func isLikelyPlaybackEcho(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userSpeechExcludingPlayback(text).isEmpty
    }

    /// Remove long contiguous spans present in our own recent replies. Preserve
    /// new speech before or after a reflected span; a whole-string containment
    /// test missed exactly that mixed case in the user's 08:31 transcript.
    func userSpeechExcludingPlayback(
        _ text: String,
        now: Date = Date()
    ) -> String {
        let heard = Self.words(in: text)
        let mask = playbackEchoMask(for: heard, provisional: false, now: now)
        return Self.removingEchoWords(from: text, words: heard, mask: mask)
    }

    /// Reconcile a cumulative recognizer snapshot without forgetting which
    /// leading token positions were already identified as playback. The
    /// caller owns one state per recognizer and resets it at turn/session or
    /// decoder-discontinuity boundaries.
    @discardableResult
    func userSpeechExcludingPlayback(
        _ text: String,
        recognition: inout EchoRecognitionState,
        provisional: Bool = false,
        now: Date = Date()
    ) -> EchoRecognitionResult {
        let heard = Self.words(in: text)
        let currentWords = heard.map(\.value)
        var inherited = [Bool](repeating: false, count: heard.count)
        let common = min(recognition.words.count, currentWords.count)
        for index in 0..<common {
            guard recognition.words[index] == currentWords[index] else { break }
            if index < recognition.echoMask.count { inherited[index] = recognition.echoMask[index] }
        }
        // Apply retained positions before testing the remaining single word;
        // otherwise a stale known echo plus a fresh fuzzy echo hides both from
        // the one-word residual rule.
        let mask = playbackEchoMask(for: heard, provisional: provisional,
            now: now, inherited: inherited)
        let retainedMask = playbackEchoMask(for: heard, provisional: false,
            now: now, inherited: inherited)
        recognition.words = currentWords
        recognition.echoMask = retainedMask
        return EchoRecognitionResult(
            text: Self.removingEchoWords(from: text, words: heard, mask: mask),
            words: currentWords,
            echoMask: mask
        )
    }

    private func playbackEchoMask(
        for heard: [Word], provisional: Bool, now: Date, inherited: [Bool]? = nil
    ) -> [Bool] {
        var mask = inherited ?? [Bool](repeating: false, count: heard.count)
        let references = recentOutputs.filter { $0.active
            || now.timeIntervalSince($0.at) < Self.echoWindow }
        for reference in references {
            let spoken = Self.words(in: reference.text)
            guard !spoken.isEmpty else { continue }
            for i in heard.indices {
                for j in spoken.indices where heard[i].value == spoken[j].value {
                    var count = 0
                    while i + count < heard.count, j + count < spoken.count,
                          heard[i + count].value == spoken[j + count].value {
                        count += 1
                    }
                    let shortEdge = count == 2
                        && (heard.count == 2 || i == 0 || i + count == heard.count)
                    if count >= 3 || shortEdge {
                        for index in i..<(i + count) { mask[index] = true }
                    }
                    guard provisional, count >= 2,
                          i + count == heard.count - 1, j + count < spoken.count else {
                        continue
                    }
                    let partial = heard[heard.count - 1].value
                    let next = spoken[j + count].value
                    guard partial.count >= 2, partial != next,
                          next.hasPrefix(partial) else { continue }
                    for index in i..<heard.count { mask[index] = true }
                }
            }
        }
        // Span removal is complete across all references before we inspect its
        // residue. Reference iteration order must not decide whether a tail
        // can be matched against an earlier, still-fresh clause.
        let residualIndices = heard.indices.filter { !mask[$0] }
        if residualIndices.count == 1, let index = residualIndices.first {
            for reference in references {
                let age = now.timeIntervalSince(reference.at)
                if Self.words(in: reference.text).contains(where: { spoken in
                    spoken.value == heard[index].value
                        || (heard[index].value.count >= 4 && (reference.active || age < 3)
                            && Self.oneEditApart(heard[index].value, spoken.value))
                }) {
                    mask[index] = true
                    break
                }
            }
        }
        return mask
    }

    private static func removingEchoWords(
        from text: String, words: [Word], mask: [Bool]
    ) -> String {
        guard !words.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var runs: [(start: String.Index, end: String.Index)] = []
        var index = 0
        while index < words.count {
            guard index < mask.count, mask[index] else {
                index += 1
                continue
            }
            let start = words[index].range.lowerBound
            var end = words[index].range.upperBound
            index += 1
            while index < words.count, index < mask.count, mask[index] {
                end = words[index].range.upperBound
                index += 1
            }
            runs.append((start, end))
        }
        guard !runs.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var pieces: [String] = []
        var cursor = text.startIndex
        func kept(_ part: Substring, afterEcho: Bool) -> String {
            let value = afterEcho
                ? part.drop(while: { $0.isWhitespace || $0.isPunctuation }) : part
            return String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for run in runs {
            let piece = kept(text[cursor..<run.start], afterEcho: cursor != text.startIndex)
            if !piece.isEmpty { pieces.append(piece) }
            cursor = run.end
        }
        let tail = kept(text[cursor...], afterEcho: true)
        if !tail.isEmpty { pieces.append(tail) }
        return pieces.joined(separator: " ")
    }

    /// Learn echo text only after the backing reports that this clause began
    /// rendering. Queued text has no acoustic evidence and is never recorded.
    private func receivePlaybackEvent(_ event: AgentSpeechSynthesizer.PlaybackEvent) {
        switch event {
        case .startAcknowledged(let text):
            recentOutputs.append(OutputReference(text: text, at: Date(), active: true))
            if recentOutputs.count > Self.maxEchoReferences {
                recentOutputs.removeFirst(recentOutputs.count - Self.maxEchoReferences)
            }
        case .completed(let text):
            finishPlaybackReference(text)
        case .interrupted(let text, wasRendered: true):
            finishPlaybackReference(text)
        case .began, .enqueued, .interrupted(_, wasRendered: false):
            break
        }
    }

    private func finishPlaybackReference(_ text: String) {
        guard let index = recentOutputs.lastIndex(where: {
            $0.active && $0.text == text
        }) else { return }
        recentOutputs[index].active = false
        recentOutputs[index].at = Date()
    }

    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            guard edits <= 1 else { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    private static func words(in text: String) -> [Word] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordPattern.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Word(value: String(text[range]).lowercased(), range: range)
        }
    }

    /// Last clause finished — keep phase honest when idle.
    func noteOutputFinished() {
        guard isSpeaking else { return }
        listeningHold = nil
        isSpeaking = false
        if isActive { phase = .listening }
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
    }

    // MARK: - Barge-in

    /// A plausible near-mic candidate holds rendered speech in place. It does
    /// not cancel the response task, current clause, or queued clauses. Only
    /// recognized novel words take the hard-stop path below.
    @discardableResult
    func pauseForListening(captureID: UUID, now: Date = Date()) -> Bool {
        let synth = AgentSpeechSynthesizer.shared
        guard isActive, isSpeaking, synth.isSpeaking else { return false }
        if var hold = listeningHold {
            guard hold.captureID == captureID,
                  hold.outputGeneration == synth.outputGeneration else { return false }
            hold.lastNearAt = now
            listeningHold = hold
            return true
        }
        synth.pauseForListening()
        guard synth.isPausedForListening else { return false }
        listeningHold = ListeningHold(captureID: captureID,
            outputGeneration: synth.outputGeneration, beganAt: now, lastNearAt: now)
        lastListeningPauseAt = Date()
        return true
    }

    /// A short nonlexical backchannel, false candidate, or unrecognized quiet
    /// releases the same playback token. A new reply or session cannot inherit
    /// an old candidate's delayed resume.
    @discardableResult
    func resumeAfterListening(captureID: UUID) -> Bool {
        guard let hold = listeningHold, hold.captureID == captureID else { return false }
        listeningHold = nil
        let synth = AgentSpeechSynthesizer.shared
        guard synth.outputGeneration == hold.outputGeneration,
              synth.isPausedForListening else { return false }
        synth.resumeAfterListening()
        return !synth.isPausedForListening
    }

    func reviewListeningPause(captureID: UUID, nearSpeech: Bool,
        recognizedSpeech: Bool, now: Date = Date()) {
        guard var hold = listeningHold, hold.captureID == captureID else { return }
        if recognizedSpeech { return }
        if nearSpeech { hold.lastNearAt = now; listeningHold = hold }
        if now.timeIntervalSince(hold.lastNearAt) >= Self.listeningQuietRelease
            || now.timeIntervalSince(hold.beganAt) >= Self.listeningMaximumUnrecognizedHold {
            _ = resumeAfterListening(captureID: captureID)
        }
    }

    /// User speech / `RealtimeAgent.interrupt`: stop TTS immediately and clear
    /// every pending clause. Capture uses this through `userSpeechStarted`;
    /// the work item and its result ledger survive the playback interruption.
    func noteUserSpeech() {
        listeningHold = nil
        let wasSpeaking = isSpeaking || AgentSpeechSynthesizer.shared.isSpeaking
        let started = ContinuousClock.now
        stopOutput()
        if wasSpeaking {
            let elapsed = started.duration(to: .now)
            lastBargeInStopSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            Log.agent.info(
                "duplex · barge-in stop \(self.lastBargeInStopSeconds ?? -1, format: .fixed(precision: 4))s"
            )
        }
        if isActive {
            phase = .listening
        }
    }

    private func stopOutput() {
        listeningHold = nil
        speechBuffer.cancel()
        AgentSpeechSynthesizer.shared.stop()
        isSpeaking = false
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
    }

    private func applySpeakingVolumeIfActive() {
        guard isActive else { return }
        AgentSpeechSynthesizer.shared.utteranceVolume =
            duckingEnabled ? Self.duckedVolume : Self.fullVolume
    }

    private func noteEnqueueIfNeeded() {
        guard speechBuffer.didEnqueue else { return }
        if isActive {
            isSpeaking = true
            phase = .speaking
            applySpeakingVolumeIfActive()
        } else {
            // Test / closed session: still allow one-shot speak for island Stop,
            // but do not claim duplex speaking state.
            isSpeaking = false
        }
    }
}

// MARK: - Self-test

extension RealtimeAudioSession {
    /// Duplex invariants. Never calls `RunLog.record`. Not wired into
    /// `NextNotesApp` — invoke directly or park `--selftest-duplex` later:
    /// ```
    /// if arguments.contains("--selftest-duplex") {
    ///     Task { @MainActor in
    ///         await RealtimeAudioSession.runSelfTest()
    ///         NSApp.terminate(nil)
    ///     }
    ///     return true
    /// }
    /// ```
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []

        failures += bargeInFailures()
        failures += echoFilterFailures()
        failures += firstAudioCallbackFailures()
        failures += await singleInputEngineFailures()
        failures += speakingStateFailures()
        failures += dictationStaysSilentFailures()
        failures += await captureEchoEndpointFailures()

        for failure in failures {
            print("DUPLEX_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "DUPLEX_OK" : "DUPLEX_FAILED")
        return failures.isEmpty
    }

    /// Interrupt must stop the synthesizer backing without awaiting utterance end,
    /// and clear any remaining clause queue mid-reply.
    private static func bargeInFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer {
            synth.restoreSystemBacking()
            session.end()
        }

        session.begin()
        session.speak("I found three files.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if !session.isLikelyPlaybackEcho("found three files") {
            failures.append("speaker playback was not recognized as an echo")
        }
        if session.isLikelyPlaybackEcho("open the calendar") {
            failures.append("new user speech was mistaken for playback echo")
        }
        if !session.isSpeaking || session.phase != .speaking {
            failures.append("speak did not enter speaking phase")
        }
        if recorder.spoken.isEmpty {
            failures.append("speak did not enqueue TTS")
        }

        let before = ContinuousClock.now
        session.noteUserSpeech()
        if !session.isLikelyPlaybackEcho("found three files") {
            failures.append("barge-in forgot the recent playback echo")
        }
        let elapsed = before.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("interrupt did not stop synthesizer")
        }
        if session.isSpeaking {
            failures.append("speaking flag still set after barge-in")
        }
        if session.phase != .listening {
            failures.append("phase was \(session.phase.rawValue) after barge-in, expected listening")
        }
        if seconds > 0.1 {
            failures.append(
                String(format: "barge-in stop took %.3fs (budget 0.100s)", seconds)
            )
        }

        // Agent interrupt hook must still stop TTS (Wave 1 path).
        recorder.reset()
        session.speak("Still listening.")
        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("RealtimeAgent.interrupt did not stop synthesizer")
        }

        // Clause queue: multi-sentence reply leaves pending clauses; barge-in clears them.
        recorder.reset()
        session.begin()
        session.speak("I found three files. The latest is enclosure version seventeen.")
        if recorder.spoken != ["I found three files."] {
            failures.append(
                "clause stream should speak first clause only, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount < 1 {
            failures.append(
                "clause stream should leave pending clauses, got \(synth.pendingClauseCount)"
            )
        }
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback("I found three files") != "I found three files" {
            failures.append("unrendered queued clause was learned as playback")
        }
        if synth.pendingClauseCount != 0 {
            failures.append(
                "barge-in left \(synth.pendingClauseCount) pending clauses"
            )
        }
        if recorder.spoken.count != 1 {
            failures.append(
                "barge-in must not speak remaining clauses, got \(recorder.spoken)"
            )
        }

        return failures
    }

    private static func echoFilterFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(RecordingSpeechBacking())
        defer {
            session.end()
            synth.restoreSystemBacking()
        }
        session.begin()
        var queuedRecognition = EchoRecognitionState()
        session.speak("The opening sentence. Pending orchard description.")
        let delayedToken = synth.currentPlaybackToken
        if session.userSpeechExcludingPlayback(
            "The opening sentence. Pending orchard description.",
            recognition: &queuedRecognition
        ).text != "The opening sentence. Pending orchard description." {
            failures.append("delayed nonplaying clause was learned as playback")
        }
        synth.notifyTestingFirstAudio(token: delayedToken)
        synth.notifyTestingAudioFinished(token: delayedToken)
        let queuedToken = synth.currentPlaybackToken
        if session.userSpeechExcludingPlayback(
            "The opening sentence. Pending orchard description.",
            recognition: &queuedRecognition
        ).text != "Pending orchard description." {
            failures.append("queued later clause was learned before rendering")
        }
        synth.notifyTestingFirstAudio(token: queuedToken)
        if session.userSpeechExcludingPlayback(
            "The opening sentence. Pending orchard description.",
            recognition: &queuedRecognition
        ).text != "" {
            failures.append("queued clause was not learned after rendering")
        }

        session.begin()
        session.speak("Do you have anything in mind?")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        var prefixRecognition = EchoRecognitionState()
        if session.userSpeechExcludingPlayback(
            "Do you have any", recognition: &prefixRecognition, provisional: true
        ).text != "" {
            failures.append("provisional partial playback was not withheld")
        }
        if session.userSpeechExcludingPlayback(
            "Do you have any", recognition: &prefixRecognition, provisional: false
        ).text != "any" {
            failures.append("final partial token retained a temporary prefix label")
        }
        if session.userSpeechExcludingPlayback(
            "Do you have anything please stop", recognition: &prefixRecognition,
            provisional: false
        ).text != "please stop" {
            failures.append("final playback echo did not preserve new suffix")
        }
        session.noteUserSpeech()

        session.begin()
        session.speak("Do you have anything in mind?")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        var mineRecognition = EchoRecognitionState()
        if session.userSpeechExcludingPlayback(
            "Do you have anything in Mine?", recognition: &mineRecognition
        ).text != "" {
            failures.append("fresh one-edit playback tail was not filtered")
        }
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback(
            "Do you have anything in Mine? please stop",
            recognition: &mineRecognition,
            now: Date().addingTimeInterval(Self.echoWindow + 1)
        ).text != "please stop" {
            failures.append("expired Mine echo resurrected while new suffix was present")
        }

        session.begin()
        session.speak("Green lantern closes.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        var revisionRecognition = EchoRecognitionState()
        _ = session.userSpeechExcludingPlayback(
            "Green lantern closes.", recognition: &revisionRecognition
        )
        if session.userSpeechExcludingPlayback(
            "Blue window opens.", recognition: &revisionRecognition
        ).text != "Blue window opens." {
            failures.append("revised cumulative prefix inherited stale echo labels")
        }

        session.begin()
        session.speak("What do you have in mind?")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        var appleRevision = EchoRecognitionState()
        _ = session.userSpeechExcludingPlayback("Mine?", recognition: &appleRevision)
        session.noteUserSpeech()
        let afterFuzzyTail = Date().addingTimeInterval(4)
        session.speak("I can help with questions.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback("Mine? I can help with question",
            recognition: &appleRevision, provisional: true, now: afterFuzzyTail).text != "" {
            failures.append("a retained old echo prevented filtering a fresh one-word residue")
        }
        if session.userSpeechExcludingPlayback("Mine? I can help with question please stop",
            recognition: &appleRevision, now: afterFuzzyTail).text != "please stop" {
            failures.append("a cumulative echo prefix swallowed newly appended user words")
        }
        var independentDecoder = EchoRecognitionState()
        if session.userSpeechExcludingPlayback("Mine?", recognition: &independentDecoder,
            now: afterFuzzyTail).text != "Mine?" {
            failures.append("echo classification leaked between recognizers")
        }
        appleRevision.reset()
        if session.userSpeechExcludingPlayback("Mine?", recognition: &appleRevision,
            now: afterFuzzyTail).text != "Mine?" {
            failures.append("recognizer reset retained expired echo labels")
        }
        session.begin()
        session.speak("An echoed sentence.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback(
            "Écoute 👋. An echoed sentence. Stop! An echoed sentence. Merci."
        ) != "Écoute 👋. Stop! Merci." {
            failures.append("multiple echo spans damaged Unicode text or user punctuation")
        }

        session.begin()
        session.speak("I can help you manage your calendar, draft emails, and search your files.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback("I can help you manage your") != "" {
            failures.append("partial playback became user speech")
        }
        if session.userSpeechExcludingPlayback("I can") != "" {
            failures.append("two-word playback fragment became user speech")
        }
        if session.userSpeechExcludingPlayback("Can you hear me? I can help you manage your")
            != "Can you hear me?" {
            failures.append("mixed user speech and playback were not separated")
        }
        session.noteUserSpeech()
        session.speak("Yes, I can hear you clearly. How would you like me to help you manage your calendar?")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback(
            "calendar. Yes, I can hear you clearly. How would you like me to help you manage"
        ) != "" {
            failures.append("echo tail from consecutive replies became a new request")
        }
        if session.userSpeechExcludingPlayback("Stop. Yes, I can hear you clearly") != "Stop." {
            failures.append("short novel barge-in was removed with playback")
        }
        if session.userSpeechExcludingPlayback("How would...?") != "" {
            failures.append("09:06 two-word reply tail became a user turn")
        }
        if session.userSpeechExcludingPlayback("Open the calendar") != "Open the calendar" {
            failures.append("unrelated user request was removed as playback")
        }
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback(
            "calendar.", now: Date().addingTimeInterval(10)
        ) != "" {
            failures.append("late one-word reply revision became a user turn")
        }
        if session.userSpeechExcludingPlayback("Yes, I can hear you clearly") != "" {
            failures.append("late playback tail survived after output stopped")
        }
        if session.userSpeechExcludingPlayback(
            "Yes, I can hear you clearly",
            now: Date().addingTimeInterval(Self.echoWindow + 1)
        ) != "Yes, I can hear you clearly" {
            failures.append("expired playback reference suppressed a new turn")
        }
        session.speak("I stopped the tool plan because it took too long.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback(
            "long.", now: Date().addingTimeInterval(10)
        ) != "" {
            failures.append("09:07 revised reply tail became a user turn")
        }
        session.speak("I don't have ears to hear audio.")
        let activeLongToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: activeLongToken)
        if session.userSpeechExcludingPlayback(
            "Audi.", now: Date().addingTimeInterval(4)
        ) != "" {
            failures.append("active long clause let one-edit playback tail through")
        }
        synth.notifyTestingAudioFinished(token: activeLongToken)
        if session.userSpeechExcludingPlayback(
            "Audi.", now: Date().addingTimeInterval(4)
        ) != "Audi." {
            failures.append("completed one-edit reference did not expire independently")
        }
        session.speak("An older completed clause should expire on its own.")
        let oldToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: oldToken)
        synth.notifyTestingAudioFinished(token: oldToken)
        let completedAt = Date()
        session.speak("A fresh active clause remains current.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback(
            "older completed clause", now: completedAt.addingTimeInterval(16)
        ) != "older completed clause" {
            failures.append("completed reference did not expire independently")
        }
        session.noteUserSpeech()
        session.speak("I don't have ears to hear audio.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        if session.userSpeechExcludingPlayback("Audi.") != "" {
            failures.append("09:48 one-word audio echo became a user turn")
        }
        if session.userSpeechExcludingPlayback("Stop.") != "Stop." {
            failures.append("a distinct one-word interruption was suppressed")
        }
        return failures
    }

    private static func captureEchoEndpointFailures() async -> [String] {
        var failures: [String] = []
        let capture = AgentCaptureController.shared
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(RecordingSpeechBacking())
        defer {
            capture.turnHandlerForTesting = nil
            session.end()
            synth.restoreSystemBacking()
        }
        var forwarded: [String] = []
        capture.turnHandlerForTesting = { forwarded.append($0) }
        await capture.beginSession(captureAudio: false)
        session.speak("I can help you manage your calendar and files.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        capture.simulateSpeech("I can help you manage your")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        if !forwarded.isEmpty { failures.append("reflected reply reached the Agent") }

        session.speak("I can help you manage your calendar and files.")
        synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
        capture.simulateSpeech("Can you hear me? I can help you manage your")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if forwarded != ["Can you hear me?"] {
            failures.append("mixed turn was not forwarded as user speech only: \(forwarded)")
        }
        await capture.endSession(source: .done)
        return failures
    }

    /// First-audio timing must stay open after enqueue, and an interrupted
    /// utterance's late delegate event must not close the next reply's span.
    /// The recorder supplies deterministic backing while explicit tokens model
    /// the AVSpeech delegate identity that production carries.
    private static func firstAudioCallbackFailures() -> [String] {
        var failures: [String] = []
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        synth.onFirstAudio = nil
        synth.onFirstAudioCancelled = nil
        defer { synth.restoreSystemBacking() }

        var callbackCount = 0
        synth.onFirstAudio = { callbackCount += 1 }
        synth.speak("First reply.")
        let oldToken = synth.currentPlaybackToken
        if callbackCount != 0 {
            failures.append("first-audio callback ran during enqueue")
        }

        synth.stop()
        var cancelledCount = 0
        synth.speak("Replacement reply.")
        let newToken = synth.currentPlaybackToken
        synth.onFirstAudio = { callbackCount += 1 }
        synth.onFirstAudioCancelled = { cancelledCount += 1 }
        synth.notifyTestingFirstAudio(token: oldToken)
        if callbackCount != 0 {
            failures.append("stale first-audio callback closed the replacement reply")
        }
        synth.notifyTestingFirstAudio(token: newToken)
        synth.notifyTestingFirstAudio(token: newToken)
        if callbackCount != 1 {
            failures.append("current first-audio callback fired \(callbackCount) times, expected once")
        }

        // A pending callback is closed exactly once when barge-in cancels it.
        synth.speak("Cancelled reply.")
        synth.onFirstAudio = { callbackCount += 1 }
        synth.onFirstAudioCancelled = { cancelledCount += 1 }
        synth.stop()
        if cancelledCount != 1 {
            failures.append("first-audio cancellation callback fired \(cancelledCount) times, expected once")
        }
        return failures
    }

    /// Agent + another hub consumer must share one input engine start.
    private static func singleInputEngineFailures() async -> [String] {
        var failures: [String] = []
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        guard let format else {
            return ["no 16 kHz format for hub probe"]
        }

        let hub = AudioCaptureHub(probe: true)
        let sink: @Sendable (AudioChunk) -> Void = { _ in }
        let level: @Sendable (Float) -> Void = { _ in }

        do {
            try hub.subscribe(.wake, outputFormat: format, onBuffer: sink, onLevel: level)
            try hub.subscribe(.agent, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("hub subscribe failed: \(error.localizedDescription)")
            return failures
        }

        if hub.inputEngineStarts != 1 {
            failures.append(
                "agent capture would start a second input engine (starts=\(hub.inputEngineStarts))"
            )
        }
        if !hub.isSubscribed(.agent) {
            failures.append("agent consumer missing on shared hub")
        }
        if !hub.isSubscribed(.wake) {
            failures.append("wake consumer dropped when agent subscribed")
        }

        hub.unsubscribe(.agent)
        hub.unsubscribe(.wake)
        return failures
    }

    private static func speakingStateFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer {
            synth.restoreSystemBacking()
            session.end()
        }

        if session.isActive {
            session.end()
        }
        if session.phase != .idle {
            failures.append("inactive session phase is \(session.phase.rawValue), expected idle")
        }

        session.begin()
        if session.phase != .listening {
            failures.append("begin did not enter listening")
        }
        if session.duckingEnabled,
           abs(synth.utteranceVolume - Self.fullVolume) > 0.01 {
            failures.append("listening should restore full utterance volume")
        }

        session.speak("I found three files.")
        if session.duckingEnabled,
           abs(synth.utteranceVolume - Self.duckedVolume) > 0.01 {
            failures.append(
                "speaking should duck utterance volume to \(Self.duckedVolume), got \(synth.utteranceVolume)"
            )
        }

        session.end()
        if session.isActive || session.isSpeaking || session.phase != .idle {
            failures.append("end did not clear duplex state")
        }
        return failures
    }

    /// Dictation must never open the duplex session or speak through it.
    private static func dictationStaysSilentFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        if session.isActive {
            failures.append("duplex session left active after prior test")
        }
        // Policy: long listings stay silent — synthesizer must not enqueue them.
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }

        let listing = """
            - /Users/me/a.step
            - /Users/me/b.step
            - /Users/me/c.step
            - /Users/me/d.txt
            """
        session.begin()
        session.speak(listing)
        if session.isSpeaking || !recorder.spoken.isEmpty {
            failures.append("long listing must stay silent on duplex speak")
        }
        session.end()
        return failures
    }
}
