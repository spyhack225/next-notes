# App 12 onboarding full-shell visual review

2026-10-01. Read-only inspection of all **28** existing PNGs in
`/tmp/sheets/setup-app12`. Installed executable SHA-256 supplied by the serial
integration owner:
`a35a883bee7666030975ee28960ca62cf958c9a158be71978b8254f2490b488c`.
The owner reported packaged font identity checks, `ONBOARDING_OK` and
`ONBOARDING_SHEET_OK: 28`. This inspection ran no application or native test.
Current sources have later theme edits and are not certified by these images.

## Observed failure: standard captures obscure the entire step

All **14 standard** images contain a large opaque black rectangle at the step
scroll viewport. The shell, titlebar circles, chevrons, footer button and progress
dots render around it. Headings, grant controls, practice and the example card
are obscured and cannot receive visual sign-off from those captures.

For example, `onboarding-dictation-allowed-standard.png` has a solid rectangle
at approximately `(260,112)–(1180,1018)` in its 1440×1264 PNG: **833,520 exact
black pixels**. Files/meetings have a slightly shorter viewport, **783,840 exact
black pixels**. Welcome and not-allowed dictation contain a small amount of text
at the viewport edge, but the same broad occlusion remains. This is an actual
image-output failure, not a demonstrated live app black-screen failure.

The renderer uses an offscreen `NSWindow`/`NSHostingView` and native
`cacheDisplay`; it never orders the window on screen. Standard production cards
use native glass; the reduced variant uses the solid fallback. The diagnostic
also switches **Reduce Motion and Reduce Transparency together**, so these
images cannot isolate glass/offscreen compositing from motion/render readiness.
That explanation remains a hypothesis; this worker did not reproduce a faulty
producer beyond the retained PNG output or apply a workaround.

`ONBOARDING_SHEET_OK: 28` currently establishes file generation and unchanged
watched stores. It does **not** establish that the images contain readable step
content. Keep the original standard images as failed visual evidence.

## Reduced captures: readable content and intact primary footer

All **14 combined Reduce Motion + Reduce Transparency** images display actual
step content. All images are 1440×1264 pixels: 720 pt window width, 600 pt content
height plus the native titlebar at 2× scale. No primary footer action, navigation
chevron or progress dot is clipped in either variant. Footer buttons are gray
with readable dark labels in these offscreen images; that is a pixel observation,
not proof of enabled state, focus, or the desired active black pill treatment.

For the table below each filename exists for both `{allowed,not-allowed}`.

| Actual reduced filename pattern | Observation at initial scroll position |
|---|---|
| `onboarding-welcome-{allowed,not-allowed}-reduced.png` | Sans headline with serif accent, explanatory copy, name field and generated face card are legible. The new **“No account, no sign-in…” reassurance is partly cut off at the scroll viewport bottom**, beneath the name/face card. It is not readable up front in this captured minimum-size state. Get started remains fully visible below the viewport |
| `onboarding-dictation-{allowed,not-allowed}-reduced.png` | Heading and both permission rows fit. Allowed checkmarks render; not-allowed Allow buttons and the plain explanation that dictation will not work yet are visible. Continue is intact |
| `onboarding-shortcut-{allowed,not-allowed}-reduced.png` | Both shortcut pickers and the “Try it now” practice card fit. Allowed fixture shows placeholder hold-key instruction; not-allowed fixture shows the grant prerequisite clearly. No real field insertion or success badge is exercised by this screenshot |
| `onboarding-brain-{allowed,not-allowed}-reduced.png` | Heading, Mac-local explanation, progress bar and “Carry on — this finishes in the background” fit with ample whitespace. Captured progress is fixture input, not an actual download or readiness proof |
| `onboarding-files-{allowed,not-allowed}-reduced.png` | Three folder rows, switches and Add a folder fit. Continue and Skip are fully visible |
| `onboarding-meetings-{allowed,not-allowed}-reduced.png` | All three grant rows fit and wrap naturally. Allowed checkmarks or not-allowed Allow buttons are legible. Continue and Skip fit. The fixture suppresses the actual next calendar event, so this does not review the newly implemented proactive event card |
| `onboarding-allSet-{allowed,not-allowed}-reduced.png` | Both outcome headings and their actual explanatory rows fit. The **EXAMPLE** label, explanation, Approve/Edit/Cancel are visible and readable. In the not-allowed case the “Open Next Notes when I log in” row is partly below the initial scroll viewport. Done remains intact. Scrolling to that setting and using any example action were not exercised |

