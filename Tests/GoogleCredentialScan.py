"""Pattern scans only: never opens/compares the private OAuth JSON or prints matches."""
from pathlib import Path
import re
import subprocess

patterns = [re.compile(r'[0-9]{8,}-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com'),
            re.compile(r'GOCSPX-[A-Za-z0-9_-]{8,}')]
synthetic = '123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com'

def check(label, content):
    assert all(match.group() == synthetic for pattern in patterns for match in pattern.finditer(content)), label + '_FAILED'
    print(label + '_OK')

check('COMMITS_SECRET_SCAN', subprocess.check_output(['git', 'log', '-p', 'c6d850c..HEAD']).decode(errors='replace'))
check('DIFF_SECRET_SCAN', subprocess.check_output(['git', 'diff', 'c6d850c']).decode(errors='replace'))
paths = subprocess.check_output(['git', 'diff', '--name-only', 'c6d850c']).decode().splitlines()
paths += subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard']).decode().splitlines()
text = '\n'.join(Path(path).read_text(errors='replace') for path in paths
                 if Path(path).is_file() and not path.startswith('.google-review-work/'))
check('WIP_SECRET_SCAN', text)
