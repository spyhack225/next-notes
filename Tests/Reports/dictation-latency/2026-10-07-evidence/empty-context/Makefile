SWIFTC := xcrun swiftc
BUILD := /Users/sergekadjo/Library/Caches/NextNotesBuild/scratch/release
check: ScreenContext.candidate.swift OriginalScreenContext.swift Check.swift
	$(SWIFTC) -swift-version 6 -O -I "$(BUILD)" $^ "$(BUILD)/NextNotesDictionary.o" -o $@
