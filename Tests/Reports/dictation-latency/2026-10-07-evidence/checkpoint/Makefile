SWIFTC := xcrun swiftc
check-original: ComputeJob.swift ComputeScheduler.original-probe.swift CheckpointCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@
check-fixed: ComputeJob.swift ComputeScheduler.fixed-probe.swift CheckpointCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@

check-maintained-original: ComputeJob.swift ComputeScheduler.maintained-probe.swift MaintainedCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@

check-unicode-original: Rules.original-probe.swift UnicodeCheck.swift
	$(SWIFTC) -swift-version 6 -O $^ -o $@

check-unicode-debug: Rules.original-probe.swift UnicodeCheck.swift
	$(SWIFTC) -swift-version 6 -Onone $^ -o $@
