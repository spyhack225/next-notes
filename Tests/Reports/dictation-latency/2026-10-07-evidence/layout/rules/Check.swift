import Foundation
@main struct Check {
 static func main() async {
  let old = OriginalRules(), current = RuleBasedFormatter()
  let seeds = ["we we need to to check the the database connection again", "um, uh, erm, uhm, hmm, mhm, heu, euh", "new paragraph no no, that was very very good", "open paren café close paren new line résumé", "l'uh un'uh I'll I'll d'uh", "équipe déjà, voilà! 東京。 👩🏽‍💻 ship it", "a a a to to to very very very", "It started, it started the meeting", "the\tthe; I\nI\n\n\nnext", "foo$1 bar\\1", "uhmummy umami euphonium human", "中文文本 𝒜 αβγ Straße München"]
  let wrappers = ["", "uh ", "Um, ", "new line ", "hello. ", " \t\n", "we we ", "new paragraph "]
  let cases = wrappers.flatMap { a in seeds.flatMap { b in wrappers.map { a+b+$0 } } }
  var failures = old.selfTestFailuresForDriver + current.selfTestFailuresForDriver
  for text in cases {
   for final in [true,false] { if old.apply(text,isFinal:final) != current.apply(text,isFinal:final) { failures += 1 } }
   if await old.format(text) != current.format(text) { failures += 1 }
  }
  let concurrent = await withTaskGroup(of:Int.self) { group in
   for _ in 0..<4 { group.addTask { cases.reduce(0) { sum,text in sum + (old.apply(text) == current.apply(text) ? 0:1) } } }
   var bad=0;for await n in group { bad += n };return bad
  }
  failures += concurrent
  let passage = Array(repeating:seeds.joined(separator:". "),count:3).joined(separator:". ")
  var timings:[[String:Double]]=[];var checksum=0
  for i in 0..<6 {
   func measure(_ newer:Bool) -> Double {
    let began=ContinuousClock.now
    for _ in 0..<100 { checksum += (newer ? current.apply(passage) : old.apply(passage)).utf8.count }
    let d=ContinuousClock.now-began;return Double(d.components.seconds)*1000+Double(d.components.attoseconds)/1e15
   }
   let a:Double,b:Double
   if i%2==0 { a=measure(false);b=measure(true) } else { b=measure(true);a=measure(false) }
   timings.append(["original_ms":a,"candidate_ms":b])
  }
  let result:[String:Any] = ["cases":cases.count,"checks":cases.count*7+16,"failures":failures,"timings_100_passes":timings,"checksum":checksum]
  print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
 }
}
extension OriginalRules { var selfTestFailuresForDriver:Int { Self.selfTestFailures().count } }
extension RuleBasedFormatter { var selfTestFailuresForDriver:Int { Self.selfTestFailures().count } }
