# Getting the speech model on Windows

Windows has **no equivalent to Apple's `SpeechAnalyzer`**. On macOS that framework ships with
the OS, manages its own model assets, and needs no download. There is nothing comparable on
Windows — so Parakeet is not the optional upgrade it is on macOS, it is the *only* engine.
The app cannot transcribe until these files are on disk.

This page is written to be followed by a person **or handed to a coding agent verbatim**.

---

## What you are downloading

**NVIDIA Parakeet TDT 0.6B**, converted to ONNX and quantized to int8, run through
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx).

| | |
|---|---|
| Download size | **~661 MB** |
| Working set once loaded | **~2 GB** — see [Memory](#memory) |
| Speed | ~40× real time on CPU (a 10 s utterance transcribes in ~250 ms) |
| Network | Needed **once**, for the download. Transcription is fully offline. |
| Licence | Model weights **CC-BY-4.0**; sherpa-onnx **Apache-2.0**. Commercial use permitted with attribution — see [Licence](#licence). |

Two variants. Pick one:

| Repo | Languages | `tokens.txt` |
|---|---|---|
| `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8` | **English only** | 1025 entries |
| `csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` | **25 languages** | 8193 entries |

**Default to v2** unless you dictate in something other than English. Same encoder size, same
speed; v3 simply carries a larger vocabulary.

---

## Where the files go

```
%LOCALAPPDATA%\Speechify\models\parakeet-v2\
    encoder.int8.onnx     ~652 MB
    decoder.int8.onnx     ~7 MB
    joiner.int8.onnx      ~1.7 MB
    tokens.txt            ~9 KB
```

The app looks here first, then next to the executable (`AppContext.BaseDirectory\models\`).
Settings → Model shows the resolved path and whether the files were found.

> **Do not put these inside the app folder if you install to `Program Files`.** That location
> needs administrator rights to write, so the app cannot download or update the model itself.

---

## Option A — PowerShell, no extra tools *(recommended)*

Nothing to install. Paste this into PowerShell:

```powershell
$dir = "$env:LOCALAPPDATA\Speechify\models\parakeet-v2"
$base = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/main"

New-Item -ItemType Directory -Force $dir | Out-Null

foreach ($f in "encoder.int8.onnx","decoder.int8.onnx","joiner.int8.onnx","tokens.txt") {
    Write-Host "Downloading $f ..."
    curl.exe -L --fail --progress-bar -o "$dir\$f" "$base/$f"
}

Get-ChildItem $dir | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}}
```

For **v3**, change `parakeet-v2` → `parakeet-v3` and `...-v2-int8` → `...-v3-int8`.

> **`curl.exe`, with the `.exe`.** Bare `curl` in PowerShell is an alias for
> `Invoke-WebRequest`, which is a different program. And if you do use
> `Invoke-WebRequest`, you **must** pass `-OutFile` — without it PowerShell buffers the
> whole 650 MB in memory.

Expected output:

```
Name                MB
----                --
decoder.int8.onnx   6.9
encoder.int8.onnx   622.0
joiner.int8.onnx    1.7
tokens.txt          0.0
```

---

## Option B — Hugging Face CLI

The command is **`hf`**. `huggingface-cli` is deprecated.

```powershell
pip install -U "huggingface_hub[cli]"

hf download csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 `
  --include "encoder.int8.onnx" "decoder.int8.onnx" "joiner.int8.onnx" "tokens.txt" `
  --local-dir "$env:LOCALAPPDATA\Speechify\models\parakeet-v2"
```

**No Hugging Face token is required.** These repositories are public. If you are prompted to
log in, you have a typo in the repo name.

---

## Option C — git

```powershell
git lfs install
git clone https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8
```

Clones extra files you don't need (fp32 weights, test audio) — roughly 3 GB. Fine if you
already have `git-lfs`; otherwise use Option A.

---

## Verifying it worked

```powershell
$dir = "$env:LOCALAPPDATA\Speechify\models\parakeet-v2"
$expect = @{
  "encoder.int8.onnx" = 652183000    # ±1 MB; exact size differs slightly between v2 and v3
  "decoder.int8.onnx" = 7257753
  "joiner.int8.onnx"  = 1739080
  "tokens.txt"        = 9384
}
foreach ($k in $expect.Keys) {
    $p = Join-Path $dir $k
    if (-not (Test-Path $p)) { Write-Host "MISSING  $k" -ForegroundColor Red; continue }
    $got = (Get-Item $p).Length
    $ok = [math]::Abs($got - $expect[$k]) -lt 2MB
    Write-Host ("{0,-20} {1,12:N0} bytes  {2}" -f $k, $got, $(if($ok){"OK"}else{"SIZE MISMATCH"}))
}
```

**A truncated download is the most common failure and it does not announce itself** — a
partial `encoder.int8.onnx` fails at model-load time with an opaque protobuf parse error.
Check the sizes before reporting a bug.

`tokens.txt` should be plain text, one `token id` pair per line, starting:

```
<unk> 0
▁t 1
▁th 2
```

---

## <a id="memory"></a>Memory: read this before choosing a machine

**The model needs roughly 2 GB of RAM resident, even for a two-second utterance.** That is
the int8 weights plus the inference runtime's memory arena — it is not a leak and it is not
specific to this app (the same footprint appears running the model from Python).

Measured peak working set by clip length:

| Audio | Peak RAM |
|---|---|
| 7 s | 2.0 GB |
| 60 s | 2.5 GB |
| 300 s | 4.3 GB |

**On an 8 GB machine, expect the app to be a noticeable tenant.** 16 GB is comfortable.

### The 400-second ceiling

The exported encoder carries a fixed relative-position table sized for **5000 frames**. At
80 ms per frame that is **400 seconds**, and beyond it inference *fails* rather than
degrading:

```
Non-zero status code returned while running Add node.
Attempting to broadcast an axis by a dimension other than 1. 126 by 5126
```

The app splits audio into 30–60 second segments on silence boundaries, so you will not hit
this dictating normally. It matters if you ever point the app at a long recording.

---

## Hardware and acceleration

**CPU only. This is deliberate, not a limitation we forgot to lift.**

- sherpa-onnx ships **no GPU package**. Setting a CUDA provider silently falls back to CPU.
- The DirectML runtime is five minor versions behind mainline, forbids parallel inference,
  and wants fixed tensor shapes — which this model, with its variable-length audio input,
  cannot provide.
- CUDA would force every user to install a matching CUDA toolkit.

None of it is worth it. Measured on CPU with int8 weights, transcription runs ~40× faster
than real time. Four threads is the sweet spot — eight measured *slower* than four.

**ARM64 Windows:** install the ARM64 build of the app. The x64 build runs under emulation
and transcription will be dramatically slower.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| "Model not found" | Files are in the wrong folder. Settings → Model shows the exact path being checked. |
| Protobuf / parse error on load | Truncated download. Re-run the size check above. |
| Loads, but every transcript is empty | Windows is blocking microphone access. Settings → Privacy & security → Microphone → **Let desktop apps access your microphone**. WASAPI returns *silence*, not an error, when this is off. |
| Very slow first transcription | Model load, ~2 s. Only on the first utterance after launch. |
| Consistently slow | You may be running the x64 build on an ARM64 machine. |
| Fails on audio over ~7 minutes | The 400-second ceiling above. |

---

## <a id="licence"></a>Licence and attribution

**Model weights: CC-BY-4.0.** Commercial use is permitted. If you redistribute the model
inside a product you must:

1. **Credit NVIDIA**, name the model, and link both the model card and
   <https://creativecommons.org/licenses/by/4.0/>.
2. **State that it was modified** — the int8 quantization and ONNX export are modifications.
3. **Add no further restrictions.** If your EULA forbids extracting bundled files, it must
   carve out the model weights.

A `THIRD-PARTY-NOTICES.txt` plus a line in the About box satisfies this.

**sherpa-onnx** is Apache-2.0. **ONNX Runtime** is MIT.

> Not legal advice. CC-BY-4.0 is a content licence rather than a software one and carries no
> patent grant. If you are shipping this commercially, have counsel confirm.

---

## For a coding agent

Minimum to reproduce a working setup:

```
Repo:    csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8   (HuggingFace, public, no token)
Files:   encoder.int8.onnx, decoder.int8.onnx, joiner.int8.onnx, tokens.txt
Target:  %LOCALAPPDATA%\Speechify\models\parakeet-v2\
NuGet:   org.k2fsa.sherpa.onnx 1.13.5
         org.k2fsa.sherpa.onnx.runtime.win-x64 1.13.5   (or .win-arm64)
```

Config that actually works — every field verified against a running transcription:

```csharp
var cfg = new OfflineRecognizerConfig();
cfg.FeatConfig.SampleRate  = 16000;
cfg.FeatConfig.FeatureDim  = 128;                  // NOT the default 80
cfg.ModelConfig.Transducer.Encoder = $"{dir}/encoder.int8.onnx";
cfg.ModelConfig.Transducer.Decoder = $"{dir}/decoder.int8.onnx";
cfg.ModelConfig.Transducer.Joiner  = $"{dir}/joiner.int8.onnx";
cfg.ModelConfig.Tokens     = $"{dir}/tokens.txt";
cfg.ModelConfig.ModelType  = "nemo_transducer";    // REQUIRED — omit it and loading fails
cfg.ModelConfig.NumThreads = 4;
cfg.ModelConfig.Provider   = "cpu";
cfg.DecodingMethod         = "greedy_search";
```

Four things that will cost an hour each if missed:

1. **`ModelType = "nemo_transducer"` is mandatory.** Without it the model will not load.
2. **`FeatureDim = 128`**, not the default 80.
3. **Set a `RuntimeIdentifier`** (`-r win-x64`). Without one, native libraries land in
   `runtimes/<rid>/native/` and you get `DllNotFoundException` at runtime.
4. **`WaveReader` is not in the NuGet package** — it's an example helper. Write your own WAV
   parsing, or feed `float[]` samples in `[-1, 1]` directly.

Audio must be **16 kHz mono float32**. On Windows, WASAPI shared mode will resample for you
if you request that format before opening the device.
