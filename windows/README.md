# Speechify for Windows

The Windows port of Speechify — push-to-talk dictation, on-device.

> **Status: feature-complete, never run on real hardware.** Every layer exists and CI
> builds, tests and publishes a working single-file executable that starts and passes its
> own self-test on Windows. What has *not* happened is a human holding the key and speaking
> into a real microphone — see [Honesty](#honesty).

---

## Why this is a rewrite, not a port

Almost every layer of the macOS app is Apple-specific:

| Layer | macOS | Windows |
|---|---|---|
| UI | SwiftUI | Avalonia |
| Audio capture | `AVAudioEngine` | WASAPI via NAudio |
| **Default speech engine** | `SpeechAnalyzer` (ships with macOS 26) | **nothing equivalent exists** |
| Parakeet | FluidAudio → CoreML | sherpa-onnx → ONNX Runtime |
| Hotkey | `CGEventTap` | `SetWindowsHookEx(WH_KEYBOARD_LL)` |
| Text injection | Accessibility API | `SendInput` |

The consequence that shapes everything: **Windows has no counterpart to Apple's
`SpeechAnalyzer`.** On macOS, Parakeet is the optional upgrade. On Windows it is the only
engine, and the app cannot transcribe until the model is downloaded —
see [`docs/PARAKEET-WINDOWS.md`](../docs/PARAKEET-WINDOWS.md).

What *is* genuinely shared is the dictionary's behaviour, and it is shared as a contract
rather than as code: [`shared/dictionary-test-vectors.json`](../shared/dictionary-test-vectors.json).
Both implementations run those vectors in CI. Changing correction semantics starts there.

---

## Decisions, and why

**Avalonia, not WPF or WinUI 3.** WPF cannot be run or UI-tested on macOS, so every mistake
would cost a full CI round-trip. Avalonia's headless test platform runs on macOS in ~100 ms,
including simulated keyboard input and real pixel capture. Win32 interop is unaffected —
hooks, `SendInput` and WASAPI are P/Invoke, not UI-framework code. WinUI 3 was rejected
outright: Microsoft's own docs contradict each other on whether unpackaged single-file
publishing works, with open bugs reporting an exe that won't launch.

**.NET 10, not .NET 8.** .NET 8 reaches end-of-life on **2026-11-10**.

**Right Ctrl is the default hotkey, not Right Alt.** Right Alt is AltGr on German, Polish,
UK, Nordic and most Latin-American layouts — it is how those users type `@`, `€`, `\`, `|`.
Binding push-to-talk there would break basic typing for a large fraction of users. Right
Ctrl produces no character on any layout.

**The hotkey is observed, never swallowed.** The macOS build consumes Right Option because
on macOS that key types characters. On Windows, suppression buys nothing and risks a much
worse failure: if the key-down is swallowed but the key-up escapes — a hook that timed out
mid-gesture, or focus crossing into an elevated window — the target app believes Ctrl is
held down forever.

**CPU-only inference.** sherpa-onnx ships no GPU package; DirectML is five versions behind
and forbids the variable tensor shapes this model requires; CUDA would force every user to
install a toolkit. On CPU with int8 weights, transcription runs ~40× faster than real time.

**Three pinned versions that would break at "latest":**

| Package | Pinned | Why |
|---|---|---|
| `NAudio` | **2.3.0** | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | **11.3.20** | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime; never also reference `Microsoft.ML.OnnxRuntime` |

---

## Layout

```
windows/
├─ Directory.Build.props          strict analysis, applied to every project
├─ Directory.Packages.props       central version pinning
├─ global.json                    SDK pin
├─ src/
│  ├─ Speechify.Dictionary/          corrections + biasing          net10.0
│  ├─ Speechify.Abstractions/        the four platform interfaces   net10.0
│  ├─ Speechify.Core/                engine, segmenter, storage     net10.0
│  ├─ Speechify.Speech/              Parakeet via sherpa-onnx       net10.0
│  ├─ Speechify.Testing/             fakes for the interfaces       net10.0
│  ├─ Speechify.App/                 Avalonia UI                    net10.0
│  └─ Speechify.Platform.Windows/    the ONLY Win32 code            net10.0-windows
└─ tests/
   ├─ Speechify.Dictionary.Tests/    the shared vectors             24 tests
   ├─ Speechify.Core.Tests/          engine, chunking, storage      26 tests
   └─ Speechify.App.Tests/           headless Avalonia UI           13 tests
```

**Only one project targets `-windows`.** Everything else is platform-neutral, so `CA1416`
turns an accidental Win32 call into a build error — and, more usefully, the whole app
builds, runs and tests on macOS.

`Speechify.App` loads the platform layer **by reflection** rather than referencing it. A direct
reference would drag the UI onto `net10.0-windows` and destroy the local loop. The published
self-test verifies that reflection works from inside the single-file bundle, because that is
where the arrangement would otherwise fail — silently, at the moment the user first pressed
the key.

Keeping the platform layer logic-free is deliberate: anything that lives there is code CI
cannot exercise. Retries, debouncing, device-change handling all belong in the neutral
projects, behind an interface.

---

## Building

**On Windows** — everything, including the platform layer:

```bash
cd windows
dotnet build Speechify.sln --no-incremental -warnaserror
dotnet test  Speechify.sln
```

**On macOS or Linux** — use the solution filter. `Speechify.Platform.Windows` targets
`net10.0-windows` and cannot compile off Windows; the filter omits it and everything else
builds and tests normally, including the full UI suite:

```bash
cd windows
dotnet test Speechify.CrossPlatform.slnf -c Release      # ~0.5s, 63 tests
```

`--no-incremental` is not optional in CI. Roslyn does not re-emit analyzer warnings on an
incremental build, so `-warnaserror` would pass on cached results and prove nothing.

---

## <a id="honesty"></a>Honesty about what is verified

**Verified, on Windows, every push:** 63 tests pass — 24 dictionary (the shared vectors),
26 core (dictation state machine, audio chunking, all three storage formats), 13 headless
Avalonia UI. CI then publishes a self-contained ~116 MB executable, **runs it**, and the
binary reports back that the dictionary works, the source-generated JSON round-trips, and
the Windows platform layer loads and constructs out of the bundle.

**Verified on macOS, in ~0.5s:** the same 63 tests. The UI genuinely runs headless here,
which is why bugs like a `Render` method mutating a property get caught while writing them
rather than three CI round-trips later.

**Known divergences between the two regex engines**, measured across 30 cases — 9 differed.
The two that affect this code are both handled: culture-sensitive case-insensitive matching
(fixed by `CultureInvariant`) and NFC/NFD mismatch (fixed by normalizing both sides). Two
that are *not* fixable are simply avoided: ICU folds `ß` to `ss` and .NET does not, and
.NET's `.` splits surrogate pairs. Neither is reachable from the patterns this code builds.

**Cannot be verified anywhere but a real machine:**

- Text injection into a foreground app. Runners have an interactive desktop but cannot take
  the foreground.
- A real microphone: device format negotiation, the OS microphone-privacy block, unplugging
  mid-capture.
- The low-level keyboard hook actually firing on a physical keypress.
- Parakeet transcribing real speech, and whether the ~2 GB working set is tolerable.

Everything those depend on is behind an interface and exercised with fakes, so the logic
around them is tested. The bindings themselves are not.
