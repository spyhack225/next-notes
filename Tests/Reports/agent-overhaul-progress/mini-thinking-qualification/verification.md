# MiniCPM role-thinking qualification — 2026-10-05

Pinned existing MiniCPM5-2B-Q4_K_M.gguf (SHA256 ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd), fixture clock 2026-10-05T09:00:00-04:00, quiet M3 Air. No download, role/default change or candidate installation.

| Arm | Actual result | Elapsed seconds |
| --- | --- | --- |
| Installed b3b6e2d, baseline sampler, thinking OFF | 9/9/9; min/median/max 9 | 62.4/62.0/78.6 |
| Same installed binary, vendor sampler only | 5/5/5; min/median/max 5 | 49.6/49.2/75.9 |
| Reconciled vendor + role thinking candidate | INCOMPLETE/TIMEOUT; 6 passing of 10 attempted, no aggregate | 303.4 |

Baseline temperature .6/top_p .9/min_p .05 versus vendor 1/.95/0; repeat penalty 1.05, seed24301, window256. Installed binary SHA256 bc80eedfe65af6bd327d6d23f968177561d5f2315527175341d456289a131942; candidate129d52384dbf8303c024287376e6dd003090e9a6169c4106f883f8f16ef54822. Machine starts load1.89–3.47, swap4.75–5.33GiB, free10.70–12.04GiB; no competing model/build work.

The imported thinking foundation reproduced32 failures through actual native/protocol paths; corrected explicit voice-OFF precedence and existing tools overload scopes pass the unchanged regression plus chat-template, scripted notes-truncation, voice-scheduling, toolloop-production and store-isolation. All five native voice routes stay OFF; work/notes and both tools completion paths open thinking. Existing native prefix-cancellation checks remain green. This does not qualify notes quality, actual dictation tail, live voice latency or model/default promotion.

Activation rejected: thinking introduced M05/A02 answer failures and N04 timed out. Its stable runner refused an incomplete score and aborted remaining runs; no min/median/max was invented. Baseline F03 remains ungrounded. Vendor-only also introduces missed draft/meeting/browser/capabilities failures. The three measured arms do not replace the unchanged9/10 bar or full/owner gates. Notes reservation by display label remains an open source defect in the held candidate. No forced-cap/notes/physical latency acceptance.

Reviewed candidate patch retained outside iCloud; private Sources restored to b3. Full raw rounds, usage counts and logs: ~/Library/Caches/NextNotesBuild/toolloop-live/{mini-baseline-b3b6e2d-20261005,mini-vendor-only-b3b6e2d-20261005,mini-thinking-candidate-20261005}; native red/green, selection and withdrawal: integration/thinking-current-reconciliation. Own subprocess temporary roots removed after joins; model claim released. Obsolete original app removed210,120,272bytes; installed app retained. Prepared optional pinned notes and floor observations were not run after rejection.
