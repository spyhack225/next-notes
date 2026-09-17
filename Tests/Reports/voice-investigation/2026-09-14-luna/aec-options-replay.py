# Diagnostic only: compares native AEC3 options after make build. Requires NumPy.
# This reports measurements; COMPLETE is not an acoustic acceptance verdict.
import ctypes as C, struct, sys
from pathlib import Path
import numpy as np

def wav(path):
 b=Path(path).read_bytes(); p=12
 while p+8<len(b):
  k=b[p:p+4]; n=struct.unpack_from('<I',b,p+4)[0]
  if k==b'fmt ': assert struct.unpack_from('<HHI',b,p+8)==(3,1,16000)
  if k==b'data': return np.frombuffer(b[p+8:p+8+n],dtype='<f4').copy()
  p+=8+n+n%2
 raise ValueError('missing PCM')
lib=C.CDLL(str(Path.home()/'Library/Caches/NextNotesBuild/webrtc/current/libNextNotesAEC.dylib'))
lib.aec_create_options_v1.argtypes=[C.c_uint32]; lib.aec_create_options_v1.restype=C.c_void_p
lib.aec_destroy.argtypes=[C.c_void_p]
ptr=C.POINTER(C.c_float)
lib.aec_feed_render.argtypes=[C.c_void_p,ptr]
lib.aec_process_capture.argtypes=[C.c_void_p,ptr,ptr,C.c_int]
if len(sys.argv) != 3: raise SystemExit('usage: python3 aec-options-replay.py FAR_FLOAT32_16K_WAV NEAR_FLOAT32_16K_WAV')
far=wav(sys.argv[1])[:144000]; far*=.125/np.sqrt(np.mean(far**2))
near=wav(sys.argv[2])[:8000]; near/=np.sqrt(np.mean(near**2))
def run(options,onset=1600,level=.02,echo=True):
 render=far.copy() if echo else np.zeros_like(far)
 mic=np.zeros_like(far)
 if echo:
  mic[320:]+=render[:-320]*.06
  mic[571:]+=render[:-571]*.02
 if level: mic[onset:onset+len(near)]+=near*level
 state=lib.aec_create_options_v1(options); assert state
 out=np.zeros_like(mic)
 try:
  for start in range(0,len(far),160):
   assert lib.aec_feed_render(state,render[start:start+160].ctypes.data_as(ptr))==0
   assert lib.aec_process_capture(state,mic[start:start+160].ctypes.data_as(ptr),out[start:start+160].ctypes.data_as(ptr),0)==0
 finally: lib.aec_destroy(state)
 return out,mic
for option in (0,4,8,12,16):
 echo,mic=run(option,level=0)
 erle=10*np.log10(np.mean(mic**2)/max(1e-12,np.mean(echo**2)))
 print('options',option,'echo_erle',round(float(erle),2))
 for onset in (1600,24000,64000):
  for level in (.02,.10):
   clean,_=run(option,onset,level)
   baseline,_=run(option,onset,level,False)
   vals=[]
   for n in (1600,8000):
    known=near[:n]*level
    lag=max(range(512),key=lambda lag: float(np.dot(baseline[onset+lag:onset+lag+8000],near)))
    sl=slice(onset+lag,onset+lag+n)
    fit=lambda x: np.dot(x[sl],known)/np.dot(known,known)
    assert .9 < fit(baseline) < 1.1, ('invalid near calibration', lag, fit(baseline))
    vals.append(round(float(fit(clean)/fit(baseline)),3))
   print('onset',onset/16000,'level',level,'first100_gain',vals[0],'full_gain',vals[1],'calibration_lag',lag)
print('AEC_OPTIONS_REPLAY_COMPLETE: synthetic room path, not hardware acceptance')
