# Raw selector correction — additive SAME COMMON

**HELD, off-source and uncompiled.** This relative patch applies after the immutable `admission-notes` COMMON new-file patch. It changes no Settings producer or test assertion.

The frozen fixture incorrectly tied `isRequested` to `SelfTest.requested`. A raw `--native-notes-settings-case` on a malformed/wrong test launch could then make the MeetingDiarizer diagnostic branch fall through to ordinary owner `modelsRoot`. The revised selector recognizes raw flag presence, so that branch stays confined and returns false on failed binding. The actual admission validator separately requires exact `--selftest-native-termination`, its explicit mode/model flags, direct temporary root and empty metadata directory. The parent SelfTest launch parser must reject the raw Notes-settings flag without the exact native test **before any owners are constructed**. Its normal mode must never read an owner model directory as a diagnostic fallback.

This is a source contract correction. Original/fixed paired COMMON composition, compiler check, malformed-launch controls, actual model/native/Cocoa flow, and owner-store isolation are UNRUN. Frozen base manifest `6e6573f2f800c5247006789a90dc7ddfffb3436e2f5b6ddbcf8fdc431d70bb26` remains unchanged.
