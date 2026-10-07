import Foundation
@main struct Check {
 static func main() {
  let input="One.\u{000B}Two?\u{000C}Three!"
  let row:[String:[String]]=["original":OriginalChunker.sentences(in:input), "candidate":SentenceChunker.sentences(in:input)]
  print(String(data:try! JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
 }
}
