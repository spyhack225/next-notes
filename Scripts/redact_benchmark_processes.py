"""Public-report boundary: retain process numbers, never host process titles/argv.

macOS `ps comm` can itself contain process-set argument strings. Original exact
reports remain in the private pre-publication Git archive.
"""
import gzip
import json
import re

PROCESS_KEYS = {'processes','ps','processinventory','processlist','processesbefore','processesafter',
                'processsnapshot','allprocesses','hostprocesses'}
TITLE_KEYS = {'command','comm','cmdline','commandline','argv','args','processtitle','executable'}
HARDWARE_IDS = {'serialnumber','serialnumbersystem','hardwareuuid','provisioningudid','platformuuid'}


def table(text, force=False):
    lines = text.splitlines()
    header = next((i for i,line in enumerate(lines)
                   if line.split() and line.split()[0] in ('PID','UID','USER')
                   and 'PID' in line.split() and any(x in line.split() for x in ('COMMAND','ARGS','COMM','NAME'))),None)
    if header is None:
        numeric = all(re.fullmatch(r'\s*(?:PID\s+%?CPU\s+RSS|[0-9.,+% -]+)\s*',line)
                      for line in lines if line.strip())
        return '[process titles omitted before publication]' if '--api-key' in text or (force and not numeric) else text
    fields = lines[header].split()
    try:
        pid_column = fields.index('PID')
        end = next(i for i,x in enumerate(fields) if x in ('COMMAND','ARGS','COMM','NAME'))
    except (ValueError,StopIteration):
        return '[process titles omitted before publication]'
    result = [' '.join(fields[:end])]
    for line in lines[header+1:]:
        parts = line.split()
        if len(parts)>pid_column and parts[pid_column].isdigit():
            # Keep only numeric metadata; even USER/TTY can be private context.
            result.append(' '.join(x for x in parts[:end] if re.fullmatch(r'[0-9.,+%-]+',x)))
    return '\n'.join(result)+'\n'


def clean(value, process_scope=False):
    if isinstance(value,dict):
        process_row = any(k.lower()=='pid' for k in value)
        result = {}
        for key,item in value.items():
            normalized = re.sub('[^a-z]','',key.lower())
            if normalized in HARDWARE_IDS:
                continue
            if process_row and normalized in TITLE_KEYS and isinstance(item,(str,list)):
                continue
            scope = process_scope or normalized in PROCESS_KEYS
            result[key] = clean(item,scope)
        return result
    if isinstance(value,list):
        return [clean(x,process_scope) for x in value]
    if isinstance(value,str) and process_scope:
        return table(value,force=True)
    return value


def redact_report(filename, contents):
    name = filename.decode('utf-8') if isinstance(filename,bytes) else str(filename)
    lower = name.lower()
    if not lower.startswith(('tests/reports/','reports/','evidence/','benchmarks/artifacts/')):
        return contents
    if lower.endswith(('.swift.txt','.py.txt','.cpp.txt','.patch')):
        return contents
    compressed = lower.endswith('.gz')
    try:
        raw = gzip.decompress(contents) if compressed else contents
        text = raw.decode('utf-8')
    except (UnicodeDecodeError,OSError,EOFError):
        return contents
    logical = lower[:-3] if compressed else lower
    updated = text
    try:
        if logical.endswith('.json'):
            data = json.loads(text)
            fixed = clean(data)
            if fixed!=data: updated=json.dumps(fixed,ensure_ascii=False,indent=2)+'\n'
        elif logical.endswith('.jsonl'):
            rows=[]; changed=False
            for line in text.splitlines():
                data=json.loads(line);fixed=clean(data);changed |= fixed!=data
                rows.append(json.dumps(fixed,ensure_ascii=False,separators=(',',':')) if fixed!=data else line)
            if changed: updated='\n'.join(rows)+'\n'
        elif logical.endswith(('.txt','.log')):
            updated=table(text)
    except (ValueError,TypeError):
        return contents
    if updated==text:
        return contents
    return gzip.compress(updated.encode(),mtime=0) if compressed else updated.encode()
