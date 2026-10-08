SWIFTC := xcrun swiftc
check-original: LiveDictationText.original.swift ProbeTypes.swift TextCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
check-fixed: LiveDictationText.fixed.swift ProbeTypes.swift TextCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
