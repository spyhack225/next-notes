#!/usr/bin/env python3
"""Serial root-only compiler driver: copied production CDP/yield source, real Chrome.
Support shells contain only unexercised app presentation/image plumbing; screenshot paths
fatalError rather than pretend to pass. Browser catalogue, action logic, transports, cache,
HumanInputWatch, bounded wait and SecureFieldRule are copied unchanged from repo sources.
"""
import argparse, hashlib, json, pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[4]
out = pathlib.Path(__file__).resolve().parent
args = argparse.ArgumentParser(); args.add_argument('--stage', required=True); args.add_argument('--prepare-only', action='store_true'); parsed = args.parse_args()

def block(source, prefix):
    begin = source.index(prefix); brace = source.index('{',begin); depth=1; pos=brace+1
    # Only extract these type/function definitions, whose comments have no braces.
    while depth:
        c=source[pos]; depth += (c=='{')-(c=='}'); pos+=1
    return source[begin:pos]

with tempfile.TemporaryDirectory(prefix='nextnotes-cu-actual-') as tmp:
    tmp=pathlib.Path(tmp); manifest={}
    def copied(rel,name=None):
        raw=(repo/rel).read_bytes(); name=name or pathlib.Path(rel).name
        (tmp/name).write_bytes(raw); manifest[rel]=hashlib.sha256(raw).hexdigest()
    for rel in ['Sources/NextNotes/Computer/BrowserCDPClient.swift','Sources/NextNotes/Computer/HumanInputWatch.swift','Sources/NextNotes/Computer/SecureFieldRule.swift','Sources/NextNotes/Computer/BrowserActionValiditySelfTest.swift','Sources/NextNotes/Agent/Tools/AgentTool.swift','Sources/NextNotes/Agent/Tools/ShellTools.swift']:
        copied(rel)
    models=(repo/'Sources/NextNotes/Agent/AgentModels.swift').read_text()
    core=(repo/'Sources/NextNotes/Core/DictationController.swift').read_text()
    support='import Foundation\nimport AppKit\nimport os\n'
    workspace=(repo/'Sources/NextNotes/Agent/WorkspaceTools.swift').read_text()
    support += block(workspace,'struct WorkspaceTool:')+'\n'
    manifest['Sources/NextNotes/Agent/WorkspaceTools.swift']=hashlib.sha256(workspace.encode()).hexdigest()
    support += block(models,'enum AgentRisk:')+'\n'+block(models,'struct WorkspaceToolResult:')+'\ntypealias AgentToolResult = WorkspaceToolResult\n'
    screen=(repo/'Sources/NextNotes/Computer/ScreenCapture.swift').read_text()
    support += block(screen,'enum VerifyRetry {')+'\n'
    for partial in ['Sources/NextNotes/Agent/AgentModels.swift','Sources/NextNotes/Core/DictationController.swift','Sources/NextNotes/Computer/ScreenCapture.swift']:
        manifest[partial]=hashlib.sha256((repo/partial).read_bytes()).hexdigest()
    support += block(core,'private actor RaceGate<')+'\n'+block(core,'func withBoundedWait<')+'\n'
    support += '''
struct AgentError: LocalizedError {
 let errorDescription: String?
 static func backendUnavailable(_ text:String)->Self{.init(errorDescription:text)}
 static func permissionDenied(_ text:String)->Self{.init(errorDescription:text)}
 static func unknownTool(_ text:String)->Self{.init(errorDescription:text)}
 static func missingArgument(name:String,tool:String)->Self{.init(errorDescription:"Missing " + name)}
}
@MainActor struct AgentToolRegistry {
 static let shared = Self()
 func tool(named id:String)->AgentTool? { BrowserToolCatalogue.all.first{$0.id == id} }
}
// Presentation dependencies only. No named action/yield behavior is stubbed.
enum AgentWorkPresentationScope { @TaskLocal static var binding:String? }
@MainActor final class AgentActivityStore {
 static let shared=AgentActivityStore()
 func noteWindow(_ text:String, binding:String? = nil) {}
 func noteHumanYield() {}
}
enum BrowserPurchaseCard { static func preview(for args:[String:String])->String? { fatalError("Purchase is outside this driver") } }
enum SelfTest { static let isRunning = true }
enum Log { static let agent=Logger(subsystem:"NextNotesCUFixture",category:"fixture") }
struct LLMImage { var thumbnail:Data; var pixelWidth:Int; var pixelHeight:Int }
enum ScreenCapture { static func encode(cgImage:CGImage)throws->LLMImage { fatalError("Screenshot is outside this driver; cannot fake it") } }
enum ComputerToolExecutor { @MainActor static func publishCapture(_ image:LLMImage,for key:String,summary:String){ fatalError("Screenshot is outside this driver") } }
'''
    (tmp/'Support.swift').write_text(support)
    (tmp/'Driver.swift').write_text('''
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
 if let text=try? String(contentsOf:profile.appendingPathComponent("DevToolsActivePort"),encoding:.utf8){port=Int(text.split(separator:"\\n").first ?? "")}
 if port==nil{try? await Task.sleep(for:.milliseconds(100))}
 }
 guard let port,let probe=await BrowserCDPClient.probe(host:"127.0.0.1",port:port),let target=probe.targets.first(where:{$0.url.contains("cu-fixture.html")})else{print("CU_ACTION_FAILED: fixture debugger unavailable");return 1}
 let failures=await BrowserActionValiditySelfTest.failures(host:"127.0.0.1",port:port,target:target)
 for item in failures{print("CU_ACTION_WRONG: "+item)}
 print(failures.isEmpty ? "CU_ACTION_OK: actual production client fixture" : "CU_ACTION_FAILED: \\(failures.count) actual client failures")
 return failures.isEmpty ? 0 : 1
 }catch{print("CU_ACTION_FAILED: "+error.localizedDescription);return 1}
 }
}
''')
    # Keep exact inputs alongside the output so the red source survives later fixes.
    archive=out/(parsed.stage+'-sources');archive.mkdir(exist_ok=True)
    for path in tmp.glob('*.swift'):(archive/path.name).write_bytes(path.read_bytes())
    (out/(parsed.stage+'-manifest.json')).write_text(json.dumps(manifest,indent=2)+'\n')
    if parsed.prepare_only:
        print('Prepared actual source archive: '+str(archive));raise SystemExit(0)
    compile_cmd=['swiftc','-swift-version','6','-parse-as-library',*map(str,tmp.glob('*.swift')),'-o',str(tmp/'cu-driver')]
    build=subprocess.run(compile_cmd,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    (out/(parsed.stage+'-compile.txt')).write_text(build.stdout)
    if build.returncode:print(build.stdout);raise SystemExit(build.returncode)
    run=subprocess.run([str(tmp/'cu-driver')],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
    (out/(parsed.stage+'-output.txt')).write_text(run.stdout);print(run.stdout)
    raise SystemExit(run.returncode)
