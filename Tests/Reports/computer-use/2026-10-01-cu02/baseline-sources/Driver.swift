
import Foundation
import Darwin
@main struct Driver {
 @MainActor static func main() async { exit(Int32(await run())) }
 @MainActor static func run() async -> Int {
 let root=FileManager.default.temporaryDirectory.appendingPathComponent("nextnotes-cu-headless-"+UUID().uuidString)
 do {
 try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
 defer{try? FileManager.default.removeItem(at:root)}
 let html=root.appendingPathComponent("cu-fixture.html")
 try "<!doctype html><title>Owned CU fixture</title><body><button>OK</button></body>".write(to:html,atomically:true,encoding:.utf8)
 let names=["Google Chrome","Google Chrome Canary","Microsoft Edge","Brave Browser"]
 guard let binary=names.map({URL(fileURLWithPath:"/Applications/"+$0+".app/Contents/MacOS/"+$0)}).first(where:{FileManager.default.isExecutableFile(atPath:$0.path)}) else {print("CU_ACTION_ABSENT: no Chromium binary");return 2}
 let profile=root.appendingPathComponent("profile")
 let process=Process(); process.executableURL=binary
 process.arguments=["--headless=new","--remote-debugging-port=0","--user-data-dir="+profile.path,"--no-first-run","--no-default-browser-check",html.absoluteString]
 process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
 try process.run()
 defer{if process.isRunning{process.terminate()}}
 var port:Int?;let deadline=Date().addingTimeInterval(20)
 while port==nil && Date()<deadline {
 if let text=try? String(contentsOf:profile.appendingPathComponent("DevToolsActivePort"),encoding:.utf8){port=Int(text.split(separator:"\n").first ?? "")}
 if port==nil{try? await Task.sleep(for:.milliseconds(100))}
 }
 guard let port,let probe=await BrowserCDPClient.probe(host:"127.0.0.1",port:port),let target=probe.targets.first(where:{$0.url.contains("cu-fixture.html")})else{print("CU_ACTION_FAILED: fixture debugger unavailable");return 1}
 let failures=await BrowserActionValiditySelfTest.failures(host:"127.0.0.1",port:port,target:target)
 for item in failures{print("CU_ACTION_WRONG: "+item)}
 print(failures.isEmpty ? "CU_ACTION_OK: actual production client fixture" : "CU_ACTION_FAILED: \(failures.count) actual client failures")
 return failures.isEmpty ? 0 : 1
 }catch{print("CU_ACTION_FAILED: "+error.localizedDescription);return 1}
 }
}
