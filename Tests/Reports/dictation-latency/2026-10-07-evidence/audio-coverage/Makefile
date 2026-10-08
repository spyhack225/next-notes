.PHONY: original candidate
original:
	xcrun swiftc -O -swift-version 6 -parse-as-library BoundaryTypes.swift TranscriptionEngine.swift ParakeetInput.swift DictationSegmenter.swift Engine.original-probe.swift AudioCoverageCheck.swift -o original-probe
	./original-probe > original.log
candidate:
	xcrun swiftc -O -swift-version 6 -parse-as-library BoundaryTypes.swift TranscriptionEngine.swift ParakeetInput.swift DictationSegmenter.swift Engine.candidate-probe.swift AudioCoverageCheck.swift -o candidate-probe
	./candidate-probe > candidate.log
