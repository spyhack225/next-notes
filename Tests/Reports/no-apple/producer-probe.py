from pathlib import Path
import subprocess,sys,re
root=Path(__file__).resolve().parents[3]
rev=sys.argv[1]
out=Path(sys.argv[2])
path='Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift'
source=(root/path).read_text() if rev=='working' else subprocess.check_output(['git','show',f'{rev}:{path}'],cwd=root,text=True)
source=source[source.index('final class AgentSpeechSynthesizer'):source.index('// MARK: - Backends')]
def method(name):
    m=re.search(r'^    (?:private )?func '+name+r'\(',source,re.M)
    if not m: raise RuntimeError(name)
    opening=source.index('{',m.start());depth=1;i=opening+1
    while depth:
        depth+=(source[i]=='{')-(source[i]=='}');i+=1
    # Diagnostic logger privacy annotations are the only substitutions in bodies.
    return source[m.start():i].replace(', privacy: .public','')
names=['speak','prepareForStream','enqueueClause','finishStream','stop','fallbackCurrentClause','interruptCurrentClause','advanceQueue','startClause']
methods='\n'.join(method(n) for n in names)
fixed='replyCanSpeak' in source
api=(root/'Sources/NextNotes/Agent/Speech/AgentVoiceAvailability.swift').read_text()
code='''import Foundation
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
 var availability:AgentVoiceAvailability { .resolve(ready:pocketIsReady,preparing:false,failed:selectedVoiceFailed) }
 var replyOpen=false, replyFinished=false,replyTokens:[UInt64]=[],pendingClauses:[String]=[]
 var voiceResumePending=false,voiceResumeBinding:Int?,isPausedForListening=false,didStop=false
 var currentPlaybackToken:UInt64=0,playbackTokenCounter:UInt64=0,outputGeneration:UInt64=0
 var currentClause:String?,currentClauseRendered=false,utteranceVolume:Float=1,listeningOutputGain:Float=1
 var onPlaybackEvent:((PlaybackEvent)->Void)?,onFirstAudio:(()->Void)?,onFirstAudioCancelled:(()->Void)?,onVoiceLifecycleSettled:(()->Void)?
 init() { backing=INITIAL }
 func setOutputGain(_ gain:Float) { listeningOutputGain=gain;backing.setOutputGain(gain) }
 METHODS
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
  s.stop();let voice=CountedBacking("allowed-test-voice");s.testingBacking=true;s.backing=voice;events=[]
  s.speak("First sentence. Untouched sentence.");s.currentClauseRendered=true;s.isPausedForListening=true;s.failCurrent()
  check(s.didStop && !s.backing.isSpeaking && s.pendingClauses.isEmpty,"allowed voice failure cancels remaining speech")
  check(s.outputAvailability == .failed,"allowed voice failure exposes text-only state")
  check(events.contains(.interrupted("First sentence.",wasRendered:true)) && events.contains(.interrupted("Untouched sentence.",wasRendered:false)),"partial and untouched receipts are truthful")
  check(s.systemBacking.spoken.isEmpty,"no error fallback reaches Apple backing")
  print(failed==0 ? "VOICE_PRODUCER_PROBE_OK" : "VOICE_PRODUCER_PROBE_FAILED: \\(failed) assertions")
  exit(failed==0 ? 0:1)
 }
}
'''.replace('INITIAL','unavailableBacking' if fixed else 'systemBacking').replace('METHODS',methods)
# available metadata and type name only; exact copied method bodies remain above.
code=code.replace('private func','func')
out.write_text(api+'\n'+code)
print(f'Generated {rev} exact nine owner methods with counted external backings: {out}')
