SWIFTC := xcrun swiftc
check-original: DictationSegmenter.original.swift ProbeTypes.swift EnergyCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
check-fixed: DictationSegmenter.fixed.swift ProbeTypes.swift EnergyCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
