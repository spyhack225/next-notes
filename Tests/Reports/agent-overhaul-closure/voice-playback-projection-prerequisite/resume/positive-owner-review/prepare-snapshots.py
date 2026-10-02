from pathlib import Path
import hashlib, json, difflib
repo=Path.cwd()
out=repo/'Tests/Reports/agent-overhaul-closure/voice-playback-projection-prerequisite/resume/positive-owner-review'
paths=['Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift','Sources/NextNotes/Agent/RealtimeAudioSession.swift','Sources/NextNotes/Agent/Duplex/VoiceContracts.swift','Sources/NextNotes/Agent/VoicePlaybackDelivery.swift']
def replace(s,old,new,count=1):
    assert s.count(old)==count, (old[:90],s.count(old),count)
    return s.replace(old,new)
base={p:(repo/p).read_text() for p in paths}
s=base[paths[0]]
fragment=(out/'APPLE-PRODUCER-CANDIDATE.swift.txt').read_text()
receipt=fragment[fragment.index('struct AppleResumePlaybackReceipt'):fragment.index('// In existing AVSpeechBacking')]
# Only the type, excluding owner-field comments.
receipt=receipt[:receipt.index('// In existing AVSpeechBacking')] if '// In existing AVSpeechBacking' in receipt else receipt
receipt=receipt[:receipt.index('// In existing AVSpeechBacking')] if '// In existing AVSpeechBacking' in receipt else receipt
receipt=receipt[:receipt.index('// In existing AVSpeechBacking')] if '// In existing AVSpeechBacking' in receipt else receipt
# All comments below the closing brace belong to the integration recipe.
receipt=receipt[:receipt.index('\n}\n')+3]
raw='''struct RawApplePlayedNotice: Sendable, Equatable {
    let buffer: ApplePlaybackBufferObservation
    let callbackKind: Int
    let nativeEntryHostTime: UInt64
}
'''
s=replace(s,'/// Playback backend. Production',receipt+'\n'+raw+'\n/// Playback backend. Production')
s=replace(s,'        case startAcknowledged(String)','        case startAcknowledged(String)\n        case resumeRequested(token: UInt64, phase: UInt64)\n        case resumeAcknowledged(AppleResumePlaybackReceipt)')
accessors='''    var appleRawCompletionDeferralForTesting:
        (@Sendable (RawApplePlayedNotice, @escaping @Sendable () -> Void) -> Void)? {
        get { systemBacking.rawCompletionDeferralForTesting }
        set { if SelfTest.isRunning { systemBacking.rawCompletionDeferralForTesting = newValue } }
    }
    var appleResumeProofObserverForTesting: (@MainActor (AppleResumePlaybackReceipt) -> Void)? {
        get { systemBacking.resumeProofObserverForTesting }
        set { if SelfTest.isRunning { systemBacking.resumeProofObserverForTesting = newValue } }
    }
'''
s=replace(s,'    private let pocketBacking = PocketSpeechBacking()',accessors+'    private let pocketBacking = PocketSpeechBacking()')
s=replace(s,'    private var voiceResumePending = false','''    private var voiceResumePending = false
    struct ResumeBinding: Sendable, Equatable { let token: UInt64; let phase: UInt64 }
    private(set) var voiceResumeBinding: ResumeBinding?
'''.rstrip())
s=replace(s,'        let resumePending: Bool','        let resumePending: Bool\n        let resumeBinding: ResumeBinding?')
s=replace(s,'              resumePending: voiceResumePending)','              resumePending: voiceResumePending, resumeBinding: voiceResumeBinding)')
s=replace(s,'        systemBacking.onUtteranceFinished =', '''        systemBacking.onResumePlaybackAcknowledged = { [weak self] receipt in
            self?.didResumeAudio(receipt)
        }
        systemBacking.onUtteranceFinished =''')
