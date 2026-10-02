#!/usr/bin/env python3
"""Prepare an UNAPPLIED native-decoder self-test support patch. Never compile."""
from pathlib import Path
import difflib
import hashlib
import json

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parent / "controlled-input-probe"
OUT.mkdir(exist_ok=True)

HELPER = r'''
/// Harness-only metadata and suspension points. Stores no PCM and produces no
/// decoder words/endpoints. Every observed callback still comes from FluidAudio.
final class VoiceInputProducerProbe: @unchecked Sendable {
    struct Input: Sendable {
        let sequence: Int
        let frames: Range<Int>
        let second: Bool
    }
    struct Event: Sendable {
        let kind: String
        let input: Input?
        let epoch: Int?
        let capturedEnd: Int
    }
    private let lock = NSLock()
    private var nextFrame = 0
    private var inputs: [Int: Input] = [:]
    private var history: [Event] = []
    private var activeInput: Input?
    private var secondInput = false
    private var prepareReleased: Bool
    private var commitReleased: Bool
    private var firstCommitSelected = false
    private var prepareWaiter: CheckedContinuation<Void, Never>?
    private var commitWaiter: CheckedContinuation<Void, Never>?

    init(holdPrepare: Bool, holdFirstCommit: Bool) {
        prepareReleased = !holdPrepare
        commitReleased = !holdFirstCommit
    }
    func beginSecondInput() {
        lock.lock()
        secondInput = true
        lock.unlock()
    }
    func captured(sequence: Int, frames: Int) {
        lock.lock()
        let input = Input(sequence: sequence,
            frames: nextFrame..<(nextFrame + frames), second: secondInput)
        nextFrame += frames
        inputs[sequence] = input
        history.append(Event(kind: "captured", input: input,
            epoch: nil, capturedEnd: nextFrame))
        lock.unlock()
    }
    func input(sequence: Int) -> Input? {
        lock.lock()
        defer { lock.unlock() }
        return inputs[sequence]
    }
    func processBegan(_ input: Input?) {
        lock.lock()
        activeInput = input
        history.append(Event(kind: "process.begin", input: input,
            epoch: nil, capturedEnd: nextFrame))
        lock.unlock()
    }
    func processEnded(success: Bool) {
        lock.lock()
        history.append(Event(kind: success ? "process.end" : "process.failed", input: activeInput,
            epoch: nil, capturedEnd: nextFrame))
        activeInput = nil
        lock.unlock()
    }
    func record(_ kind: String, epoch: Int? = nil) {
        lock.lock()
        history.append(Event(kind: kind, input: activeInput,
            epoch: epoch, capturedEnd: nextFrame))
        lock.unlock()
    }
    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }
    func holdPreparedDecoder() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            history.append(Event(kind: "prepare.checkpoint", input: nil,
                epoch: nil, capturedEnd: nextFrame))
            if prepareReleased {
                lock.unlock()
                continuation.resume()
            } else {
                history.append(Event(kind: "prepare.held", input: nil,
                    epoch: nil, capturedEnd: nextFrame))
                prepareWaiter = continuation
                lock.unlock()
            }
        }
    }
    func holdFirstCommit(epoch: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstCommitSelected {
                lock.unlock()
                continuation.resume()
                return
            }
            firstCommitSelected = true
            history.append(Event(kind: "commit.selected", input: nil,
                epoch: epoch, capturedEnd: nextFrame))
            if commitReleased {
                lock.unlock()
                continuation.resume()
            } else {
                commitWaiter = continuation
                lock.unlock()
            }
        }
    }
    func releasePrepare() {
        lock.lock()
        prepareReleased = true
        let waiter = prepareWaiter
        prepareWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
    func releaseCommit() {
        lock.lock()
        commitReleased = true
        let waiter = commitWaiter
        commitWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
    func releaseAll() {
        releasePrepare()
        releaseCommit()
    }
}

'''


def replace_once(text, old, new):
    assert text.count(old) == 1, (old[:100], text.count(old))
    return text.replace(old, new, 1)


