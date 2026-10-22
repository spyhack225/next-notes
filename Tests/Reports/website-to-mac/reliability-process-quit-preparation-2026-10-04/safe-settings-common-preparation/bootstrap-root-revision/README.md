# Additive SAME COMMON bootstrap/root corrections

OFF-SOURCE / UNCOMPILED. Frozen base/selector/App packets unchanged. Both producer versions require these additive COMMON patches. This modifies no canonical file and runs no diagnostic, native model, asset scan, preference access or owner app.

The App entry patch recognizes the raw selector before usage/report/ACP/normal routes and requires exact native grammar. Detailed admission still happens before explicit NSApplication/AppDelegate. Together with the peer's raw-selector getter branch, missing/wrong named diagnostics cannot silently fall back to the owner metadata root.

The private meeting-root patch prevents the general MeetingStore.isolated(at:) reopening seam from accepting a directory which appeared after earlier absence validation. It exclusively creates the exact direct canonical temp UUID path with Darwin mkdir before opening that SAME existing store. EEXIST (including a preexisting file/directory/link) refuses rather than reopening. No second store, custom constructor, restored history seed or owner path is introduced. Post-create metadata must be a canonical non-symlink directory. This is not atomic filesystem CAS against replacement after creation; passive immutable fixture inputs remain required. Source-only assurance cannot substitute for actual path-mutation/refusal controls.

The exclusive primitive is based on Apple's mkdir contract (success0, existing named entry EEXIST): [Apple mkdir manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/mkdir.2.html). No syscall was executed here; only relative text candidates were generated. Swift Darwin signature/typecheck remains UNRUN. Failure is before private tuple mounting/backend/native admission, so exact-mode handleArmFailure must exit INVALID rather than invoke generic/shared quit. After mounted native work, the qualified private drain remains required.

Parent composition must apply base App + base admission/fixture + selector revision before these patches and verify exact postimages. Real Settings producer differs ONLY under FIXED. No original/native crash/fast quit claim follows.
