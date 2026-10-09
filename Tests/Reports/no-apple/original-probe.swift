import Foundation

/// Availability of the selected voice, independent of an answer's playback receipts.
enum AgentVoiceAvailability: Equatable, Sendable {
    case ready
    case preparing(progress: Double?)
    case needsDownload
    case failed

    var message: String? {
        switch self {
        case .ready: nil
        case .preparing: "Your voice is getting ready. You can read the answer here."
        case .needsDownload: "Download a voice to hear replies."
        case .failed: "Voice couldn't start. Your answer is here."
        }
    }

    static func resolve(ready: Bool, preparing: Bool, progress: Double? = nil,
                        failed: Bool) -> Self {
        if failed { return .failed }
        if ready { return .ready }
        if preparing { return .preparing(progress: progress.map { max(0, min(1, $0)) }) }
        return .needsDownload
    }

    static func runSelfTest() -> [String] {
        let cases: [(Self, Self)] = [
            (resolve(ready: true, preparing: false, failed: false), .ready),
            (resolve(ready: false, preparing: true, failed: false), .preparing(progress: nil)),
            (resolve(ready: false, preparing: true, progress: 1.5, failed: false), .preparing(progress: 1)),
            (resolve(ready: false, preparing: false, failed: false), .needsDownload),
            (resolve(ready: true, preparing: false, failed: true), .failed)
        ]
        return cases.enumerated().compactMap { index, item in
            item.0 == item.1 ? nil : "voice availability: case \(index) failed"
        }
    }
}

