from pathlib import Path
import json
r=Path(__file__).resolve().parent
root=r.parents[3]
p=root/'Sources/NextNotes/Agent/Voice/VoiceAcknowledgementClipSelfTest.swift'
s=p.read_text().replace('''        speech.stop(); speech.restoreSystemBacking()
        check(answerEntered''','''        speech.stop(); speech.restoreSystemBacking()
        VoiceConversationCoordinator.shared.resetForTesting()
        RealtimeAudioSession.shared.noteOutputFinished()
        check(answerEntered''')
a=s.index('        // Held courtesy -> real input activity')
s=s[:a]+'''        // A non-cancellation refusal stays silent, then retries at the
        // existing resource-admission idle event; never an immediate retry loop.
        cache.invalidate()
        var recoveredRenders = 0
        _ = cache.setRenderFixture(selection: .init(engine: "pocket", voice: "fixture-idle-recovery"), ready: true,
            render: { _, _ in
                recoveredRenders += 1
                return .init(samples: recoveredRenders == 1 ? [0, 0] : Array(repeating: 0.125, count: 960), sampleRate: 24_000)
            })
        check(!(await cache.prepareForLatency()), "non-cancellation refusal stays silent")
        check(recoveredRenders == 1, "failure does not spin an immediate retry")
        NotificationCenter.default.post(name: ModelResidencyPolicy.admissionChanged, object: nil)
        let recoveryDeadline = Date().addingTimeInterval(1)
        while cache.readyCount != 2, Date() < recoveryDeadline { await Task.yield() }
        check(cache.readyCount == 2, "existing idle admission event rearms non-cancellation failure")
'''+s[a:]
p.write_text(s)
p=root/'Sources/NextNotes/Agent/Voice/VoiceAcknowledgement.swift';s=p.read_text();s=s.replace('''    private var observing = false''','''    private var observing = false
    private var admissionObserver: NSObjectProtocol?''');s=s.replace('''    private func observePrewarmInputs() {
        guard !observing else''','''    private func observePrewarmInputs() {
        if admissionObserver == nil {
            admissionObserver = NotificationCenter.default.addObserver(
                forName: ModelResidencyPolicy.admissionChanged, object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.prewarm() }
            }
        }
        guard !observing else''');p.write_text(s)

p=root/'Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift'
s=p.read_text().replace("""        if acknowledgementEnabled, !(await clipCache.prepareForLatency()) {""","""        let cacheRequestsBefore = speech.speechSynthesisCallsForTesting
        if acknowledgementEnabled, !(await clipCache.prepareForLatency()) {""")
a=s.index("""        SelfTest.diagnostic("VOICE_ACK_CACHE ready=""")
s=s[:a]+"""        if acknowledgementEnabled {
            let renderRequests = speech.speechSynthesisCallsForTesting - cacheRequestsBefore
            SelfTest.diagnostic("VOICE_ACK_CENSUS render_requests=\\(renderRequests) expected=2")
            if renderRequests != 2 { wrong.append("two fresh Pocket courtesy renders must enter permitted request census") }
            clipCache.invalidate()
            let restored = await clipCache.prepareForLatency()
            let restorationRequests = speech.speechSynthesisCallsForTesting - cacheRequestsBefore - renderRequests
            SelfTest.diagnostic("VOICE_ACK_CENSUS restoration_requests=\\(restorationRequests) expected=0")
            if !restored || restorationRequests != 0 { wrong.append("disk restoration must be ready without native synthesis") }
            if CommandLine.arguments.contains("--voice-latency-ack-census") {
                return finish(wrong)
            }
        }
"""+s[a:]
p.write_text(s)
# Identical new native-census consumer in the original RED source.
p=r/'original-producers.json';d=json.loads(p.read_text())
k='Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift'
original=d[k]
a=original.index("""        SelfTest.diagnostic("VOICE_ACK_CACHE ready=""")
consumer=s[s.index("""        if acknowledgementEnabled {
            let renderRequests"""):s.index("""        SelfTest.diagnostic("VOICE_ACK_CACHE ready=""")]
original=original[:a]+consumer+original[a:]
original=original.replace("""        if acknowledgementEnabled, !(await clipCache.prepareForLatency()) {""","""        let cacheRequestsBefore = speech.speechSynthesisCallsForTesting
        if acknowledgementEnabled, !(await clipCache.prepareForLatency()) {""")
d[k]=original;p.write_text(json.dumps(d,indent=2)+'\n')

p=root/'Sources/NextNotes/Agent/Voice/VoiceAcknowledgementClips.swift'
s=p.read_text().replace("""else { throw ClipError.invalidPCM }
                                    samples.append""","""else { throw ClipError.oversized }
                                    samples.append""")
s=s.replace("""        guard audio.sampleRate == 24_000, audio.samples.count <= 48_000,
              audio.samples.allSatisfy(\\.isFinite),
              let first""","""        guard audio.sampleRate == 24_000 else { throw ClipError.format }
        guard audio.samples.count <= 48_000 else { throw ClipError.oversized }
        guard audio.samples.allSatisfy(\\.isFinite) else { throw ClipError.nonfinite }
        guard audio.samples.contains(where: { abs($0) > 0.0001 }) else { throw ClipError.silent }
        guard let first""")
s=s.replace("""(error is ClipError ? "invalid-pcm" : "render-or-io")""","""((error as? ClipError)?.rawValue ?? "render-or-io")""")
s=s.replace("""private enum ClipError: Error { case invalidPCM }""","""private enum ClipError: String, Error { case invalidPCM = "invalid-pcm", oversized, silent, nonfinite, format }""")
p.write_text(s)
# Original deadline predicate now uses the same production consumer helper;
# its median equation is unchanged for the original five counted turns.
p=r/'original-producers.json';d=json.loads(p.read_text());k='Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift'
d[k]=d[k].replace("""values.count == expected && (values.sorted().dropFirst(values.count / 2).first ?? .infinity) < 0.200""","""values.count == expected && median(values).map { $0 < 0.200 } == true""").replace("""let met = ack.count == runs && median(ack).map { $0 < 0.200 } == true""","""let met = acknowledgementDeadlineMet(ack, expected: runs)""")
p.write_text(json.dumps(d,indent=2)+'\n')
