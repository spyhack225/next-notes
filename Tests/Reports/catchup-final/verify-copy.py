from pathlib import Path
import subprocess

def discloses_permissions(source):
    return 'CatchUpOffer.permissionExplanation' in source and 'anything I would send waits for your yes.' not in source

path = 'Sources/NextNotes/UI/CatchUp/CatchUpSettingsSection.swift'
original = subprocess.check_output(['git', 'show', 'c0d37462:' + path], text=True)
fixed = Path(path).read_text()
assert not discloses_permissions(original)
assert discloses_permissions(fixed)
print('SETTINGS_PERMISSION_COPY_ORIGINAL_FAILED')
print('SETTINGS_PERMISSION_COPY_FIXED_OK')
