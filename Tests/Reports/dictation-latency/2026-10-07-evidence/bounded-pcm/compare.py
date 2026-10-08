import json,sys
from pathlib import Path
root=Path(__file__).parent
a=json.loads((root/sys.argv[1]).read_text());b=json.loads((root/sys.argv[2]).read_text())
ignore={"retainedBeforeFinish","peakRetainedSamples"}
errors=[]
for old,new in zip(a["cases"],b["cases"],strict=True):
    for row in (old,new):
        if row["failures"]:errors.append({"case":row["name"],"fixtureFailures":row["failures"]})
    for key in old.keys()|new.keys():
        if key not in ignore and old.get(key)!=new.get(key):errors.append({"case":old["name"],"field":key})
out={"caseCount":len(a["cases"]),"parityFailures":errors,"originalRetentionRequirementMet":a["retentionRequirementMet"],"candidateRetentionRequirementMet":b["retentionRequirementMet"],"retention":[{"case":x["name"],"oldPeak":x["peakRetainedSamples"],"newPeak":y["peakRetainedSamples"]}for x,y in zip(a["cases"],b["cases"],strict=True)],"scope":a["scope"]}
print(json.dumps(out,indent=2))
sys.exit(bool(errors))
