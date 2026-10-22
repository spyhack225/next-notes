import Foundation
struct RouterSemantic: TextFormatter {
    let calls: LockedBox<[String]>
    let upper: Bool
    func format(_ raw: String) async -> String {
        calls.value.append(raw)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return upper ? trimmed.uppercased() : trimmed
    }
}
@main struct FullRouterCheck {
    struct Case: Sendable { let name: String; let commits: [String]; let final: String; let mustReuse: Bool }
    static func main() async {
        #if GROUP_PREPARE
        let candidate = true
        #else
        let candidate = false
        #endif
        let quote = "Open quote. We will deliver every required feature and preserve its exact meaning. End quote."
        let code = "Start code. npm run dev --host zero dot zero dot zero dot zero. End code."
        let list = "Start the list. First point, preserve the original dictated words and their meaning. Second point, preserve all file tags and final formatting. Close the list."
        let prose = "We will deliver every required feature and preserve its exact meaning."
        let tail = "The remaining sentence finishes later."
        let cases: [Case] = [
            .init(name:"closed-quote",commits:[quote],final:quote+" "+tail,mustReuse:true),
            .init(name:"closed-list",commits:[list],final:list+" "+tail,mustReuse:true),
            .init(name:"closed-code",commits:[code],final:code+" "+tail,mustReuse:true),
            .init(name:"ordinary",commits:[prose],final:prose+" "+tail,mustReuse:true),
            .init(name:"revised",commits:[prose],final:"We must retain the original words and their meaning. "+tail,mustReuse:false),
            .init(name:"cross-quote",commits:["Open quote. We will deliver every required feature.",quote],final:quote+" "+tail,mustReuse:false),
            .init(name:"cross-list",commits:["Start the list. First point, preserve the original dictated words and their meaning.",list],final:list+" "+tail,mustReuse:false),
            .init(name:"unicode",commits:["ßeta is a named file and must retain all of its original content."],final:"ßeta is a named file and must retain all of its original content. "+tail,mustReuse:true),
            .init(name:"two-structured-heads",commits:[quote,quote+" "+code],final:quote+" "+code+" "+tail,mustReuse:true),
            .init(name:"paragraph-between-heads",commits:[prose,prose+" New paragraph. "+prose],final:prose+" New paragraph. "+prose+" "+tail,mustReuse:true)
        ]
        var checks = 0, reuseFailures = 0, exactFailures = 0, traceFailures = 0, refusalFailures = 0, tailFailures = 0
        for upper in [false,true] {
            for markdown in [false,true] {
                let target = OutputProfile(bundleID:"fixture",displayName:"Fixture",capabilities:markdown ? Set(OutputCapability.allCases) : [])
                for enabled in [false,true] {
                    for item in cases {
                        let calls=LockedBox<[String]>([])
                        let semantic=RouterSemantic(calls:calls,upper:upper)
                        #if GROUP_PREPARE
                        let producer=IncrementalCleanupSession(semantic:semantic,
                            rules:{ RuleBasedFormatter().apply($0,isFinal:false) },
                            prepareGroup:{ SpokenStructure.apply(to:$0,target:target,isEnabled:enabled).text })
                        #else
                        let producer=IncrementalCleanupSession(semantic:semantic,
                            rules:{ RuleBasedFormatter().apply($0,isFinal:false) })
                        #endif
                        for committed in item.commits { await producer.notePartial(committed,committed:committed) }
                        let head=await producer.head()
                        for task in head.cleaned { _ = await task.value }
                        let during=calls.value.count
                        let trace=CleanupTrace()
                        let result=await CleanupRouter(semantic:semantic,engine:.apple,formatsLists:enabled,
                            target:target,trace:trace,pressureSample:{ .idle }).format(item.final,head:head)
                        let control=await CleanupRouter(semantic:RouterSemantic(calls:LockedBox([]),upper:upper),
                            engine:.apple,formatsLists:enabled,target:target,pressureSample:{ .idle }).format(item.final)
                        let used=trace.snapshot.precleanedGroups == head.cleaned.count && !head.cleaned.isEmpty
                        let exact=result==control
                        let traceExact=trace.snapshot.cleanedText==result
                        checks += 1
                        if item.mustReuse && !used { reuseFailures += 1 }
                        if !item.mustReuse && used { refusalFailures += 1 }
                        if used && calls.value.count - during != 1 { tailFailures += 1 }
                        if !exact { exactFailures += 1 }
                        if !traceExact { traceFailures += 1 }
                        let row:[String:Any]=["case":item.name,"candidate":candidate,"upper":upper,"markdown":markdown,"enabled":enabled,"groups":head.cleaned.count,"requiredReuse":item.mustReuse,"headUsed":used,"keyUpModelCalls":calls.value.count-during,"finalExact":exact,"traceExact":traceExact,"output":result,"control":control]
                        if let d=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) { print(String(decoding:d,as:UTF8.self)) }
                        await producer.cancel()
                    }
                }
            }
        }
        print("FULL_ROUTER_REVIEW: candidate=\(candidate) cases=\(checks) reuseFailures=\(reuseFailures) exactFailures=\(exactFailures) traceFailures=\(traceFailures) refusalFailures=\(refusalFailures) tailFailures=\(tailFailures)")
        if reuseFailures>0 || exactFailures>0 || traceFailures>0 || refusalFailures>0 || tailFailures>0 { exit(1) }
    }
}
