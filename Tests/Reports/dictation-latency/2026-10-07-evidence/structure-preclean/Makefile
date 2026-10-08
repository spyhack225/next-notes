COMMON := Rules.production.swift SpokenStructure.production.swift SentenceChunker.production.swift OutputProfile.production.swift PrefixContract.production.swift LockedBox.production.swift StructurePrecleanCheck.swift
check: $(COMMON) IncrementalCleanup.production.swift
	xcrun swiftc -swift-version 6 -O $^ -o $@
check-group: $(COMMON) IncrementalCleanup.group-candidate.swift
	xcrun swiftc -swift-version 6 -O -D GROUP_PREPARE $^ -o $@
check-boundary: $(COMMON) IncrementalCleanup.group-candidate.swift SourceBoundaryCandidate.swift
	xcrun swiftc -swift-version 6 -O -D GROUP_PREPARE -D PRESERVE_BOUNDARIES $^ -o $@
