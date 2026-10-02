#!/usr/bin/env python3
"""Copied actual P4-12 producers. No model, notifications or owner store.
Original uses commit 8888474. New Apple enum/signature compile adapters only permit
asserting the old router rejects Apple; they add no route/delivery behavior.
The delivery class is a recording shell around the exact production method,
actual makeDelivery, and actual quiet-hour predicates. Installed scheduler tests
are still required to prove the real runOnce/testRun callers and disk stores.
"""
import argparse, hashlib, json, pathlib, subprocess, tempfile
P=pathlib.Path(__file__).resolve().parents[4]
a=argparse.ArgumentParser();a.add_argument('--stage',choices=['original','current'],required=True);args=a.parse_args()
out=pathlib.Path(__file__).resolve().parent
paths={n:'Sources/NextNotes/Agent/Schedules/'+n+'.swift' for n in ['AgentSchedule','AgentScheduler','ScheduledRunner']}
source={n:subprocess.check_output(['git','show','8888474:'+p],cwd=P,text=True) if args.stage=='original' else (P/p).read_text() for n,p in paths.items()}
def block(text,needle):
    start=text.index(needle);brace=text.index('{',start);depth=1;i=brace+1
    while depth:
        depth+= (text[i]=='{')-(text[i]=='}');i+=1
    return text[start:i]
router=source['ScheduledRunner'][source['ScheduledRunner'].index('enum RoutineModelRoute:'):source['ScheduledRunner'].index('/// The tools a routine')]
if args.stage=='original':
    router=router.replace('case local\n','case local\n    case appleFoundation\n',1).replace('cloudConfigured: Bool\n','cloudConfigured: Bool, appleAvailable: Bool = false\n',1)
settings=block(source['AgentScheduler'],'struct ScheduleSettingsSnapshot:')
settings=settings.replace(block(settings,'    @MainActor\n    static func fromSettings()'),'')
delivery=block(source['AgentScheduler'],'struct ScheduleDelivery:')
method=block(source['AgentScheduler'],'    private func deliverRoutineResult(').replace('private func','func',1)
make=block(source['AgentScheduler'],'    private func makeDelivery(')
stamp=block(source['AgentScheduler'],'    nonisolated static func stamp(')
live=block(source['ScheduledRunner'],'@MainActor\nfinal class LiveScheduledRunEnvironment:')
if args.stage=='original':
    live=live.replace('        case .skip:', '        case .appleFoundation: return nil\n        case .skip:',1)