s=replace(s,'        voiceResumePending = false','        voiceResumePending = false\n        voiceResumeBinding = nil',3)
s=replace(s,'        voiceResumePending = true','        voiceResumePending = true\n        voiceResumeBinding = nil')
s=replace(s,'        backing.resumeAfterListening()\n', '''        backing.resumeAfterListening()
        if (backing as AnyObject) === systemBacking,
           let phase = systemBacking.currentResumePhase {
            voiceResumeBinding = .init(token: currentPlaybackToken, phase: phase)
            onPlaybackEvent?(.resumeRequested(token: currentPlaybackToken, phase: phase))
        }
''')
originalbody='''    private func didResumeAudio(_ receipt: AppleResumePlaybackReceipt) {
        // Original missing-feature scaffold: SAME native gate observes receipts,
        // but the current owner has no qualified resume publication contract.
    }

'''
s=replace(s,'    private func didBeginAudio(token: UInt64)',originalbody+'    private func didBeginAudio(token: UInt64)')
fields='''    private var resumeEarlierCursor: ApplePlaybackCursorObservation?
    private var resumeLaterCursor: ApplePlaybackCursorObservation?
    private var resumeStrongCut: Int64?
    private var resumeCheckpointBuffer: ApplePlaybackBufferObservation?
    private var resumeReceiptDelivered = false
    var onResumePlaybackAcknowledged: ((AppleResumePlaybackReceipt) -> Void)?
    var resumeProofObserverForTesting: (@MainActor (AppleResumePlaybackReceipt) -> Void)?
    var rawCompletionDeferralForTesting:
        (@Sendable (RawApplePlayedNotice, @escaping @Sendable () -> Void) -> Void)?
    private var timelineEnabled: Bool {
        onResumePlaybackAcknowledged != nil || (SelfTest.isRunning && timelineObserverForTesting != nil)
    }
    var currentResumePhase: UInt64? {
        let phase = timelinePhase.value.load(ordering: .acquiring)
        return speaking && !pausedForListening && phase != 0 && phase % 2 == 0
            && timelineResumeHost != nil ? phase : nil
    }
    private func clearResumeProof() {
        resumeEarlierCursor = nil; resumeLaterCursor = nil; resumeStrongCut = nil
        resumeCheckpointBuffer = nil; resumeReceiptDelivered = false
    }
'''
s=replace(s,'    private var timelineCheckpoint: Int64?','    private var timelineCheckpoint: Int64?\n'+fields.rstrip())
# Enable metadata on the exact existing player when its receipt owner is bound.
s=s.replace('if SelfTest.isRunning, timelineObserverForTesting != nil {','if timelineEnabled {')
s=s.replace('if SelfTest.isRunning, timelineObserverForTesting != nil, let token = activeToken {','if timelineEnabled, let token = activeToken {')
s=replace(s,'        activeToken = token\n        if timelineEnabled {','        activeToken = token\n        clearResumeProof()\n        if timelineEnabled {')
s=replace(s,'                        interceptor: nativeCompletionInterceptorForTesting))','''                        interceptor: nativeCompletionInterceptorForTesting,
                        rawDeferral: SelfTest.isRunning ? rawCompletionDeferralForTesting : nil))''')
s=replace(s,'''            @escaping @Sendable () -> Void) -> Void)?
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {''','''            @escaping @Sendable () -> Void) -> Void)?,
        rawDeferral: (@Sendable (RawApplePlayedNotice,
            @escaping @Sendable () -> Void) -> Void)?
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {''')
old='''            let packet = ApplePlaybackNativeObservation(buffer: buffer,
                originPhase: phase.value.load(ordering: .acquiring),
                callbackKind: Int(kind.rawValue), originHostTime: mach_absolute_time(),
                originWasMainThread: Thread.isMainThread)
            let forward: @Sendable () -> Void = { [weak backing] in
                Task { @MainActor in backing?.receiveTimelineCompletion(packet) }
            }
            if let interceptor { interceptor(packet, forward) }
            else { forward() }
'''
new='''            let raw = RawApplePlayedNotice(buffer: buffer,
                callbackKind: Int(kind.rawValue), nativeEntryHostTime: mach_absolute_time())
            let observe: @Sendable () -> Void = { [weak backing] in
                let packet = ApplePlaybackNativeObservation(buffer: buffer,
                    originPhase: phase.value.load(ordering: .acquiring),
                    callbackKind: Int(kind.rawValue), originHostTime: mach_absolute_time(),
                    originWasMainThread: Thread.isMainThread)
                let forward: @Sendable () -> Void = { [weak backing] in
                    Task { @MainActor in backing?.receiveTimelineCompletion(packet) }
                }
                if let interceptor { interceptor(packet, forward) }
                else { forward() }
            }
            if let rawDeferral { rawDeferral(raw, observe) }
            else { observe() }
'''
s=replace(s,old,new)
qualified=fragment[fragment.index('private func qualifiedResumeReceipt'):fragment.index('// Existing receiveTimelineCompletion')].rstrip()
qualified='\n'.join('    '+line if line else '' for line in qualified.splitlines())+'\n\n'
s=replace(s,'    private func receiveTimelineCompletion(',qualified+'    private func receiveTimelineCompletion(')
s=replace(s,'        let cursor = timelineCursor()\n        let before = timelineCheckpoint','''        // Existing initial onset keeps its fast path: player query only for a
        // pending resume or an explicitly installed SelfTest observer.
        let cursor = timelineObserverForTesting != nil || (timelineResumeHost != nil && !resumeReceiptDelivered)
            ? timelineCursor() : nil
        let before = timelineCheckpoint''')
s=replace(s,'        // Never suppress the existing drain bookkeeping', '''        if let receipt = qualifiedResumeReceipt(packet, cursor: cursor) {
            if SelfTest.isRunning { resumeProofObserverForTesting?(receipt) }
            onResumePlaybackAcknowledged?(receipt)
        }
        // Never suppress the existing drain bookkeeping''')
s=replace(s,'        pausedForListening = false\n        if timelineEnabled {','        pausedForListening = false\n        clearResumeProof()\n        if timelineEnabled {',3) # finish/stop/resume
s=replace(s,'        pausedForListening = true\n        if timelineEnabled','        pausedForListening = true\n        clearResumeProof()\n        if timelineEnabled')
s=replace(s,'''            let cursor = timelineCursor()
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor, completedEnd: nil)''','''            let cursor = timelineCursor()
            if let cursor, let host = timelineResumeHost,
               cursor.sampleRate == timelineRate, cursor.frame >= 0, cursor.frame <= timelineEnd,
               cursor.observedHostTime >= host, cursor.nodeHostTime >= host {
                resumeEarlierCursor = cursor
            }
            timelineCheckpoint = diagnosticCheckpoint(cursor: cursor, completedEnd: nil)''')
