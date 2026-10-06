# Complete rendered evaluation replies — 2026-10-06

Confirmed report-producer defect: JSON exported only 300 characters of the final reply and omitted earlier rendered replies. Complete model raw rounds cannot always reconstruct the rendered text. The existing reportRows seam now retains the full final reply and all per-turn replies; production rendering, model, prompts and grading inputs are unchanged.

The same long, distinct Unicode rendered replies fail the original actual reportRows→JSON assertion and pass after the fix. Existing complete raw-round/pin/clock controls remain green. Shared original build has one report failure and four independent M03 misclassifications; fixed build passes the entire grader, production tool loop, capability manifest and store isolation (21 files/32 defaults unchanged). All child temporary roots removed.

Raw results/logs: ~/Library/Caches/NextNotesBuild/integration/full-final-report/{original-result.json,fixed-result.json}. This repairs the instrument; unavailable historical rendered suffixes are not reconstructed and no broader product/model/phase acceptance is claimed.
