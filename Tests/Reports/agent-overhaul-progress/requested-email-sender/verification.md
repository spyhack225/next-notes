# Requested email sender — 2026-10-05

The default read producer discarded the explicitly named sender, authored in:inbox, and the existing argument grounder removed that unrequested inbox filter. The actual executor consequently read all fixture senders. The same producer now copies a literal sender from a complete simple sender question into from:"name". It guesses no address, unread status or freshness window; compound/topic/time requests stay with the planner.

Same original “Any new emails from Marcus?” and first raw reply: original seven assertion failures -> PASS. Real planner/executor/fixture mailbox returns the two Marcus messages and only that corpus reaches the final provider. General reads, recipient-only writes, compounds and clarification negatives pass. Capability manifest, tool review, live grader and owner isolation pass once.

Pinned MiniCPM5-2B baseline at Oct 5 09:00 New York now calls search_email(query=from:"Marcus") and reports both actual messages. Grader PASS; the reply calls the September 26 message “new,” so freshness interpretation remains unresolved. Full/owner and latency gates remain open.

Evidence: `~/Library/Caches/NextNotesBuild/integration/m02-requested-sender-floor/`. Bulk artifacts remain outside iCloud.
