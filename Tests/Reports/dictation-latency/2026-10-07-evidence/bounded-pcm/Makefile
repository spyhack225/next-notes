SWIFTC := xcrun swiftc
SHARED := TranscriptionEngine.swift ParakeetInput.swift BoundaryTypes.swift PCMCheck.swift
check-original: Engine.original-probe.swift DictationSegmenter.original.swift $(SHARED)
	$(SWIFTC) -swift-version 6 -O $^ -o $@
check-fixed: Engine.candidate-probe.swift DictationSegmenter.candidate.swift $(SHARED)
	$(SWIFTC) -swift-version 6 -O $^ -o $@
check-prefix: Engine.prefix-candidate-probe.swift DictationSegmenter.original.swift $(SHARED)
	$(SWIFTC) -swift-version 6 -O $^ -o $@

check-combined: Engine.combined-candidate-probe.swift DictationSegmenter.candidate.swift $(SHARED)
	$(SWIFTC) -swift-version 6 -O $^ -o $@
