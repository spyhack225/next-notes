#!/usr/bin/env python3
import os,subprocess,json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
env=dict(os.environ,NEXTNOTES_APP='/Users/sergekadjo/Library/Caches/NextNotesBuild/bakeoff-app/NextNotes-503e0e40.app')
models=[('unsloth/Qwen3.5-4B-GGUF/Qwen3.5-4B-Q4_K_M.gguf','qwen35-clone','small'),('apple','apple-clone','small'),('openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf','minicpm-clone','small'),('built-in/gemma-4-e4b','gemma-clone','large'),('unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf','qwen3-clone','small')]
for model,label,size in models:
    for i in range(1,4):
        code=subprocess.call(['python3',str(root/'evidence/2026-10-09/quick-one.py'),model,label,str(i),size],env=env)
        if code:
            (root/'evidence/2026-10-09/matrix-stop.json').write_text(json.dumps({'label':label,'run':i,'exit':code})+'\n')
            raise SystemExit(code)
print('QUICK_MATRIX_MEASURED',flush=True)
