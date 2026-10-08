SHARED := AudioConversion.swift TranscriptionEngine.swift ParakeetInput.swift EngineBoundaryTypes.swift PerPassZeroCheck.swift DictationSegmenter.candidate.swift
original: Engine.sixth-before-probe.swift $(SHARED)
	xcrun swiftc -swift-version 6 -O $^ -o $@
candidate: Engine.per-pass-candidate-probe.swift $(SHARED)
	xcrun swiftc -swift-version 6 -O $^ -o $@
