import CoreAudio
import Foundation
if let i = CommandLine.arguments.firstIndex(of: "--set-output"), i + 1 < CommandLine.arguments.count {
 guard var level = Float32(CommandLine.arguments[i+1]), level > 0, level <= 1 else { exit(2) }
 var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
 var device:AudioDeviceID=0;var size:UInt32=4
 guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr else {exit(3)}
 address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:kAudioDevicePropertyScopeOutput,mElement:0)
 guard AudioObjectSetPropertyData(device,&address,0,nil,size,&level)==noErr else {exit(4)}
}
var rows: [[String:Any]] = []
for (name,selector,scope) in [("input",kAudioHardwarePropertyDefaultInputDevice,kAudioDevicePropertyScopeInput),("output",kAudioHardwarePropertyDefaultOutputDevice,kAudioDevicePropertyScopeOutput)] {
 var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 var device:AudioDeviceID=0;var n=UInt32(MemoryLayout<AudioDeviceID>.size)
 guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&device)==noErr else{continue}
 var row:[String:Any]=["scope":name,"device":device]
 for channel:UInt32 in [0,1,2] {
  a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyVolumeScalar,mScope:scope,mElement:channel);var v:Float32=0;n=4
  if AudioObjectGetPropertyData(device,&a,0,nil,&n,&v)==noErr{row["volume\(channel)"]=v}
 }
 a=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:scope,mElement:0);var muted:UInt32=0;n=4
 if AudioObjectGetPropertyData(device,&a,0,nil,&n,&muted)==noErr{row["muted"]=muted}
 rows.append(row)
}
print(String(data:try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
