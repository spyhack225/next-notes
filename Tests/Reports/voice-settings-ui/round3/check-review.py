#!/usr/bin/env python3
"""Same source contracts against retained round-two and current UI producers."""
import hashlib, pathlib, subprocess, sys, re
root = pathlib.Path(__file__).resolve().parents[4]
rev = sys.argv[1] if len(sys.argv) > 1 else None
def read(path):
    path = 'Sources/NextNotes/' + path
    s = subprocess.check_output(['git', 'show', rev + ':' + path], cwd=root).decode() if rev else (root/path).read_text()
    print(path, hashlib.sha256(s.encode()).hexdigest())
    return s
section=read('UI/Settings/VoiceSettingsSection.swift')
message=read('Agent/Speech/AgentVoiceAvailability.swift')
note=read('UI/Components/VoiceTextOnlyNote.swift')
preview=read('UI/Settings/VoiceSettingsPreview.swift')
tab=read('UI/Settings/ModelsSettingsTab.swift')
lint=read('UI/UIStringsLint.swift')
checks={
 'no version/size literals in Voice section': not re.search(r'macOS 26|\b(?:MB|GB)\b', section),
 'plain Kokoro warning': 'Kokoro needs a newer version of macOS. Choose Pocket to hear replies.' in section,
 'unsupported selection has no selected outline': 'selected == engine && isAvailableOnThisMac(engine)' in section,
 'unsupported choice has no named voice row': 'else if isAvailableOnThisMac(selected)' in section,
 'selection has checkmark': 'isSelected ? "checkmark.circle.fill"' in section,
 'ready-only footer': 'availability == .ready' in section[section.index('private var footerText'):],
 'failure points beside to Retry': 'retry below' not in section and 'tap Retry' in section,
 'failure has warning icon': 'warning: true' in section,
 'primary Retry uses accent': '.tint(DS.Color.accent)' in section,
 'preparing orb is still': 'isAnimated: false' in section,
 'unknown progress is indeterminate': 'ProgressView()' in section,
 'no invented preview progress': 'progress: 0.4' not in preview,
 'preparing text names temporary text': 'Your voice is getting ready, so answers are in text for now.' in message,
 'failure text names retry': "Voice couldn't start, so your answer is in text. Retry in Voice settings." in message,
 'missing voice text agrees with auto-download': "Your voice isn't on this Mac yet, so answers are in text. Voice settings." in message,
 'notch shares wrapping interactive line with preview': 'VoiceTextOnlyIslandLine' in note and 'VoiceTextOnlyIslandLine' in preview and '.fixedSize(horizontal: false, vertical: true)' in note,
 'settings links carry accent': '.foregroundStyle(DS.Color.accent)' in note,
 'preview pins light': '.environment(\\.colorScheme, .light)' in preview and 'NSAppearance(named: .aqua)' in preview,
 '560 Models preview uses real page': 'ModelsSettingsTab(voicePreviewAvailability:' in preview and '.defaultScrollAnchor(.bottom)' in preview,
 'Voice literal size/version lint exists': 'voiceSectionProblems' in lint,
}
for name, ok in checks.items(): print(('PASS ' if ok else 'FAIL ') + name)
fails=sum(not v for v in checks.values())
print('VOICE_SETTINGS_REVIEW_FAILED: '+str(fails) if fails else 'VOICE_SETTINGS_REVIEW_OK')
sys.exit(bool(fails))
