SWIFTC := xcrun swiftc
check-original: IncrementalCleanup.original-probe.swift SentenceChunker.swift ProbeTypes.swift PrecleanCheck.swift
	$(SWIFTC) -swift-version 6 -O -D PRECLEAN_PROBE $^ -o $@
check-fixed: IncrementalCleanup.fixed-probe.swift SentenceChunker.swift ProbeTypes.swift PrecleanCheck.swift
	$(SWIFTC) -swift-version 6 -O -D PRECLEAN_PROBE $^ -o $@
check-maintained: IncrementalCleanup.maintained-production.swift SentenceChunker.swift ProbeTypes.swift MaintainedCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
