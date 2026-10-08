import Foundation
struct ProcessSnapshot { var physicalFootprintBytes: UInt64?; var residentMemoryBytes: UInt64? }
@main struct CodecProbe {
 static func main() throws {
  let start=Date(timeIntervalSinceReferenceDate:812345678.375)
  var summary=MeetingPerformanceSummary(recordingStartedAt:start)
  summary.observe(at:start.addingTimeInterval(1.125),process:ProcessSnapshot(physicalFootprintBytes:1200000000,residentMemoryBytes:700000000),queuedBytes:7,activeBytes:448000,paused:false)
  let e=JSONEncoder();e.dateEncodingStrategy = .iso8601
  let d=JSONDecoder();d.dateDecodingStrategy = .iso8601
  let read=try d.decode(MeetingPerformanceSummary.self,from:e.encode(summary))
  let stale=MeetingPerformanceSummary(recordingStartedAt:start)
  let checks=[("exact durable clock",read==summary),("fresh reader keeps accepted sample",stale.preserving(read).samples==1),("fresh reader keeps middle peak",stale.preserving(read).peakSampledFootprintBytes==1200000000)]
  for (name,ok) in checks { print("CODEC_\(ok ? "OK" : "FAILED"): \(name)") }
  if checks.contains(where:{!$0.1}) {exit(1)}
 }
}
