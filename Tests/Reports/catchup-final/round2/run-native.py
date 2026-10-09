#!/usr/bin/env python3
# One foreground native child at a time. Called only inside heavy.sh.
import json, os, pathlib, shutil, subprocess, sys, time
binary, reports, runtemp, *flags = sys.argv[1:]
reports, runtemp = pathlib.Path(reports), pathlib.Path(runtemp)
records = []
failed = False
for flag in flags:
    print('Running ' + flag, flush=True)
    args = [binary, '--selftest-' + flag, '--selftest-out', str(runtemp / (flag + '.log'))]
    start = time.time()
    with (reports / (flag + '.log')).open('w') as output:
        child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT)
        status = child.wait()
    status = 128 - status if status < 0 else status
    end = time.time()
    line = f'{flag} EXIT={status}'
    print(line, flush=True)
    with (reports / 'exits.txt').open('a') as output: output.write(line + '\n')
    records.append(dict(flag=flag, pid=child.pid, args=args, start=start, end=end, exit=status))
    (reports / 'native-processes.json').write_text(json.dumps(records, indent=2) + '\n')
    log = runtemp / (flag + '.log')
    if log.exists(): shutil.copyfile(log, reports / 'selftest-out' / (flag + '.log'))
    if status != 0: failed = True
sys.exit(1 if failed else 0)
