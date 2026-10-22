# App13 UI checkpoint

Pinned binary: 47921c5faff10a75d55c6dd760e6f8d78439ce5937abdd1892b0d2411376af57.

Functional UI/font gates passed. Experience72 images were created with isolation intact. The onboarding56-image diagnostic FAILED its unchanged store comparison; do not count it as an isolation pass. Its standard and Reduce-Motion-only images have a black content viewport; Reduce-Transparency images show content. Actual on-screen behavior and the store-change producer are unverified.

SettingsSheet is explicitly a live-store diagnostic, dispatched before self-test isolation. Its generated Settings images included live credential/account fields and saved text, so the root removed exactly its 36 newly generated images. No Settings PNGs or values are archived here. Its file-creation marker is not sanitized visual evidence. An isolated fixture producer is required for future shareable captures.

Current source may include later root-owned regression fixtures; source-manifest.json pins this binary's source inputs.
