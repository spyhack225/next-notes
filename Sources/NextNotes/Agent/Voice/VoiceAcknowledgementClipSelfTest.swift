import Foundation

@MainActor
enum VoiceAcknowledgementClipSelfTest {
    static func run() async -> [String] {
        let cache = VoiceAcknowledgementClips.shared
        let ack = VoiceAcknowledgement.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotes-ack-cache-\(UUID().uuidString)")
        var wrong: [String] = []
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1; if !value { wrong.append(name) }
        }
        check(!cache.useHarnessDirectory(URL(fileURLWithPath: FileManager.default.temporaryDirectory.path + "-escape")), "cache refuses temp prefix escape")
        check(cache.useHarnessDirectory(root), "cache admits exact isolated temp root")
        defer {
            ack.environmentForTesting = nil
            cache.clearRenderFixture(); _ = cache.useHarnessDirectory(nil)
            try? FileManager.default.removeItem(at: root)
        }
        ack.environmentForTesting = { .init() }
        var rendered: [(String, String)] = []
        let render: @MainActor (String, VoiceAcknowledgementClips.Selection) async throws -> LongFormRenderer.Audio = { text, choice in
            rendered.append((text, choice.voice))
            return .init(samples: [0, 0, 0] + Array(repeating: 0.25, count: 2_400) + [0, 0], sampleRate: 24_000)
        }
        let first = VoiceAcknowledgementClips.Selection(engine: "pocket", voice: "fixture-A")
        check(cache.setRenderFixture(selection: first, ready: true, render: render), "cache fixture admitted")
        check(await cache.prepareForLatency(), "cache ready after idle render")
        check(rendered.count == 2 && rendered.allSatisfy { $0.1 == "fixture-A" }, "two selected-voice clips rendered")
        check(cache.readyCount == 2, "cache keeps both clips in memory")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        check(files.count == 2 && files.allSatisfy { $0.pathExtension == "wav" }, "cache writes only two prepared WAV files")
        if let one = cache.next(), let two = cache.next(), let three = cache.next() {
            check(one.text != two.text && two.text != three.text, "cached clips rotate without immediate repeat")
            check(one.buffers.first?.frameLength == 240 && one.buffers.reduce(0) { $0 + Int($1.frameLength) } == 2_400, "idle trim/split preserves exact nonzero PCM")
            check(one.buffers.first?.floatChannelData?[0][0] == 0.25, "first receipt buffer begins with nonzero sample")
        } else { wrong.append("cache next lost ready clips") }
        cache.invalidate()
        check(await cache.prepareForLatency(), "fresh memory restores disk clips")
        check(rendered.count == 2, "restoration does not synthesize again")
        let second = VoiceAcknowledgementClips.Selection(engine: "pocket", voice: "fixture-B")
        _ = cache.setRenderFixture(selection: second, ready: true, render: render)
        check(cache.readyCount == 0 && cache.next() == nil, "voice change immediately refuses stale clips")
        check(await cache.prepareForLatency(), "voice change prepares new clips")
        check(rendered.count == 4 && rendered.suffix(2).allSatisfy { $0.1 == "fixture-B" }, "voice change rerenders selected conditioning")
        _ = cache.setRenderFixture(selection: second, ready: false, render: render)
        check(cache.readyCount == 0 && cache.next() == nil, "unready model never plays cached clips")
        cache.invalidate()
        _ = cache.setRenderFixture(selection: .init(engine: "apple", voice: "fixture-apple"), ready: true, render: render)
        check(!(await cache.prepareForLatency()) && rendered.count == 4, "Apple selection never renders or falls back")
        let silent = VoiceAcknowledgementClips.Selection(engine: "pocket", voice: "fixture-silence")
        _ = cache.setRenderFixture(selection: silent, ready: true, render: { _, _ in .init(samples: [0, 0], sampleRate: 24_000) })
        check(!(await cache.prepareForLatency()) && cache.readyCount == 0, "silent PCM is not a ready acknowledgement")
        cache.invalidate()
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-nan"), ready: true, render: { _, _ in .init(samples: [0.25, .nan], sampleRate: 24_000) })
        check(!(await cache.prepareForLatency()), "nonfinite PCM is refused")
        cache.invalidate()
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-long"), ready: true, render: { _, _ in .init(samples: Array(repeating: 0.25, count: 48_001), sampleRate: 24_000) })
        check(!(await cache.prepareForLatency()), "oversized clip stays bounded")
        let timeline = VoiceLatencyTimeline.shared
        timeline.resetForTesting(); timeline.beginSession(UUID())
        timeline.mark(.voiceOnset, at: 1_000_000_000)
        timeline.mark(.endpoint, at: 2_000_000_000)
        timeline.mark(.acknowledgementAudible, at: 2_100_000_000)
        check(timeline.closedTurnsForTesting().isEmpty, "ack receipt cannot close answer turn")
        timeline.mark(.firstAudible, at: 2_600_000_000)
        if let turn = timeline.closedTurnsForTesting().last {
            check(VoiceLatencySelfTest.listenSeconds("ACK", turn: turn) == 0.1, "ACK uses committed endpoint clock")
            check(VoiceLatencySelfTest.listenSeconds("L3", turn: turn) == 0.6, "ACK cannot replace first answer audio")
        } else { wrong.append("answer timing turn was lost") }
        timeline.endSession(); timeline.resetForTesting()
        // Native cancellation may return after the idle observation. The SAME
        // cache slot joins the predecessor before admitting its next idle render.
        cache.invalidate()
        let idleHeld = HeldRender()
        var idleRenders = 0
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-idle-cancel"), ready: true,
            render: { _, _ in
                idleRenders += 1
                if idleRenders == 1 { return await idleHeld.render() }
                return .init(samples: Array(repeating: 0.125, count: 960), sampleRate: 24_000)
            })
        let idlePreparing = Task { await cache.prepareForLatency() }
        let idleEnteredDeadline = Date().addingTimeInterval(1)
        while !idleHeld.entered, Date() < idleEnteredDeadline { await Task.yield() }
        check(idleHeld.entered, "idle cancellation reaches actual render producer")
        cache.stopPrewarm(); idleHeld.release()
        _ = await idlePreparing.value
        let idleReadyDeadline = Date().addingTimeInterval(1)
        while cache.readyCount != 2, Date() < idleReadyDeadline { await Task.yield() }
        check(cache.readyCount == 2 && idleRenders == 3, "joined cancellation re-arms exactly two idle clips")
        check(cache.next()?.buffers.first?.floatChannelData?[0][0] == 0.125,
              "cancelled predecessor cannot publish its PCM")
        // The audio owner is not Observable. Its actual native-completion seam
        // must retry an idle prewarm that was refused while speech owned output.
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        await capture.beginSession(captureAudio: false)
        speech.useTestingBacking(recorder)
        cache.invalidate()
        var completedOutputRenders = 0
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-output-idle"), ready: true,
            render: { _, _ in
                completedOutputRenders += 1
                return .init(samples: Array(repeating: 0.125, count: 960), sampleRate: 24_000)
            })
        ack.environmentForTesting = nil
        _ = OutputScheduler.shared.speakSessionless("A finished answer.")
        check(RealtimeAudioSession.shared.isSpeaking, "actual fixed answer owns output before completion")
        ack.prewarm()
        await Task.yield()
        check(completedOutputRenders == 0 && cache.readyCount == 0,
              "speaking output refuses optional clip render")
        recorder.finishNaturallyForTesting()
        speech.notifyTestingAudioFinished(token: speech.currentPlaybackToken)
        let outputIdleDeadline = Date().addingTimeInterval(1)
        while cache.readyCount != 2, Date() < outputIdleDeadline { await Task.yield() }
        check(!RealtimeAudioSession.shared.isSpeaking, "actual completion releases speaking output")
        check(cache.readyCount == 2 && completedOutputRenders == 2,
              "natural output completion restarts actual idle clip producer")
        await capture.endSession(source: .done)
        speech.restoreSystemBacking()
        ack.environmentForTesting = { .init() }
        // Actual capture quit join retains the same optional prewarm producer.
        cache.invalidate()
        let held = HeldRender()
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-held"), ready: true,
            render: { _, _ in await held.render() })
        let preparing = Task { await cache.prepareForLatency() }
        let deadline = Date().addingTimeInterval(1)
        while !held.entered, Date() < deadline { await Task.yield() }
        check(held.entered, "held prewarm entered actual cache producer")
        let quitting = AgentCaptureController.shared.beginEOUTermination()
        var returned = false
        let join = Task { await quitting?.value; returned = true }
        await Task.yield(); await Task.yield()
        check(!returned, "capture quit waits for same held prewarm")
        held.release()
        _ = await preparing.value; await join.value
        check(returned && cache.readyCount == 0, "cancelled prewarm joins without publishing stale clips")
        check(!(await cache.prepareForLatency()), "termination refuses new prewarm admission")
        SelfTest.diagnostic("VOICE_ACK_CACHE_CHECKS=\(checks) failures=\(wrong.count)")
        return wrong
    }
    @MainActor private final class HeldRender {
        var entered = false
        var continuation: CheckedContinuation<LongFormRenderer.Audio, Never>?
        func render() async -> LongFormRenderer.Audio {
            entered = true
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            continuation?.resume(returning: .init(samples: [0.25, 0.25], sampleRate: 24_000))
            continuation = nil
        }
    }
}
