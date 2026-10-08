SWIFTC := xcrun swiftc
check: LockedBox.production.swift BoundedWait.production.swift SentenceChunker.production.swift IncrementalCleanup.production.swift OriginalResolver.swift CandidateResolver.swift ReadyHeadsCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