The scrolling viewport correctly separates longer content from the fixed footer;
partly visible nonprimary lower content is not evidence that the footer overlaps
it. The welcome reassurance does need a producer/layout review because the
explicit onboarding reference requirement places that reassurance **up front**.
Move or compact its production presentation only after reproducing the current
minimum-size step; do not hide text or reduce type merely to force the entire
welcome into one frame. No source fix was made by this worker.

No heading, permission label, practice label or example action was observed
clipped in the readable reduced images. This is visual inspection at one
captured text size, not measured contrast-ratio, larger-text, keyboard, VoiceOver,
scroll, click, focus-restoration, animation, real practice or first-value proof.

## Smallest producer investigation for the standard failure

1. Keep the exact app12 input and failed original standard PNG. Separate
   Reduce Motion-only and Reduce Transparency-only in a bounded diagnostic
   capture of one actual step before multiplying the whole matrix. The current
   paired accessibility axis cannot identify the responsible branch.
2. Compare the same actual production step through a supported native on-screen
   capture if access succeeds. If live content is fine and only offscreen glass
   fails, fix or label the **capture producer**; do not replace production glass,
   add a sleep, or make the diagnostic force reduced transparency while calling
   it a standard visual pass. If live content also fails, trace its actual rendering
   producer and verify the original flow after repair.
3. Make image acceptance truthful: a missing image, an unreadable/occluded
   viewport, or unsupported glass capture must be reported as failure/unverified
   instead of treating count28 as content acceptance. A diagnostic image guard
   can reject the observed broad opaque viewport, but it does not itself repair
   production rendering or prove every step is correct.

## Review artifacts and identities

Contact sheets created only from the existing local PNGs, without altering originals:

- `/tmp/sheets/setup-app12-review/allowed-standard.png`
- `/tmp/sheets/setup-app12-review/not-allowed-standard.png`
- `/tmp/sheets/setup-app12-review/allowed-reduced.png`
- `/tmp/sheets/setup-app12-review/not-allowed-reduced.png`

All four sheets were inspected using `view_image`; original welcome, shortcut,
allowed all-set reduced and allowed dictation standard were additionally inspected
at original resolution. Pixel counts above came from local Pillow/NumPy reads,
not image editing or a new application capture.

| Original PNG | SHA-256 |
|---|---|
| `onboarding-dictation-allowed-standard.png` | `127fbdfb8d1e3026f8014096f0da58cc0ee557f16d6679b397ac4aaf6bbd2f27` |
| `onboarding-welcome-allowed-reduced.png` | `6cb6f69b696e3132c1ccef2277a1c05e0e565a8df2262e994c7278c791ed2a85` |
| `onboarding-shortcut-allowed-reduced.png` | `16ae03df400f058d9cd8a935b60e252cec296379af5b9fea727065d03250482d` |
| `onboarding-allSet-allowed-reduced.png` | `6ecc0245cf1e892f81f0e4875429602c92ff6ab02007b1ed46489a985323d0b5` |
| `onboarding-allSet-not-allowed-reduced.png` | `b82ab754a927ee4cc337246ed1b548d7f5c98b9c38fbeff7e8b7d78c8284dfa4` |

No Swift, build/native slot, owner data, preferences or STATUS was changed.
**Visual verdict: reduced layouts reviewed with the limitations above; standard
content blocked by confirmed capture occlusion; onboarding visual closure remains open.**

## Primary API context for the next producer investigation

Apple describes cacheDisplay as drawing a view and descendants into a compatible,
initialized bitmap. It does not document that result as an onscreen window-server
frame. [NSView.cacheDisplay documentation](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)).

