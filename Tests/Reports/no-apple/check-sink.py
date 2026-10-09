"""No app Apple synthesis; explicit existing catalog/standalone tool exceptions."""
from pathlib import Path
import sys,json,re
root=Path(__file__).resolve().parents[3]
allow=json.loads(Path(__file__).with_name('speech-source-allowlist.json').read_text())
patterns=[re.compile(r'\b(?:AVSpeech\w*|NSSpeechSynthesizer)\b'),
          re.compile(r'/usr/bin/say\b|/usr/bin/env\s+say\b'),
          re.compile(r'(?:^|[\s;|])say\s+(?:-|["\w$])|["\x27]say["\x27]')]
files=set()
for directory in ['Sources','Tools','Scripts','site/scripts']:
    if (root/directory).exists():files.update(p for p in (root/directory).rglob('*') if p.is_file())
files.update(p for pattern in ['Makefile*','*.mk','GNUmakefile'] for p in root.glob(pattern) if p.is_file())
# Executable support/fixture scripts, excluding retained reports and dependency trees.
for directory in ['Resources','Tests/Fixtures']:
    if (root/directory).exists():files.update(p for p in (root/directory).rglob('*') if p.is_file() and (p.suffix in {'.sh','.py','.js','.zsh','.bash','.rb','.pl','.ps1'} or p.stat().st_mode & 0o111))
# Source imports and scripts outside the named app/tool roots also count.
# Retained reports/vendor/generated web bundles are evidence/dependencies, not
# authored application sources or executable support scripts.
source_suffixes={'.swift','.m','.mm','.h','.c','.cc','.cpp','.cs'}
script_suffixes={'.sh','.py','.js','.zsh','.bash','.rb','.pl','.ps1','.mk'}
for path in root.rglob('*'):
    relative=path.relative_to(root).as_posix()
    if relative.startswith('.git/') or not path.is_file():continue
    # Specialized speech imports are forbidden in ANY readable file, even
    # retained evidence/dependencies, unless the exact line has a reason.
    try: imported_source=path.read_text()
    except UnicodeError: imported_source=''
    if re.search(r'^\s*(?:@preconcurrency\s+)?(?:import\b|@import\b|#\s*(?:import|include)\b)[^\n]*(?:AVSpeech\w*|NSSpeechSynthesizer)',imported_source,re.MULTILINE):
        files.add(path)
    if relative.startswith(('Tests/Reports/','Vendor/','docs/')):continue
    if path.suffix in source_suffixes | script_suffixes or path.name.startswith('Makefile') or path.name=='GNUmakefile':
        files.add(path)
    elif path.stat().st_mode & 0o111:
        with path.open('rb') as stream:
            if stream.read(2)==b'#!':files.add(path)
hits=[];exceptions=0
for path in sorted(files):
    try:source=path.read_text()
    except UnicodeError:continue # binary resources cannot import/call speech symbols
    relative=path.relative_to(root).as_posix()
    entry=allow.get(relative,{})
    permitted=list(entry.get('lines',[])) if entry.get('reason') else []
    for number,line in enumerate(source.splitlines(),1):
        script = (source.lstrip().startswith('#!') or path.suffix in {'.sh','.py','.js','.zsh','.bash','.rb','.pl','.ps1','.mk'} or path.name.startswith('Makefile') or path.name == 'GNUmakefile'
                  or relative.startswith(('Scripts/','scripts/','site/scripts/')))
        # Shell/Python comments are not executable commands; C/ObjC #import
        # and executable shebangs must still be scanned. Speech symbols are
        # always checked, including specialized framework imports.
        comment = script and line.lstrip().startswith('#') and not line.lstrip().startswith('#!')
        candidates = patterns[:1] if comment else patterns if script else patterns[:2]
        # Even existing catalog/benchmark files cannot hide a new synthesis
        # operation behind previously allowed declarations. Exact known writes
        # and the selected Agent preview are separately reasoned allowances.
        allowed_source_operation = bool(entry) and path.suffix in source_suffixes and re.search(r'\.(?:speak|write)\s*\(', line)
        if not allowed_source_operation and not any(p.search(line) for p in candidates):continue
        # Exact existing operations with bounded occurrence counts. Renaming a
        # file invalidates its allowance; adding even a duplicate line fails.
        if line.strip() in permitted:
            permitted.remove(line.strip());exceptions+=1
        else:hits.append(f'{relative}:{number}: forbidden speech symbol or command')
print(f'VOICE_POLICY_SOURCE_COUNTS forbidden={len(hits)} explicit_nonplayback_exceptions={exceptions} files={len(files)}')
for hit in hits:print(hit)
print('VOICE_SINK_SOURCE_FAILED' if hits else 'VOICE_SINK_SOURCE_OK')
sys.exit(bool(hits))