common={paths[0]:s}
c=base[paths[2]]
c=replace(c,'    case began, firstAudio, clauseCompleted, finished, interrupted(byUser: Bool)','''    case began, firstAudio, clauseCompleted, finished, interrupted(byUser: Bool)
    case resumeRequested(token: UInt64, phase: UInt64)
    case resumed(token: UInt64, phase: UInt64)''')
c=replace(c,'        var id: OutputID; var kind: OutputKind; var status: Status; var heard: Bool','''        var id: OutputID; var kind: OutputKind; var status: Status; var heard: Bool
        var resumeToken: UInt64? = nil
        var resumePhase: UInt64? = nil''')
c=replace(c,'                    output.status = .paused\n                    next.output = output','''                    output.status = .paused
                    output.resumeToken = nil; output.resumePhase = nil
                    next.output = output''')
c=replace(c,'                case .firstAudio:','''                case .resumeRequested(let token, let phase):
                    guard output.status == .awaitingResume || output.status == .paused else { break }
                    output.status = .awaitingResume
                    output.resumeToken = token; output.resumePhase = phase
                    next.output = output
                case .resumed(let token, let phase):
                    guard output.status == .awaitingResume,
                          output.resumeToken == token, output.resumePhase == phase else { break }
                    output.status = .playing; output.heard = true; next.output = output
                    if let request = next.pendingApproval { project(.proposal(request)) }
                    else if next.floor != .free { project(.listening) }
                    else { project(.speaking) }
                case .firstAudio:''')
common[paths[2]]=c
a=base[paths[1]]
a=replace(a,'            heard: voiceShadowHeard || actual.rendered)','''            heard: voiceShadowHeard || actual.rendered,
            resumeToken: actual.resumeBinding?.token, resumePhase: actual.resumeBinding?.phase)''')
a=replace(a,'            case .startAcknowledged:\n                voiceShadowHeard = true','''            case .resumeRequested(let token, let phase):
                let actual = AgentSpeechSynthesizer.shared.voiceLifecycleSnapshot
                guard actual.resumeBinding == .init(token: token, phase: phase) else { break }
                VoiceSession.shared.send(.playback(output.id, .resumeRequested(token: token, phase: phase)))
            case .resumeAcknowledged(let receipt):
                let speech = AgentSpeechSynthesizer.shared
                let actual = speech.voiceLifecycleSnapshot
                guard !actual.paused, !actual.resumePending,
                      receipt.packet.buffer.token == speech.currentPlaybackToken,
                      actual.resumeBinding == .init(token: receipt.packet.buffer.token,
                                                   phase: receipt.packet.originPhase) else { break }
                voiceShadowHeard = true
                VoiceSession.shared.send(.playback(output.id,
                    .resumed(token: receipt.packet.buffer.token, phase: receipt.packet.originPhase)))
            case .startAcknowledged:
                voiceShadowHeard = true''')
a=replace(a,'        case .began, .enqueued, .interrupted(_, wasRendered: false):','        case .began, .enqueued, .interrupted(_, wasRendered: false), .resumeRequested, .resumeAcknowledged:')
common[paths[1]]=a
d=replace(base[paths[3]],'        case .startAcknowledged: break','        case .startAcknowledged, .resumeRequested, .resumeAcknowledged: break')
common[paths[3]]=d
fixedbody=fragment[fragment.index('private func didResumeAudio'):fragment.index('// Suggested currentResumePhase')].rstrip()
fixedbody='\n'.join('    '+line if line else '' for line in fixedbody.splitlines())+'\n\n'
fixed=s.replace(originalbody,fixedbody)
assert fixed!=s
manifest={'status':'off-source-uncompiled-unexecuted-proposal','baseline':{},'common':{},'fixed':{}}
for path, original in base.items():
    name=Path(path).name
    for prefix, text in [('baseline',original),('common-original',common[path]),('proposed-fixed',fixed if path==paths[0] else common[path])]:
        (out/(prefix+'-'+name+'.txt')).write_text(text)
    manifest['baseline'][path]=hashlib.sha256(original.encode()).hexdigest()
    manifest['common'][path]=hashlib.sha256(common[path].encode()).hexdigest()
    manifest['fixed'][path]=hashlib.sha256((fixed if path==paths[0] else common[path]).encode()).hexdigest()
    patch=''.join(difflib.unified_diff(original.splitlines(True),common[path].splitlines(True),fromfile=path,tofile=path))
    (out/('common-'+name+'.patch')).write_text(patch)
(out/'fixed-bridge-only.patch').write_text(''.join(difflib.unified_diff(s.splitlines(True),fixed.splitlines(True),fromfile=paths[0],tofile=paths[0])))
(out/'source-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps(manifest,indent=2))
