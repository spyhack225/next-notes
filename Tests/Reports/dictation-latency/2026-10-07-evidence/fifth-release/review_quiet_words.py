#!/usr/bin/env python3
"""Review explicit public dictation replay files; never call models or alter words.
WER is whole-script lexical edit distance; final clause is independently aligned
by the repository fixture generator, not inferred from recognizer punctuation.
No functional OK marker, reference WER or nonempty answer establishes word retention.
"""
import argparse, hashlib, json, pathlib, re
GOLD=pathlib.Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/dictation-bounded-pcm-20261008/quiet-final-whole-gold.txt')
WAV=GOLD.with_name('quiet-final-clause.wav')
PINS={'gold':'0b7465741fe4a5fb780a941f78d946935acb6e84bbd26d9d74205af3d5a19e2b','wav':'76c16c4ffd310a9e9b1b87841a8211a7ae738e92868b02b8141c578a1f726dc4'}
CLAUSE='Great, I will send the summary tonight.'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def words(s):return re.findall(r'[^\W_]+',s.lower(),re.UNICODE)
def distance(a,b):
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        current=[i]
        for j,y in enumerate(b,1):current.append(min(current[-1]+1,row[j]+1,row[j-1]+(x!=y)))
        row=current
    return row[-1]
def review(p,g):
    assert p.is_file(), 'required actual output absent: '+str(p)
    text=p.read_text(); hyp=words(text); ref=words(g); clause=words(CLAUSE)
    found=sum(hyp[i:i+len(clause)]==clause for i in range(max(0,len(hyp)-len(clause)+1)))
    return {'path':str(p),'sha256':sha(p),'referenceWords':len(ref),'hypothesisWords':len(hyp),'editDistance':distance(ref,hyp),'WER':distance(ref,hyp)/len(ref),'exactFinalClauseCount':found,'endsWithExactFinalClause':hyp[-len(clause):]==clause,'noDuplicatedClause':found==1,'normalization':'Unicode alphanumeric lowercase; punctuation/whitespace only, no lexical corrections'}
parser=argparse.ArgumentParser(); parser.add_argument('--asr-prefix',type=pathlib.Path); parser.add_argument('--polish-raw-prefix',type=pathlib.Path); parser.add_argument('--polish-final-prefix',type=pathlib.Path); parser.add_argument('--output',required=True,type=pathlib.Path); args=parser.parse_args()
assert sha(GOLD)==PINS['gold'] and sha(WAV)==PINS['wav']
gold=GOLD.read_text(); result={'scope':'Pinned whole public quiet input, actual replay outputs only; not microphone/paint/AX/concurrentASR+voice proof','pins':PINS,'reference':None,'engine':[],'coreRaw':[],'coreFinal':[],'fixedNativeAcceptance':False}
if args.asr_prefix:
    result['reference']=review(pathlib.Path(str(args.asr_prefix)+'.reference.txt'),gold)
    for suffix in ['.complete-file+300ms.txt','.complete-file.txt']: result['engine'].append(review(pathlib.Path(str(args.asr_prefix)+suffix),gold))
for prefix,key in [(args.polish_raw_prefix,'coreRaw'),(args.polish_final_prefix,'coreFinal')]:
    if prefix:
        for i in [1,2]:result[key].append(review(pathlib.Path(str(prefix)+f'.{i}.txt'),gold))
ref=result['reference']; tested=result['engine']+result['coreRaw']+result['coreFinal']
result['allRequestedOutputsKeepExactClauseOnce']=bool(tested) and all(x['endsWithExactFinalClause'] and x['noDuplicatedClause'] for x in tested)
result['completeNativeWordAcceptance']=bool(ref and len(result['engine'])==2 and len(result['coreRaw'])==2 and len(result['coreFinal'])==2 and ref['endsWithExactFinalClause'] and ref['noDuplicatedClause'] and result['allRequestedOutputsKeepExactClauseOnce'])
result['fixedNativeAcceptance']=False # timings/noise/normal/failure/ownership checks remain separate
args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'output':str(args.output),'completeNativeWordAcceptance':result['completeNativeWordAcceptance'],'allRequestedOutputsKeepExactClauseOnce':result['allRequestedOutputsKeepExactClauseOnce'],'fixedNativeAcceptance':False}))
raise SystemExit(0 if result['allRequestedOutputsKeepExactClauseOnce'] else 1)
