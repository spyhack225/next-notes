SWIFTC := xcrun swiftc
check: SpokenForms.swift OriginalSpokenForms.swift FileReferences.swift OriginalFileReferences.swift ScreenContext.swift OriginalScreenContext.swift DictionaryCorrector.swift DictionaryEntry.swift Check.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
