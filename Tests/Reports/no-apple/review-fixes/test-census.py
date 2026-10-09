from pathlib import Path
import subprocess,tempfile,shutil,sys,json
scanner=Path(sys.argv[1]).resolve()
cases={'Sources/NextNotes/Renamed.swift':'let engine = NSSpeechSynthesizer()','Sources/NextNotes/Another.swift':'import class AVFoundation.AVSpeechUtterance','Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift':'let engine = AVSpeechSynthesizer()','Tools/tts_benchmark.swift':'let surprise = NSSpeechSynthesizer()','Scripts/renamed.sh':'/usr/bin/say hello','Makefile':'voice:\n\tsay hello','Tools/voice.py':'subprocess.run(["/usr/bin/say", "hello"])','Sources/NextNotes/Renamed.m':'#import <AVFoundation/AVSpeechSynthesizer.h>','Scripts/without-extension':'#!/bin/sh\nsay hello','Scripts/speech-shebang':'#!/usr/bin/say','Tools/renamed-tool':'#!/bin/sh\nsay hello','renamed-build.mk':'voice:\n\tsay hello','bench/new-route.py':'subprocess.run(["say", "hello"])','shared/NewRoute.swift':'import protocol AVFoundation.AVSpeechSynthesizerDelegate','Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift#operation':'synthesizer.speak("Unexpected Apple playback")','Tools/tts_benchmark.swift#operation':'probe.synthesizer.write(unexpectedUtterance) { _ in }','docs/renamed.txt':'import class AVFoundation.AVSpeechUtterance'}
cases.update({
    'Sources/NextNotes/EnvVoice.swift': 'let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/env"); task.arguments = ["say", "Hello"]',
    'Scripts/stdin-voice.sh': "printf 'Hello' | say",
    'Sources/NextNotes/EnvVoice.c': 'const char *args[] = {"say", "Hello"};',
    'Scripts/exec-voice.sh': 'exec say Hello',
})
cases.update({
    'Sources/NextNotes/ShellVoice.swift': 'let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", "say Hello"]',
    'Sources/NextNotes/SystemVoice.c': 'system("say Hello");',
    'Sources/NextNotes/PopenVoice.c': 'popen("say Hello", "r");',
    'Scripts/stdin-exec.sh': 'printf x | exec say',
    'Scripts/stdin-echo.sh': 'echo hi | say',
    'Scripts/bare-say.sh': 'say',
    'Scripts/exec-bare-say.sh': 'exec say',
    'Sources/NextNotes/SystemStdin.c': 'system("printf x | exec say");',
})
# Round 5: ordinary spacing, wrappers/options and stdin redirections. Each
# body is scanned as source only; no injected speech command is executed.
cases.update({
    'Sources/NextNotes/LeadingSpace.c': 'system(" say Hello");',
    'Sources/NextNotes/AdjacentPipe.c': 'system("printf Hello|say");',
    'Sources/NextNotes/LeadingSpace.swift': 'let task = Process(); task.arguments = ["-c", " say Hello"]',
    'Sources/NextNotes/AdjacentPipe.swift': 'let task = Process(); task.arguments = ["-c", "printf Hello|say"]',
    'Scripts/pipe-env-options.sh': 'printf Hello | env -i say',
    'Scripts/adjacent-pipe-env-options.sh': 'printf Hello|env -i say',
    'Scripts/heredoc.sh': 'say<<EOF\nHello\nEOF',
    'Scripts/redirect.sh': 'say<file',
    'Scripts/here-string.sh': 'say <<<"x"',
    'Sources/NextNotes/Redirect.c': 'system("say<file");',
    'Tools/env-stdin.py': 'subprocess.run("env -i say", shell=True, input="Hello", text=True)',
    'Sources/NextNotes/EnvOptionsArgs.swift': 'let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/env"); task.arguments = ["-i", "say", "Hello"]',
    'Sources/NextNotes/OutputPipe.c': 'system("say|cat");',
    'Sources/NextNotes/TwoAdjacentPipes.c': 'system("printf Hello|say|cat");',
})
for name, command in {
    'env-options': 'env -i say',
    'command': 'command say',
    'nohup': 'nohup say',
    'env-path': '/usr/bin/env say',
    'nested-wrappers': 'command nohup /usr/bin/env -i say',
}.items():
    cases[f'Sources/NextNotes/{name}.swift'] = f'let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/sh"); task.arguments = ["-c", "{command} Hello"]'
    cases[f'Sources/NextNotes/{name}-system.c'] = f'system("{command} Hello");'
    cases[f'Sources/NextNotes/{name}-popen.c'] = f'popen("{command} Hello", "r");'
    cases[f'Scripts/{name}-stdin.sh'] = command
misses=[]
for path,body in cases.items():
    with tempfile.TemporaryDirectory(prefix='NextNotes-noapple-census-') as tmp:
        root=Path(tmp);p=root/path.split('#')[0];p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body)
        location=root/'Tests/Reports/no-apple/check-sink.py';location.parent.mkdir(parents=True,exist_ok=True);shutil.copy(scanner,location)
        manifest=scanner.parent/'speech-source-allowlist.json'
        if manifest.exists():shutil.copy(manifest,location.parent/manifest.name)
        proc=subprocess.run([sys.executable,str(location)],capture_output=True,text=True)
        if proc.returncode != 1 or not proc.stdout.rstrip().endswith("VOICE_SINK_SOURCE_FAILED"):misses.append(path)
print(json.dumps({'undetected':misses,'cases':len(cases)}))
print('VOICE_CENSUS_MUTATIONS_FAILED' if misses else 'VOICE_CENSUS_MUTATIONS_OK')
sys.exit(bool(misses))