def detector(source):
    source = replace_once(source, "actor LocalVoiceTurnDetector {", HELPER + "actor LocalVoiceTurnDetector {")
    source = replace_once(source, "    private var ready = false\n", """    private var ready = false
    private let producerProbeForTesting: VoiceInputProducerProbe?

    init(producerProbeForTesting: VoiceInputProducerProbe? = nil) {
        // An ordinary app invocation cannot suspend production operations.
        self.producerProbeForTesting = SelfTest.isRunning ? producerProbeForTesting : nil
    }
""")
    source = replace_once(source, "        await manager.reset()\n        await setCallbacks(onEndOfUtterance, onPartial: onPartial)\n        ready = true", """        await manager.reset()
        if let producerProbeForTesting {
            // Keep the real preparation operation held after native load/prime.
            // This is the cold-backlog/reset ordering, without variable load time.
            await producerProbeForTesting.holdPreparedDecoder()
        }
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
        ready = true
        producerProbeForTesting?.record("prepare.ready")""")
    source = replace_once(source, "    func process(_ chunk: AudioChunk) async throws {", """    func process(_ chunk: AudioChunk,
        producerInputForTesting: VoiceInputProducerProbe.Input? = nil) async throws {""")
    source = replace_once(source, "        guard ready else { return }\n        _ = try await manager.process(audioBuffer: chunk.buffer)", """        guard ready else { return }
        producerProbeForTesting?.processBegan(producerInputForTesting)
        var completed = false
        defer { producerProbeForTesting?.processEnded(success: completed) }
        _ = try await manager.process(audioBuffer: chunk.buffer)
        completed = true""")
    source = replace_once(source, "    ) async {\n        guard await acquireOperation() else { return }\n        defer { releaseOperation() }\n        guard ready else { return }\n        await manager.reset()\n        await setCallbacks(onEndOfUtterance, onPartial: onPartial)", """    ) async {
        producerProbeForTesting?.record("reset.requested")
        guard await acquireOperation() else { return }
        defer { releaseOperation() }
        guard ready else { return }
        producerProbeForTesting?.record("reset.granted")
        await manager.reset()
        await setCallbacks(onEndOfUtterance, onPartial: onPartial)
        producerProbeForTesting?.record("reset.completed")""")
    source = replace_once(source, "        await manager.setEouCallback { transcript in", """        let producerProbeForTesting = self.producerProbeForTesting
        await manager.setEouCallback { transcript in
            producerProbeForTesting?.record("native.eou")""")
    source = replace_once(source, "        await manager.setPartialCallback { transcript in\n            onPartial(transcript)", """        await manager.setPartialCallback { transcript in
            producerProbeForTesting?.record("native.partial")
            onPartial(transcript)""")
    return source


def capture(source):
    source = replace_once(source, "    private var turnDetector: LocalVoiceTurnDetector?\n", """    private var turnDetector: LocalVoiceTurnDetector?
    @ObservationIgnored private var inputProducerProbeForTesting: VoiceInputProducerProbe?
""")
    source = replace_once(source, "        let detector = LocalVoiceTurnDetector()\n", """        let producerProbeForTesting = SelfTest.isRunning ? inputProducerProbeForTesting : nil
        let detector = LocalVoiceTurnDetector(producerProbeForTesting: producerProbeForTesting)
""")
    source = replace_once(source, "                    try await detector.process(chunk)\n", """                    if let producerProbeForTesting {
                        try await detector.process(chunk,
                            producerInputForTesting: producerProbeForTesting.input(sequence: sequence))
                    } else {
                        try await detector.process(chunk)
                    }
""")
    source = replace_once(source, "            let dropped = turnAudioBacklog.enqueue((cleaned, Date(), turnAudioSequence.next()))", """            let sequence = turnAudioSequence.next()
            if let producerProbeForTesting {
                let format = cleaned.buffer.format
                if format.commonFormat != .pcmFormatFloat32 || format.sampleRate != 16_000
                    || format.channelCount != 1 || format.isInterleaved {
                    producerProbeForTesting.record("capture.format.invalid")
                }
            }
            producerProbeForTesting?.captured(sequence: sequence,
                frames: Int(cleaned.buffer.frameLength))
            let dropped = turnAudioBacklog.enqueue((cleaned, Date(), sequence))""")
    source = replace_once(source, "    ) async {\n        let shadowTurn = shadowTurnIfNeeded()\n", """    ) async {
        if let inputProducerProbeForTesting {
            // Harness-only: text/endpoint eligibility was selected by the real
            // tick; permit the next file's input to arrive before this commit.
            await inputProducerProbeForTesting.holdFirstCommit(epoch: turnEpoch)
        }
        inputProducerProbeForTesting?.record("commit.emitted", epoch: turnEpoch)
        let shadowTurn = shadowTurnIfNeeded()
""")
    source = replace_once(source, "    private func makeEOUCallback(captureID: UUID, epoch: Int) -> @Sendable (String) -> Void {\n        { modelText in", """    private func makeEOUCallback(captureID: UUID, epoch: Int) -> @Sendable (String) -> Void {
        let producerProbeForTesting = inputProducerProbeForTesting
        return { modelText in
            producerProbeForTesting?.record("callback.eou", epoch: epoch)""")
    source = replace_once(source, "            VoiceLatencyTimeline.shared.mark(.eouCallback)\n            Task { @MainActor in\n                let capture = AgentCaptureController.shared", """            VoiceLatencyTimeline.shared.mark(.eouCallback)
            Task { @MainActor in
                defer { producerProbeForTesting?.record("callback.eou.handled", epoch: epoch) }
                let capture = AgentCaptureController.shared""")
    source = replace_once(source, "    private func resetTurn() {\n", """    private func resetTurn() {
        inputProducerProbeForTesting?.record("capture.reset", epoch: turnEpoch)
""")
    source = replace_once(source, "    /// Two paced requests share one decoder and one microphone-session epoch.\n", r'''    /// Support for the controlled producer regression. This emits no pass marker.
    /// The flag's conductor must apply the recipe in the retained report and
    /// require actual native callbacks, frame coverage and expected commit counts.
    func beginInputProducerFixtureForTesting(wav: URL,
        holdPrepare: Bool, holdFirstCommit: Bool,
        committed: @escaping @MainActor (String) async -> Void) async throws
        -> VoiceInputProducerProbe {
        guard SelfTest.isRunning else { throw TranscriptionError.notRunning }
        await endSession(source: .done)
        let probe = VoiceInputProducerProbe(holdPrepare: holdPrepare,
            holdFirstCommit: holdFirstCommit)
        inputProducerProbeForTesting = probe
        turnHandlerForTesting = committed
        do {
            try await beginFileSession(wav: wav, deferFeed: true,
                prepareResources: false)
            return probe
        } catch {
            probe.releaseAll()
            inputProducerProbeForTesting = nil
            turnHandlerForTesting = nil
            await endSession(source: .done)
            throw error
        }
    }

    func startInputProducerFixtureFeedForTesting() {
        guard SelfTest.isRunning, inputProducerProbeForTesting != nil else { return }
        startDeferredFileFeed()
    }

    func feedInputProducerFixtureSecondForTesting(wav: URL) async throws {
        guard SelfTest.isRunning, let probe = inputProducerProbeForTesting,
            let format = fileCaptureFormat, let deliver = fileDeliveryForTesting else {
            throw TranscriptionError.notRunning
        }
        fileFeedTask?.cancel()
        await fileFeedTask?.value
        probe.beginSecondInput()
        try await feedFile(wav, outputFormat: format,
            deliver: deliver, markSecondInput: true)
    }

    func endInputProducerFixtureForTesting() async {
        guard SelfTest.isRunning else { return }
        // Release continuations before endSession waits for the real decoder.
        inputProducerProbeForTesting?.releaseAll()
        await endSession(source: .done)
        inputProducerProbeForTesting = nil
        turnHandlerForTesting = nil
    }

    /// Two paced requests share one decoder and one microphone-session epoch.
''')
    return source


