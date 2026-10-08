from pathlib import Path
import wave,array,math,json,hashlib,sys
root=Path("/Users/sergekadjo/Documents/Claude/Projects/speechify")
out=Path(__file__).parent
source=root/"Tests/Fixtures/meetings/en-dialogue.wav"
with wave.open(str(source),"rb") as w:
    assert w.getnchannels()==1 and w.getsampwidth()==2 and w.getframerate()==16000
    raw=w.readframes(w.getnframes())
audio=array.array("h");audio.frombytes(raw);assert sys.byteorder=="little"
def rms(fr):return math.sqrt(sum((v/32768)**2 for v in fr)/len(fr))
last=max(i+320 for i in range(0,len(audio)-319,320) if rms(audio[i:i+320])>=.01)
start=max(0,last-38400)
gain=.009/max(rms(audio[i:i+320]) for i in range(start,last,320))
tail=array.array("h",(round(v*gain)for v in audio[start:]))
assert max(rms(tail[i:i+320]) for i in range(0,len(tail)-319,320))<.01
files={}
for name,samples in {"quiet-final-clause.wav":audio[:start]+tail,"quiet-final-clause-alone.wav":tail}.items():
    p=out/name
    with wave.open(str(p),"wb")as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(samples.tobytes())
    files[name]={"samples":len(samples),"sha256":hashlib.sha256(p.read_bytes()).hexdigest()}
gold="\n".join(line.split(":",1)[1].strip() for line in (root/"Tests/Fixtures/meetings/scripts/en-dialogue.txt").read_text().splitlines() if ":" in line)+"\n"
(out/"quiet-final-whole-gold.txt").write_text(gold)
m={"source":"Public repository en-dialogue.wav, no owner audio","sourceSHA256":hashlib.sha256(source.read_bytes()).hexdigest(),"originalLastAboveFloorEndSamples":last,"quietStartsAtSample":start,"quietSpeechSeconds":(last-start)/16000,"gain":gain,"maxQuietFrameRMS":max(rms(tail[i:i+320])for i in range(0,len(tail)-319,320)),"allScriptWordsRetained":True,"goldScope":"Original complete independent script; no acoustic end derived from ASR output. Quiet-alone crop has no exact independent word alignment.","nativeVerdict":"pending","files":files,"goldSHA256":hashlib.sha256(gold.encode()).hexdigest()}
(out/"quiet-final-manifest.json").write_text(json.dumps(m,indent=2)+"\n")
print(json.dumps(m,indent=2))
