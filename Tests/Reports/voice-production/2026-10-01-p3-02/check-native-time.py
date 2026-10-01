#!/usr/bin/env python3
"""Actual runner union methods + actual native charge expression, deterministic instants."""
from pathlib import Path
import subprocess, tempfile, sys
repo=Path(__file__).resolve().parents[4]
runner=(repo/'Sources/NextNotes/Agent/Planner/ToolStepRunner.swift').read_text()
loop=(repo/'Sources/NextNotes/Agent/RealtimeAgent+ToolLoop.swift').read_text()
def method(marker):
 start=runner.index(marker); brace=runner.index('{',start); depth=1; end=brace+1
 while depth:
  if runner[end]=='{': depth+=1
  elif runner[end]=='}': depth-=1
  end+=1
 return runner[start:end]
methods='\n'.join(method(m) for m in ['    func charge(', '    func executionUnionTime(', '    private func beginExecutionMeasurement(', '    private func endExecutionMeasurement('])
if len(sys.argv)>1 and sys.argv[1]=='break-overlap':
 methods=methods.replace('if activeExecutions == 0 { executionUnionStart = now }','executionUnionStart = now').replace('if activeExecutions == 0, let start = executionUnionStart {','if let start = executionUnionStart {')
charge_start=loop.index('                let nonModelTime = runner.executionUnionTime(at: nativeEnded) - executionTimeBefore')
charge_end=loop.index('\n                guard isCurrent(owner)',charge_start)
charge=loop[charge_start:charge_end]
assert 'beginExecutionMeasurement()\n        defer { endExecutionMeasurement() }' in runner
fixture='''import Foundation
final class Runner {
 var ceilingRemaining: Duration = .seconds(10)
 private var activeExecutions=0
 private var executionUnionStart: ContinuousClock.Instant?
 private var finishedExecutionUnionTime: Duration = .zero
'''+methods+'''
 func enter(_ now: ContinuousClock.Instant) { beginExecutionMeasurement(now: now) }
 func leave(_ now: ContinuousClock.Instant) { endExecutionMeasurement(now: now) }
}
@main struct Driver {
 static func main() {
 let runner=Runner()
 let nativeBegan=ContinuousClock.now
 let executionTimeBefore=runner.executionUnionTime(at: nativeBegan)
 runner.enter(nativeBegan.advanced(by: .milliseconds(50)))
 runner.enter(nativeBegan.advanced(by: .milliseconds(100)))
 runner.leave(nativeBegan.advanced(by: .milliseconds(150)))
 runner.leave(nativeBegan.advanced(by: .milliseconds(200)))
 runner.enter(nativeBegan.advanced(by: .milliseconds(250)))
 runner.leave(nativeBegan.advanced(by: .milliseconds(300)))
 // This existing read charge stays in the same runner ceiling.
 runner.charge(.milliseconds(20))
 let nativeEnded=nativeBegan.advanced(by: .milliseconds(350))
'''+charge+'''
 let correct=runner.executionUnionTime(at: nativeEnded) == .milliseconds(200)
  && runner.ceilingRemaining == .seconds(10) - .milliseconds(170)
 print(correct ? "DUPLEX_NATIVE_TIME_OK" : "DUPLEX_NATIVE_TIME_FAILED")
 Foundation.exit(correct ? 0 : 1)
 }
}
'''
with tempfile.TemporaryDirectory(prefix='nextnotes-native-time-') as tmp:
 tmp=Path(tmp); path=tmp/'fixture.swift'; path.write_text(fixture)
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(path),'-o',str(tmp/'fixture')],check=True)
 raise SystemExit(subprocess.run([str(tmp/'fixture')],timeout=5).returncode)
