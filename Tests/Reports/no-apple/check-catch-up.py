from pathlib import Path
import sys
r=Path(__file__).resolve().parents[3]
s=(r/'Sources/NextNotes/Agent/Schedules/CatchUpTemplate.swift').read_text()
ok='audioStatus(taskID, availability == .ready ? .failed : availability)' in s
print('CATCH_UP_VOICE_SOURCE_OK' if ok else 'CATCH_UP_VOICE_SOURCE_FAILED')
sys.exit(not ok)