paths = {
    "Sources/NextNotes/Activation/LocalVoiceTurnDetector.swift": detector,
    "Sources/NextNotes/Activation/AgentCaptureController.swift": capture,
}
patch = []
manifest = {"state": "UNAPPLIED; no compiler or model run; support only, not a verdict", "sources": []}
for relative, transform in paths.items():
    original = (ROOT / relative).read_text()
    proposed = transform(original)
    (OUT / (Path(relative).name + ".original.txt")).write_text(original)
    (OUT / (Path(relative).name + ".proposed.txt")).write_text(proposed)
    patch.extend(difflib.unified_diff(original.splitlines(keepends=True),
        proposed.splitlines(keepends=True), fromfile="a/" + relative, tofile="b/" + relative))
    manifest["sources"].append({"path": relative,
        "originalSha256": hashlib.sha256(original.encode()).hexdigest(),
        "proposedSha256": hashlib.sha256(proposed.encode()).hexdigest()})
(OUT / "proposed-support.patch").write_text("".join(patch))
conductor = OUT / "NativeInputProducerConductor.swift.txt"
if conductor.exists():
    relative = "Sources/NextNotes/Activation/AgentCaptureController.swift"
    proposed = (OUT / "AgentCaptureController.swift.proposed.txt").read_text()
    combined = proposed + "\n" + conductor.read_text()
    (OUT / "AgentCaptureController.swift.with-conductor.txt").write_text(combined)
    (OUT / "proposed-conductor.patch").write_text("".join(difflib.unified_diff(
        proposed.splitlines(keepends=True), combined.splitlines(keepends=True),
        fromfile="a/" + relative, tofile="b/" + relative)))
    original = (ROOT / relative).read_text()
    detector_original = (OUT / "LocalVoiceTurnDetector.swift.original.txt").read_text()
    detector_proposed = (OUT / "LocalVoiceTurnDetector.swift.proposed.txt").read_text()
    combined_patch = list(difflib.unified_diff(detector_original.splitlines(keepends=True),
        detector_proposed.splitlines(keepends=True),
        fromfile="a/Sources/NextNotes/Activation/LocalVoiceTurnDetector.swift",
        tofile="b/Sources/NextNotes/Activation/LocalVoiceTurnDetector.swift"))
    combined_patch += list(difflib.unified_diff(original.splitlines(keepends=True),
        combined.splitlines(keepends=True), fromfile="a/" + relative, tofile="b/" + relative))
    (OUT / "proposed-combined.patch").write_text("".join(combined_patch))
    manifest["conductor"] = {"state": "UNAPPLIED AND UNCOMPILED; actual native verdict pending",
        "defaultSelection": "cold original single-WAV regression first",
        "sha256": hashlib.sha256(conductor.read_bytes()).hexdigest(),
        "combinedCaptureSha256": hashlib.sha256(combined.encode()).hexdigest()}
(OUT / "source-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("PREPARED_UNAPPLIED_NATIVE_PRODUCER_SUPPORT")