model_support=r'''
enum LLMProviderID: Sendable { case appLLM, appleFoundation, openRouter }
protocol LLMProvider: Sendable {
 var id: LLMProviderID { get }; var contextTokens: Int { get }; var fileIdentity: String { get }
 var unavailableReason: String? { get async }
}
struct FixtureProvider: LLMProvider {
 let id: LLMProviderID; let contextTokens: Int; let fileIdentity: String
 var unavailableReason: String? { get async { nil } }
}
struct LlamaLLMProvider: LLMProvider {
 let id=LLMProviderID.appLLM, contextTokens=4096, fileIdentity="bare-default-file"
 var unavailableReason: String? { get async { nil } }
}
enum LLMProviders {
 @MainActor static func make(_ id: LLMProviderID, modelID: String? = nil, contextTokens: Int? = nil)->any LLMProvider {
  FixtureProvider(id:id,contextTokens:contextTokens ?? 4096,fileIdentity:"factory-shared-file")
 }
}
@MainActor final class ModelRoleStore {
 static let shared=ModelRoleStore()
 enum Role { case agent }
 func provider(for role: Role) async -> (any LLMProvider)? {
  FixtureProvider(id:.appLLM,contextTokens:4096,fileIdentity:"role-existing-file")
 }
}
@MainActor final class Settings {
 static let shared=Settings();let openRouterAgentModelID="fixture", openRouterAgentContextTokens=32768
}
protocol MemoryReviewModel: Sendable {}
enum UsageFeature: Sendable { case agentRoutine }
struct ProviderMemoryReviewModel: MemoryReviewModel {
 let provider:any LLMProvider; let maxTokens:Int; let usageFeature:UsageFeature
}
@MainActor protocol ScheduledRunEnvironment:AnyObject {
 var isRecording: Bool { get }
 func localModelState() async -> MemoryReviewLocalState
 func isCloudConfigured() async -> Bool
 func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)?
 func model(for route: RoutineModelRoute,maxOutputTokens:Int) async -> (any MemoryReviewModel)?
}
extension ScheduledRunEnvironment {
 func model(for route: RoutineModelRoute,maxOutputTokens:Int) async -> (any MemoryReviewModel)? { await model(for:route) }
}
@MainActor final class LiveMemoryReviewEnvironment {
 var isRecording:Bool { false }
 func localModelState() async -> MemoryReviewLocalState { .unavailable }
 func isCloudConfigured() async -> Bool { false }
 func isAppleFoundationAvailable() async -> Bool { true }
}
'''
support=r'''
import Foundation
enum AgentRisk: String, Codable, Sendable { case read, send }
struct ScheduleTriggerOccurrence: Codable, Equatable, Sendable {}
enum DigestTemplate { static let title="Morning digest" }
enum PodcastTemplate { static let title="Your morning podcast" }
enum MemoryReviewLocalState: Equatable, Sendable { case unavailable, notLoaded, idle(seconds: Double), busy }
@MainActor final class RecordedDelivery {
 var deliveries: [ScheduleDelivery] = []
 func deliver(_ d: ScheduleDelivery) async throws { deliveries.append(d) }
}
@MainActor final class FixturePresence {
 var isUserPresent=true, isRecording=false, isDictating=false, isCallActive=false, isAgentBusy=false
}
@MainActor final class AgentScheduler {
 let deliverer=RecordedDelivery(), environment=FixturePresence()
 var lastDeliveredText: [UUID:String]=[:]
 let zoneProvider: ()->TimeZone = { TimeZone(identifier:"America/New_York")! }
 func record(_ s: inout AgentSchedule, slot: Date?, at: Date, outcome: ScheduleRunRecord.Outcome, detail: String) {
  s.lastRun=ScheduleRunSummary(at:at,outcome:outcome,detail:detail)
 }
 func fail(_ s: inout AgentSchedule, slot: Date?, missed: Bool, now: Date, error: String, text: String? = nil) { fatalError("delivery fixture cannot fail") }
'''+method+'\n'+make+'\n'+stamp+'\n}\n'+model_support+'\n'+live
main=r'''
import Foundation
@main struct Driver {
 @MainActor static func main() async {
  var failures=0, cases=0
  func check(_ label: String,_ yes: Bool) { cases+=1; if !yes { failures+=1; print("P412_WRONG: "+label) } }
  func date(_ hour:Int,_ minute:Int)->Date {
   var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"America/New_York")!
   return c.date(from:DateComponents(year:2026,month:9,day:16,hour:hour,minute:minute))!
  }
  let rows:[(AgentSchedule.ModelChoice,Bool,MemoryReviewLocalState,Bool,RoutineModelRoute)]=[
   (.auto,false,.unavailable,false,.appleFoundation), (.auto,false,.busy,true,.appleFoundation),
   (.auto,true,.idle(seconds:99),true,.cloud), (.auto,true,.idle(seconds:99),false,.appleFoundation),
   (.local,false,.busy,true,.appleFoundation), (.local,true,.notLoaded,true,.appleFoundation),
   (.cloud,false,.idle(seconds:99),false,.skip("OpenRouter isn't set up"))]
  for (i,row) in rows.enumerated() {
   check("Apple router row \(i+1)",RoutineModelRouter.route(choice:row.0,isRecording:row.1,local:row.2,cloudConfigured:row.3,appleAvailable:true)==row.4)
  }
  check("runnable local retains priority",RoutineModelRouter.route(choice:.auto,isRecording:false,local:.notLoaded,cloudConfigured:true,appleAvailable:true)==.local)
  check("cloud explicit retains choice",RoutineModelRouter.route(choice:.cloud,isRecording:false,local:.notLoaded,cloudConfigured:true,appleAvailable:true)==.cloud)
  let live=LiveScheduledRunEnvironment()
  let digestModel=await live.model(for:.local,maxOutputTokens:1536) as? ProviderMemoryReviewModel
  check("digest budget reaches actual environment model",digestModel?.maxTokens==1365)
  check("actual local environment retains Agent role file",digestModel?.provider.fileIdentity=="role-existing-file")
  let cloudPodcast=await live.model(for:.cloud,maxOutputTokens:4096) as? ProviderMemoryReviewModel
  check("cloud podcast budget reaches actual model",cloudPodcast?.maxTokens==4096)
  let settings=ScheduleSettingsSnapshot(enabled:true,quietStart:ScheduleLocalTime(hour:21,minute:0),quietEnd:ScheduleLocalTime(hour:8,minute:0),speech:.whenPresent)
  let scheduler=AgentScheduler()
  var early=AgentSchedule(kind:.routine,title:"Digest",plainEnglish:"At 7",prompt:"Digest.",createdAt:date(6,0))
  await scheduler.deliverRoutineResult(&early,text:"Digest.",slot:date(7,0),now:date(7,0),settings:settings,outcome:.completed,ignoreQuiet:false)
  check("07:00 explicit routine delivers",scheduler.deliverer.deliveries.count==1 && early.pendingDelivery==nil && early.lastRun?.outcome == .completed)
  check("07:00 delivery never speaks",scheduler.deliverer.deliveries.first?.speak==false)
  var late=AgentSchedule(kind:.routine,title:"Late",plainEnglish:"At 20",prompt:"Late.",createdAt:date(19,0))
  await scheduler.deliverRoutineResult(&late,text:"Late.",slot:date(20,0),now:date(21,30),settings:settings,outcome:.completed,ignoreQuiet:false)
  check("late outside-slot result held",late.pendingDelivery?.text=="Late." && late.lastRun?.outcome == .deferred)
  var trigger=AgentSchedule(kind:.trigger,title:"Call",plainEnglish:"After calls",prompt:"Recap.",trigger:.callStarted,createdAt:date(21,31))
  await scheduler.deliverRoutineResult(&trigger,text:"Recap.",slot:nil,now:date(22,0),settings:settings,outcome:.completed,ignoreQuiet:false)
  check("trigger result held",trigger.pendingDeliveries.count==1 && trigger.pendingDelivery?.text=="Recap." && trigger.lastRun?.outcome == .deferred)
  print(failures==0 ? "P412_PRODUCERS_OK: \(cases) cases" : "P412_PRODUCERS_FAILED: \(failures)/\(cases)")
  exit(failures==0 ? 0:1)
 }
}
'''
# Spaces before dot enum members matter to Swift's operator lexer.
main=main.replace(')==.local',') == .local').replace(')==.cloud',') == .cloud')
with tempfile.TemporaryDirectory(prefix='NextNotes-p412-') as tmp:
 tmp=pathlib.Path(tmp)
 files={'Schedule.swift':source['AgentSchedule'],'Support.swift':support+'\n'+settings+'\n'+delivery+'\n'+router,'Driver.swift':main}
 for name,text in files.items(): (tmp/name).write_text(text)
 manifest={'stage':args.stage,'baseline':'8888474' if args.stage=='original' else None,
  'sources':{paths[n]:hashlib.sha256(t.encode()).hexdigest() for n,t in source.items()},
  'generated':{n:hashlib.sha256(t.encode()).hexdigest() for n,t in files.items()},
  'scope':'actual copied router/deliverRoutineResult/makeDelivery/quiet predicates; recording shell, not installed scheduler'}
 (out/(args.stage+'-manifest.json')).write_text(json.dumps(manifest,indent=2)+'\n')
 cmd=['xcrun','swiftc','-swift-version','6','-module-cache-path',str(tmp/'modules'),*[str(tmp/n) for n in files],'-o',str(tmp/'driver')]
 built=subprocess.run(cmd,text=True,capture_output=True)
 log='command: '+' '.join(cmd)+'\n'+built.stdout+built.stderr
 if built.returncode: print(log);(out/(args.stage+'-producer.log')).write_text(log);raise SystemExit(built.returncode)
 result=subprocess.run([str(tmp/'driver')],text=True,capture_output=True)
 log+=result.stdout+result.stderr
 (out/(args.stage+'-producer.log')).write_text(log)
 print(result.stdout+result.stderr,end='');raise SystemExit(result.returncode)
