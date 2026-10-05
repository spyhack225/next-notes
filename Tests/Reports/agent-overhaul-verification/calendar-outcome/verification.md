# Calendar identity and uncertain outcomes

The actual executor now derives the inserted event ID from the prepared action, reads that exact resource, and checks its reviewed title, dates, description and attendees. A duplicate ID alone supplies no success claim. A failed send is resolved by one exact read; unavailable or mismatched data stays uncertain. Rejected result persistence prevents successful delivery.

Original 420 failed 38/114 checks; fixed 421 passed the same 114. Identity original 426 failed 9/10; fixed 427 passed 10/10. Unknown-outcome original 434 failed 32/82 and post-read ownership 8/31; fixed 436 passed both unchanged sets. The 23 related flags passed. Earlier 5 ms/100 ms failures remain recorded; no live Google, crash durability or retry claim.

Raw evidence: `~/Library/Caches/NextNotesBuild/evidence/agent-overhaul-closure/p3-task-bridge-production/manager-voice-worker-ownership-production/` (calendar 420–436 records).
