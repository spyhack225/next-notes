import ctypes,datetime,json,pathlib,sys,time
pid=int(sys.argv[1]); out=pathlib.Path(sys.argv[2])
class Usage(ctypes.Structure):
 _fields_=[('uuid',ctypes.c_uint8*16)]+[(n,ctypes.c_uint64) for n in ('user','system','idle','wakeups','pageins','wired','resident','footprint','start','exit')]
lib=ctypes.CDLL('/usr/lib/libproc.dylib');lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p];lib.proc_pid_rusage.restype=ctypes.c_int
identity=None;until=time.monotonic()+360
with out.open('w',buffering=1) as f:
 while time.monotonic()<until:
  u=Usage()
  if lib.proc_pid_rusage(pid,0,ctypes.byref(u))!=0:break
  identity=identity or u.start
  if u.start!=identity:break
  f.write(json.dumps({'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'pid':pid,'start':u.start,'footprint_bytes':u.footprint,'resident_bytes':u.resident,'user_ns':u.user,'system_ns':u.system,'pageins':u.pageins})+'\n')
  time.sleep(.5)
