#!/bin/bash
set -euo pipefail
report=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$report/../../../.." && pwd)
scratch=$(mktemp -d /tmp/nextnotes-startup-regression.XXXXXX)
cleanup() {
  # A bounded original-code failure can leave its generated native peer running.
  # Match the exact executable AND this unique generated --system path.
  python3 - "$scratch" <<'PY'
import ctypes,os,pathlib,signal,subprocess,sys
scratch=sys.argv[1]
engine=str(pathlib.Path.home()/'Library/Application Support/Next Notes/Models/needle3-macos-arm64')
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
for line in subprocess.check_output(['ps','-axo','pid=,args='],text=True).splitlines():
 parts=line.strip().split(None,1)
 if len(parts)!=2 or '--system '+scratch+'/system.txt' not in parts[1]:continue
 pid=int(parts[0]);buf=ctypes.create_string_buffer(4096)
 if lib.proc_pidpath(pid,buf,4096)>0 and os.fsdecode(buf.value)==engine:
  try:os.kill(pid,signal.SIGTERM)
  except ProcessLookupError:pass
PY
  rm -rf "$scratch"
}
trap cleanup EXIT
source=${1:-"$repo/Sources/NextNotes/Agent/FunctionCalling/NeedleServer.swift"}
python3 - "$repo" "$scratch" <<'PY'
import pathlib,sys
repo=pathlib.Path(sys.argv[1]); scratch=pathlib.Path(sys.argv[2])
source=(repo/'Sources/NextNotes/Agent/FunctionCalling/NeedleEngine.swift').read_text()
start=source.index('struct NeedleResponse:'); end=source.index('/// Runs the Needle CLI',start)
buffers=source[source.index('final class NeedleBuffers:'):]
(scratch/'Dependencies.swift').write_text('import Foundation\n'+source[start:end]+buffers)
engine=scratch/'failed-engine'
engine.write_text('#!/bin/sh\necho launch >> "'+str(scratch/'launches')+'"\n/bin/sleep 0.2\necho fixture-start-failed >&2\nexit 1\n')
engine.chmod(0o755)
PY
xcrun swiftc -swift-version 6 -parse-as-library -O "$source" \
  "$repo/Sources/NextNotes/Agent/FunctionCalling/NeedleServerStartupSelfTest.swift" \
  "$scratch/Dependencies.swift" "$report/StartupRegression.swift" -o "$scratch/probe"
"$scratch/probe" "$scratch" "${2:-}"
