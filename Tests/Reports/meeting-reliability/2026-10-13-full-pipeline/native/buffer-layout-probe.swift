import AVFoundation
import Foundation
let scenario=CommandLine.arguments[1]
let shapes:[(UInt32,Int)]
switch scenario{case "interleaved":shapes=[(2,512*8)];case "planar":shapes=[(1,512*4),(1,512*4)];case "mono-plus-tap":shapes=[(1,512*4),(2,512*8)];case "tap-plus-mono":shapes=[(2,512*8),(1,512*4)];default:fatalError("unknown authored layout")}
let bytes=MemoryLayout<AudioBufferList>.size+(shapes.count-1)*MemoryLayout<AudioBuffer>.size
let memory=UnsafeMutableRawPointer.allocate(byteCount:bytes,alignment:MemoryLayout<AudioBufferList>.alignment);memory.initializeMemory(as:UInt8.self,repeating:0,count:bytes);defer{memory.deallocate()}
let list=memory.assumingMemoryBound(to:AudioBufferList.self);list.pointee.mNumberBuffers=UInt32(shapes.count);var storage=[UnsafeMutableRawPointer]();let buffers=UnsafeMutableAudioBufferListPointer(list)
for (i,shape) in shapes.enumerated(){let p=UnsafeMutableRawPointer.allocate(byteCount:shape.1,alignment:16);p.initializeMemory(as:Float.self,repeating:Float(i+1)/10,count:shape.1/4);storage.append(p);buffers[i]=AudioBuffer(mNumberChannels:shape.0,mDataByteSize:UInt32(shape.1),mData:p)}
defer{for p in storage{p.deallocate()}}
let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:true)!
let borrowed=AVAudioPCMBuffer(pcmFormat:format,bufferListNoCopy:list)
var row:[String:Any]=["scenario":scenario,"expectedTapFrames":512,"declaredTapFormat":"48kHz/interleaved/Float32/stereo","buffers":shapes.map{["channels":$0.0,"bytes":$0.1]},"constructorAccepted":borrowed != nil]
if let b=borrowed{row["constructedFrames"]=b.frameLength;row["constructedStride"]=b.stride;if let c=b.floatChannelData?[0]{let s=(0..<Int(b.frameLength)).map{c[$0*b.stride]};row["firstChannelCount"]=s.count;row["firstChannelMean"]=s.isEmpty ? 0:Double(s.reduce(0,+))/Double(s.count)}}
print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