Apple explicitly limits ImageRenderer to SwiftUI drawing primitives and excludes
many Core Animation-composited native controls/containers. Switching renderers
would therefore not establish equivalent full-shell proof.
[ImageRenderer documentation](https://developer.apple.com/documentation/swiftui/imagerenderer).

The Liquid Glass documentation describes capturing custom content into its effect
container and sampling surrounding content. That makes compositing a plausible
investigation target, **not a confirmed explanation** for these PNGs.
[Applying Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).
The independent Reduce Motion/Transparency diagnostic is now implemented for the
next build; no production material was disabled to obtain readable screenshots.

## Current invariance trace (pending installed verification)

The original app13 setup diagnostic creates56 independent motion/transparency images and then reports `ONBOARDING_SHEET_FAILED: owner stores changed`. This remains an isolation failure with an unconfirmed writer. The serial owner has integrated checkpoints around actual shell construction, hosting/layout, capture, close and image writing. The original baseline and assertion are unchanged; no warm-up or assertion narrowing is used.

The first proposal could expose values through `SelfTestStoreGuard.diff` for appeared/disappeared preferences. The integrated trace uses changed key names and types only, not that value-bearing formatter. It compares merged defaults, supported app/global persistent domains, and registration/argument volatile domains separately, plus watched file/folder metadata. It cannot enumerate all persistent domains with the current SDK. Two diagnostic builds failed SDK spelling; the supported helper now typechecks, but that is neither an installed trace result nor a fixed setup regression. The responsible producer remains open until the original installed flow supplies evidence.

## Installed app17 trace: first incorrect verifier decision

App17 SHA `0ee52308a47c409b115d0a0050719a5476c08a9132cf336fe053b185b83cb85c` retains the strict original assertion and fails after56 captures. The first delta is immediately after native window construction, before hosting the step: `METAL_DEVICE_WRAPPER_TYPE` appears in registration and merged defaults only. The trace reports no app/global persistent-domain delta, and watched folder bytes/hash remain identical. Exact logs and source manifest are in `app17/`.

The verifier currently treats any merged-default change as an owner-store mutation. Apple's API documentation identifies registration defaults as volatile and recreated per process; persistent-domain reads exclude volatile defaults. That explains why the current error is a false attribution of the traced registration event to durable owner data. [Apple registration defaults](https://developer.apple.com/documentation/foundation/userdefaults/register(defaults:)), [persistent-domain lookup](https://developer.apple.com/documentation/foundation/userdefaults/persistentdomain(forname:)).

A repair belongs to the diagnostic's comparison contract, while retaining full owner app/global persistent keys, watched file/preferences and folder invariance. The original failure remains preserved. No registration warm-up, blanket exception or offscreen glass workaround has been applied. Actual on-screen composition and first-success interaction remain separate open gates.

## Bounded verifier repair integrated for the next serial build

With the runtime owner's explicit source-only handoff, `OnboardingSheet` now compares complete app/global persistent domains, the original watched files/preferences, and folder bytes plus presence. The original merged/volatile trace and baseline remain in place. No Metal-key exception is used.

The actual comparator receives a negative test from a UUID-key write in the existing isolated harness preference domain; it must reject that persistent addition and accept an otherwise identical snapshot containing only a registration default. The exact prior harness domain is restored, and owner app/global domains are never written. Source SHA `5010b47a5eafa5e17f07e8578890b33a56fea56c34d1684a2c5413d74c44dbdd` is frozen for serial verification. Native execution and after-verification remain pending. App18 failed a separate worker fixture's SDK/type contract and was not installed; the original app17 red trace remains preserved.

## Installed app19 after-verification

App19 SHA `43d80d8ce964b491f0462c47c257b870d19b180a529962761a64bc1c7fd38366` passes the actual persistent-write negative and generates56 shell previews without durable owner-store changes. Exact executed source and logs are archived in `app19/`. The original app17 failure remains preserved.

The current welcome standard PNG still has an opaque black step viewport; the Reduce Transparency PNG is readable and includes the complete no-account reassurance, identity card and footer. Only these two current previews were reviewed here. Image generation and the repaired verifier pass; standard composition, all-step visual acceptance, physical first success, keyboard and VoiceOver remain open.
