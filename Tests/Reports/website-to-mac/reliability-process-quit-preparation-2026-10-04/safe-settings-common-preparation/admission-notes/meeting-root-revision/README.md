# Exclusive private meeting-root admission — additive SAME COMMON

**HELD, off-source and uncompiled.** Apply after immutable base `admission-notes` and `selector-revision` COMMON patches, identically before both producer variants.

The prior pre-NSApp absent check and subsequent `MeetingStore.isolated(at:)` leave a gap: that existing store may reopen a directory that appeared in between. Foundation `FileManager.createDirectory` is idempotent for an already present directory, so it is not an exclusive gate. The revision calls POSIX `mkdir` once with mode 0700 at the exact admitted direct temporary UUID path immediately before the existing store. Any existing directory, file or dangling symlink returns nonzero and is INVALID; successful creation is checked against link resolution before the same `MeetingStore.isolated(at:)` opens it. No new store, map, wait or native owner is added.

This is not a general protection against concurrent hostile mutation after successful mkdir or around the model/metadata root. Parent must preserve the pre-owner validation, source-pinned copied-model inputs and no-concurrent-mutation staging contract. No compiler, native, original/fixed or filesystem race run occurred here.
