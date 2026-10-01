#!/usr/bin/env python3
"""Compile actual pure reducer/test sources only; mutations never edit repository inputs."""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[4]
source = root / 'Sources/NextNotes/Agent/Duplex/VoiceContracts.swift'
mode = sys.argv[1] if len(sys.argv) > 1 else 'green'
body = source.read_text()
if mode == 'failure-hold':
    needle = 'if case .failed = outcome { next.failedInputHold = turn }'
    assert needle in body
    body = body.replace(needle, 'if case .failed = outcome { next.failedInputHold = nil }', 1)
elif mode == 'duplicate-commit':
    needle = '''case .committed(let turn, let text):
                guard next.lastCommittedTurn == nil || turn > next.lastCommittedTurn! else { return (state, []) }'''
    assert needle in body
    body = body.replace(needle, 'case .committed(let turn, let text):', 1)
elif mode == 'input-ended':
    needle = '''case .inputEnded(let turn):
                guard next.floor == .userProvisional(turn) else { return (state, []) }
                // The acoustic/control floor can end before text is classified.
                // Keep pending input and any failed-epoch effect hold intact.
                next.floor = .free
                next.lastUserSpeechAt = now'''
    assert needle in body
    body = body.replace(needle, 'case .inputEnded: break', 1)
elif mode != 'green':
    raise SystemExit('unknown mutation')
with tempfile.TemporaryDirectory(prefix='NextNotesVoiceReducer-') as tmp:
    contracts = Path(tmp) / 'VoiceContracts.swift'
    contracts.write_text(body)
    executable = Path(tmp) / 'reducer'
    subprocess.run(['swiftc', '-swift-version', '6', '-D', 'VOICE_REDUCER_PURE', str(contracts), str(root / 'Sources/NextNotes/Agent/Duplex/VoiceSessionReducerSelfTest.swift'), str(Path(__file__).with_name('pure-stubs.swift')), '-o', str(executable)], check=True)
    raise SystemExit(subprocess.run([str(executable)]).returncode)