import Foundation
@MainActor protocol AgentSpeechBacking: AnyObject {
 var isSpeaking: Bool { get }; func speak(_ text: String, volume: Float, token: UInt64)
 func stop(); func setOutputGain(_ gain: Float)
}
@MainActor protocol AgentReplySpeechBacking: AgentSpeechBacking {
 func beginReply(volume: Float); func enqueue(_ text: String, token: UInt64); func finishReply()
}
@MainActor final class CountedBacking: AgentSpeechBacking {
 let name: String; var spoken: [String] = []; var isSpeaking = false
 init(_ name: String) { self.name=name }
 func speak(_ text: String, volume: Float, token: UInt64) { spoken.append(text); isSpeaking=true }
 func stop() { isSpeaking=false }; func setOutputGain(_ gain: Float) {}
}
enum SelfTest { static let isRunning=true; static func diagnostic(_ line:String) {} }
enum AgentSpeechPolicy { static func spokenClauses(_ reply:String)->[String] { reply.split(separator:".").map { $0.trimmingCharacters(in:.whitespaces)+"." } } }
struct StubLog { func info(_ text:String){} }
enum Log { static let agent=StubLog() }
enum MainActorSection { static func run(_ name:String, _ body:()->Void) { body() } }
@MainActor final class RealtimeAudioSession { static let shared=RealtimeAudioSession(); func noteOutputFinished() {} }
enum KokoroAgentVoice { static let isSupportedOS=true }
@MainActor final class Probe {
 enum PlaybackEvent: Equatable { case began(UInt64),enqueued(String),interrupted(String,wasRendered:Bool) }
 static var selectedEngine="pocket"
 let systemBacking=CountedBacking("apple"), unavailableBacking=CountedBacking("unavailable")
 let pocketBacking=CountedBacking("pocket"), kokoroBacking=CountedBacking("kokoro")
 var backing:any AgentSpeechBacking
 var persistentPlaybackBacking:(any AgentSpeechBacking)?; var persistentPlaybackUsesPocketSource=false
 var usingSystemFallbackForReply=false, deferredFallbackClause=false
 var fallbackBackingForTesting:(any AgentSpeechBacking)?
 var testingBacking=false, pocketIsReady=false, kokoroIsReady=false
 var replyCanSpeak=false,selectedVoiceFailed=false,outputAvailability:AgentVoiceAvailability?
 var availability:AgentVoiceAvailability { .resolve(ready:Self.selectedEngine == "pocket" ? pocketIsReady : Self.selectedEngine == "kokoro" && kokoroIsReady,preparing:false,failed:selectedVoiceFailed || !["pocket","kokoro"].contains(Self.selectedEngine)) }
 var replyOpen=false, replyFinished=false,replyTokens:[UInt64]=[],pendingClauses:[String]=[]
 var voiceResumePending=false,voiceResumeBinding:Int?,isPausedForListening=false,didStop=false
 var currentPlaybackToken:UInt64=0,playbackTokenCounter:UInt64=0,outputGeneration:UInt64=0
 var currentClause:String?,currentClauseRendered=false,utteranceVolume:Float=1,listeningOutputGain:Float=1
 var onPlaybackEvent:((PlaybackEvent)->Void)?,onFirstAudio:(()->Void)?,onFirstAudioCancelled:(()->Void)?,onVoiceLifecycleSettled:(()->Void)?
 init() { backing=systemBacking }
 func setOutputGain(_ gain:Float) { listeningOutputGain=gain;backing.setOutputGain(gain) }
     func speak(_ reply: String) {
        let clauses = AgentSpeechPolicy.spokenClauses(reply)
        guard !clauses.isEmpty else { return }
        prepareForStream()
        if backing is any AgentReplySpeechBacking {
            for clause in clauses { enqueueClause(clause) }
            finishStream()
            return
        }
        pendingClauses = Array(clauses.dropFirst())
        currentClause = clauses[0]
        currentClauseRendered = false
        onPlaybackEvent?(.enqueued(clauses[0]))
        for clause in pendingClauses { onPlaybackEvent?(.enqueued(clause)) }
        startClause(clauses[0])
    }
    func prepareForStream() {
        setOutputGain(1)
        voiceResumePending = false
        voiceResumeBinding = nil
        usingSystemFallbackForReply = false
        deferredFallbackClause = false
        isPausedForListening = false
        let closingReply = replyOpen
        interruptCurrentClause()
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        currentPlaybackToken = 0
        outputGeneration &+= 1
        onPlaybackEvent?(.began(outputGeneration))
        didStop = false
        pendingClauses.removeAll()
        if backing.isSpeaking || closingReply {
            backing.stop()
        }
        if !testingBacking {
            if let persistentPlaybackBacking {
                backing = persistentPlaybackBacking
                Log.agent.info(
                    "voice playback route selected=persistent \(self.persistentPlaybackUsesPocketSource ? "pocket-source" : "fixed-wav")"
                )
            } else {
                switch Self.selectedEngine {
                case "pocket" where pocketIsReady:
                    backing = pocketBacking
                case "kokoro" where KokoroAgentVoice.isSupportedOS:
                    backing = kokoroBacking
                default:
                    backing = systemBacking
                }
                Log.agent.info(
                    "voice playback route selected=settings \(String(describing: type(of: self.backing)))"
                )
            }
        }
        backing.setOutputGain(listeningOutputGain)
    }
    func enqueueClause(_ clause: String) {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !didStop else { return }
        if let reply = backing as? any AgentReplySpeechBacking {
            let beginning = !replyOpen
            if beginning { replyOpen = true; replyFinished = false }
            playbackTokenCounter &+= 1
            let token = playbackTokenCounter
            replyTokens.append(token)
            if currentClause == nil && pendingClauses.isEmpty {
                currentClause = trimmed
                currentClauseRendered = false
                currentPlaybackToken = token
            } else { pendingClauses.append(trimmed) }
            onPlaybackEvent?(.enqueued(trimmed))
            if beginning { reply.beginReply(volume: utteranceVolume) }
            backing.setOutputGain(listeningOutputGain)
            reply.enqueue(trimmed, token: token)
            return
        }
        if backing.isSpeaking || !pendingClauses.isEmpty || isPausedForListening {
            pendingClauses.append(trimmed)
            onPlaybackEvent?(.enqueued(trimmed))
        } else {
            currentClause = trimmed
            currentClauseRendered = false
            onPlaybackEvent?(.enqueued(trimmed))
            startClause(trimmed)
        }
    }
    func finishStream() {
        guard !didStop, replyOpen, !replyFinished,
              let reply = backing as? any AgentReplySpeechBacking else { return }
        replyFinished = true
        reply.finishReply()
        if currentClause == nil && pendingClauses.isEmpty { advanceQueue() }
    }
    func stop() {
        setOutputGain(1)
        voiceResumePending = false
        voiceResumeBinding = nil
        isPausedForListening = false
        deferredFallbackClause = false
        interruptCurrentClause()
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        outputGeneration &+= 1
        currentPlaybackToken = 0
        let hadPendingAudio = onFirstAudio != nil
        didStop = true
        pendingClauses.removeAll()
        onFirstAudio = nil
        if hadPendingAudio { onFirstAudioCancelled?() }
        backing.stop()
        onVoiceLifecycleSettled?()
    }
    func fallbackCurrentClause(text: String, token: UInt64) {
        guard token == currentPlaybackToken, !usingSystemFallbackForReply,
              let currentClause, !currentClause.isEmpty,
              currentClause == text || (replyOpen && text.isEmpty) else { return }
        usingSystemFallbackForReply = true
        let partialReply = replyOpen && currentClauseRendered
        replyTokens.removeAll()
        replyOpen = false
        replyFinished = false
        backing = fallbackBackingForTesting ?? systemBacking
        backing.setOutputGain(listeningOutputGain)
        if partialReply {
            // Completed clauses are gone. A partially rendered head is interrupted,
            // never repeated; only untouched pending clauses use the old fallback.
            onPlaybackEvent?(.interrupted(currentClause, wasRendered: true))
            self.currentClause = nil
            currentClauseRendered = false
            if !isPausedForListening { advanceQueue() }
            return
        }
        currentClauseRendered = false
        if isPausedForListening {
            deferredFallbackClause = true
            return
        }
        startClause(currentClause)
    }
    func interruptCurrentClause() {
        if let currentClause {
            onPlaybackEvent?(.interrupted(currentClause, wasRendered: currentClauseRendered))
        }
        currentClause = nil
        currentClauseRendered = false
        for clause in pendingClauses {
            onPlaybackEvent?(.interrupted(clause, wasRendered: false))
        }
    }
    func advanceQueue() {
        guard !didStop else { return }
        guard !isPausedForListening || replyOpen else { return }
        guard !pendingClauses.isEmpty else {
            guard !isPausedForListening else { return }
            if replyOpen {
                guard replyFinished else { return }
                replyOpen = false
                replyTokens.removeAll()
            }
            RealtimeAudioSession.shared.noteOutputFinished()
            return
        }
        let next = pendingClauses.removeFirst()
        currentClause = next
        currentClauseRendered = false
        if replyOpen, let token = replyTokens.first {
            currentPlaybackToken = token // Already submitted: never restart synthesis.
            return
        }
        startClause(next)
    }
    func startClause(_ clause: String) {
        playbackTokenCounter &+= 1
        currentPlaybackToken = playbackTokenCounter
        let detail = String(format: "Voice clause start %.3f token=%llu backing=%@ characters=%d",
                            Date().timeIntervalSince1970, currentPlaybackToken,
                            String(describing: type(of: self.backing)), clause.count)
        Log.agent.info("\(detail)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
        MainActorSection.run("tts.clause") {
            backing.speak(clause, volume: utteranceVolume, token: currentPlaybackToken)
            backing.setOutputGain(listeningOutputGain)
        }
    }
 func failCurrent() { if let currentClause { fallbackCurrentClause(text:currentClause,token:currentPlaybackToken) } }
}
@main struct Run {
 @MainActor static func main() {
  var failed=0
  func check(_ okay:Bool,_ label:String) { if !okay { failed+=1;print("FAIL: "+label) } }
  let s=Probe();var events:[Probe.PlaybackEvent]=[];s.onPlaybackEvent={ events.append($0) }
  s.speak("Written answer. Second sentence.")
  check(!s.backing.isSpeaking && s.systemBacking.spoken.isEmpty && s.pocketBacking.spoken.isEmpty,"unready selected Pocket does not invoke any voice")
  check(s.currentPlaybackToken==0 && s.pendingClauses.isEmpty,"unready answer retains no playback token/queue")
  check(events.contains(.interrupted("Written answer.",wasRendered:false)),"unready answer has truthful unheard receipt")
  s.pocketIsReady=true;s.prepareForStream()
  check(s.backing === s.pocketBacking,"next ready reply selects chosen Pocket")
  s.stop();Probe.selectedEngine="kokoro";s.kokoroIsReady=false;s.speak("Kokoro not ready.")
  check(!s.backing.isSpeaking && s.kokoroBacking.spoken.isEmpty,"unready Kokoro never starts loading on reply path")
  s.stop();Probe.selectedEngine="pocket";s.pocketIsReady=true;s.selectedVoiceFailed=true
  let spokenBefore=s.pocketBacking.spoken.count;s.speak("Failed voice remains written.")
  check(s.backing === s.unavailableBacking && s.pocketBacking.spoken.count==spokenBefore && s.outputAvailability == .failed,"failed selected voice stays written on a new reply")
  s.stop();s.selectedVoiceFailed=false;let voice=CountedBacking("allowed-test-voice");s.testingBacking=true;s.backing=voice;events=[]
  s.speak("First sentence. Untouched sentence.");s.currentClauseRendered=true;s.isPausedForListening=true;s.failCurrent()
  check(s.didStop && !s.backing.isSpeaking && s.pendingClauses.isEmpty,"allowed voice failure cancels remaining speech")
  check(s.outputAvailability == .failed,"allowed voice failure exposes text-only state")
  check(events.contains(.interrupted("First sentence.",wasRendered:true)) && events.contains(.interrupted("Untouched sentence.",wasRendered:false)),"partial and untouched receipts are truthful")
  check(s.systemBacking.spoken.isEmpty,"no error fallback reaches Apple backing")
  print(failed==0 ? "VOICE_PRODUCER_PROBE_OK" : "VOICE_PRODUCER_PROBE_FAILED: \(failed) assertions")
  exit(failed==0 ? 0:1)
 }
}
