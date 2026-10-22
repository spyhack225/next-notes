#!/usr/bin/env python3
import subprocess,json
from pathlib import Path
here=Path(__file__).resolve().parent
models=[('openbmb/MiniCPM5-2B-GGUF/MiniCPM5-2B-Q4_K_M.gguf','minicpm','small'),('apple','apple','small'),('unsloth/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-Q4_K_M.gguf','qwen3','small'),('built-in/gemma-4-e4b','gemma','large')]
for model,label,size in models:
 for i in range(1,4):
  code=subprocess.call(['python3',str(here/'quick-one.py'),model,label,str(i),size])
  if code:
   (here/'matrix-stop.json').write_text(json.dumps(dict(label=label,run=i,exit=code))+'\n');raise SystemExit(code)
print('QUICK_MATRIX_MEASURED',flush=True)
