"""Core Audio route/level helper for the explicitly authorized speaker experiment."""
import ctypes,json
from ctypes import c_uint32 as U,c_int32 as I,c_float as F,c_void_p as P,byref
ca=ctypes.CDLL('/System/Library/Frameworks/CoreAudio.framework/CoreAudio')
class Address(ctypes.Structure):_fields_=[('selector',U),('scope',U),('element',U)]
for name,args in [('AudioObjectGetPropertyData',[U,ctypes.POINTER(Address),U,P,ctypes.POINTER(U),P]),('AudioObjectSetPropertyData',[U,ctypes.POINTER(Address),U,P,U,P])]:
 f=getattr(ca,name);f.argtypes=args;f.restype=I

def four(s):return int.from_bytes(s.encode(),'big')
def get(device,selector,scope='glob',channel=0,kind=U):
 value=kind();size=U(ctypes.sizeof(value));a=Address(four(selector),four(scope),channel)
 if ca.AudioObjectGetPropertyData(device,byref(a),0,None,byref(size),byref(value))!=0:return None
 return value.value

def put(device,selector,value,scope='glob',channel=0,kind=U):
 value=kind(value);a=Address(four(selector),four(scope),channel)
 if ca.AudioObjectSetPropertyData(device,byref(a),0,None,ctypes.sizeof(value),byref(value))!=0:raise RuntimeError('Audio property could not be set')

def selected():return {'input':get(1,'dIn '),'output':get(1,'dOut')}
def levels(device,scope):
 return {'device':device,'volumes':{str(c):v for c in (0,1,2) if (v:=get(device,'volm',scope,c,F)) is not None},'mute':get(device,'mute',scope)}
def snapshot():
 route=selected();return {role:levels(device,'inpt' if role=='input' else 'outp') for role,device in route.items()}
def route(devices):
 for role,device in devices.items():put(1,'dIn ' if role=='input' else 'dOut',device)
 if selected()!=devices:raise RuntimeError('Selected route did not settle')
def restore_levels(data):
 for role,row in data.items():
  scope='inpt' if role=='input' else 'outp'
  for channel,value in row['volumes'].items():put(row['device'],'volm',value,scope,int(channel),F)
  if row['mute'] is not None:put(row['device'],'mute',row['mute'],scope)

if __name__=='__main__':print(json.dumps({'selected':snapshot(),'builtInTransport':{str(d):get(d,'tran') for d in [90,83]}},indent=2))
