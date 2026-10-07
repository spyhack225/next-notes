import Foundation
@main struct Check {
 static func main() async {
  let old=OriginalChunker.self, candidate=SentenceChunker.self
  let seeds=["", "word", "a. b? c!", "e.g. 3.5 vs 2.0. End", "\n\n", "\n\n\nnext", "\r\n\r\nnext", "👩🏽‍💻 café! 中文？ next!", "e\u{301}. x", "... \t\n next", "a!\u{a0}b?\u{2003}c", "abc\u{2028}def. ghi\u{2029}jkl", "Mr. Jones, um. Hello", "new\nparagraph\n\nlast"]
  let wrappers=["", " ", "\n", "\n\n", "A. ", ".", "\t", "\r\n"]
  var cases=wrappers.flatMap { a in seeds.flatMap { b in wrappers.map { a+b+$0 } } }
  var random:UInt64=74213
  let atoms=["word", "a", "3", ".", "!", "?", " ", "\n", "\r\n", "\t", "é", "e\u{301}", "👩🏽‍💻", "\u{a0}", "\u{2003}", "\u{2028}", "\u{2029}", "中文"]
  let asciiAtoms=["word", "a", "3", ".", "!", "?", " ", "\n", "\r\n", "\t", "\u{000b}", "\u{000c}", "\u{0000}", "\u{007f}"]
  for row in 0..<2000 {
   let selected = row < 500 ? Array(asciiAtoms.filter { $0 != "\r\n" }) : (row < 1000 ? asciiAtoms : atoms)
   var text=""
   for _ in 0..<60 { random = random &* 6364136223846793005 &+ 1442695040888963407; text += selected[Int((random>>32)%UInt64(selected.count))] }
   cases.append(text)
  }
  var checks=0, failures=0
  for text in cases {
   checks += 1; if old.sentences(in:text) != candidate.sentences(in:text) { failures += 1 }
   for budget in [0,1,5,15,120] { checks += 1; if old.chunks(text,maxWords:budget) != candidate.chunks(text,maxWords:budget) { failures += 1 } }
  }
  let frozenCases=cases
  let concurrent=await withTaskGroup(of:Int.self) { group in
   for _ in 0..<4 { group.addTask { frozenCases.reduce(0) { $0+(old.sentences(in:$1) == candidate.sentences(in:$1) ? 0:1) } } }
   var bad=0;for await n in group { bad += n };return bad
  }
  failures += concurrent;checks += cases.count*4
  let prose=Array(repeating:"The first thing is this code. Next, ship it! Hello there.\n\nA paragraph? e.g. 3.5. ",count:180).joined()
  var timings:[[String:Double]]=[];var checksum=0
  for i in 0..<6 {
   func measure(_ newer:Bool)->Double {
    let began=ContinuousClock.now
    for _ in 0..<100 { checksum += (newer ? candidate.sentences(in:prose):old.sentences(in:prose)).count }
    let d=ContinuousClock.now-began;return Double(d.components.seconds)*1000+Double(d.components.attoseconds)/1e15
   }
   let a:Double,b:Double
   if i%2==0 { a=measure(false);b=measure(true) } else { b=measure(true);a=measure(false) }
   timings.append(["original_ms":a,"candidate_ms":b])
  }
  let result:[String:Any]=["cases":cases.count,"checks":checks,"failures":failures,"timings_100_splits":timings,"checksum":checksum]
  print(String(data:try! JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
 }
}
