import Foundation
import AVFoundation
@main struct PerPassZeroCheck {
 static func chunk(_ pcm: ArraySlice<Float>) -> AudioChunk {
  let f=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false)!
  let b=AVAudioPCMBuffer(pcmFormat:f,frameCapacity:UInt32(pcm.count))!; b.frameLength=UInt32(pcm.count)
  for (i,v) in pcm.enumerated() { b.floatChannelData![0][i]=v }; return AudioChunk(buffer:b)
 }
 static func joined(_ engine: ParakeetEngine) async -> Bool {
  let until=ContinuousClock.now.advanced(by:.seconds(2))
  while ContinuousClock.now < until {
   if await engine.workerIsIdleForProbe() { return true }; await Task.yield()
  }; return await engine.workerIsIdleForProbe()
 }
 static func main() async throws {
  let quiet=try AudioConversion.monoSamples(fromFileAt:URL(fileURLWithPath:CommandLine.arguments[1]),sampleRate:16000)
  precondition(quiet.count==52566)
  let zero=[Float](repeating:0,count:256000)
  let cases:[(String,[Float])]=[("quiet",quiet),("leading-zero",zero+quiet),("trailing-zero",quiet+zero),("all-zero",zero)]
  var errors:[String]=[]; var result:[[String:Any]]=[]
  for (name,pcm) in cases {
   await ASRBoundary.shared.reset(); let engine=ParakeetEngine(); let stream=try await engine.start()
   let consumer=Task { () -> [TranscriptionChunk] in
    var output:[TranscriptionChunk]=[]; do { for try await c in stream { output.append(c) } } catch {}
    return output
   }
   var fed=0
   while fed < pcm.count {
    let end=min(fed+1600,pcm.count); await engine.feed(chunk(pcm[fed..<end]))
    if !(await joined(engine)) { errors.append(name+": worker not joined") }; fed=end
   }
   let worker=await engine.workerHandleForProbe(); await engine.finish(); await worker?.value; let output=await consumer.value
   let calls=await ASRBoundary.shared.snapshot(); let empty=calls.filter{ !$0.contains(where:{$0 != 0}) }.count
   if empty>0 { errors.append(name+": literal-zero inference inputs "+String(empty)) }
   if output.filter({$0.isFinal}).count != 1 { errors.append(name+": missing single final") }
   if name != "all-zero" && !calls.contains(where:{$0.contains(where:{$0 != 0})}) { errors.append(name+": recognizable PCM omitted") }
   if name == "all-zero" && (!calls.isEmpty || !output.last!.text.isEmpty) { errors.append(name+": silence generated words") }
   result.append(["name":name,"samples":pcm.count,"calls":calls.map{["samples":$0.count,"nonzero":$0.filter{$0 != 0}.count]},"zeroInputCalls":empty,"finals":output.filter{$0.isFinal}.count])
  }
  print(String(decoding:try JSONSerialization.data(withJSONObject:["cases":result,"failures":errors,"scope":"Actual copied Engine producer/real public PCM/AV and segmenter; native recognizer, converter, scheduler and registry substituted. No native words proof."],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
  print(errors.isEmpty ? "PER_PASS_ZERO_OK" : "PER_PASS_ZERO_FAILED"); if !errors.isEmpty {exit(1)}
 }
}
