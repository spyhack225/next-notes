# Speech engine benchmark

Apple's macOS 26 `SpeechTranscriber` vs NVIDIA's **Parakeet TDT 0.6B** running on the
Neural Engine, on the same audio, scored the same way.

Self-contained — it doesn't build or touch the Next Notes app.

```bash
cd bench
swift run bench record take1.wav          # talk, press RETURN
swift run bench run take1.wav             # transcribe with both, open dashboard
```

To score accuracy, write down what you actually said and pass it as the reference:

```bash
echo "the quick brown fox jumps over the lazy dog" > take1.txt
swift run bench run take1.wav --ref take1.txt
```

Flags: `--v2` (English-only Parakeet, higher recall), `--int4` (smaller/faster encoder).

Outputs `take1-results.json` and `take1-dashboard.html`, and opens the dashboard.

---

## Where the Parakeet model comes from

Parakeet is NVIDIA's ASR model, trained in their NeMo framework and published as PyTorch
weights. It can't run on the Neural Engine in that form.

**Fluid Inference** is an open-source project that converts frontier audio models to
**CoreML** and wraps them in a Swift SDK called **FluidAudio** — the same thing Argmax's
WhisperKit does for Whisper. They publish the converted weights on Hugging Face:

| | |
|---|---|
| Repo | [`FluidInference/parakeet-tdt-0.6b-v3-coreml`](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) |
| Base model | `nvidia/parakeet-tdt-0.6b-v3` |
| License | CC-BY-4.0 |
| Languages | 25 (English + European) |

Nothing but `curl` is needed to inspect it — the Hugging Face API is public and unauthenticated:

```bash
REPO=FluidInference/parakeet-tdt-0.6b-v3-coreml

# metadata
curl -s "https://huggingface.co/api/models/$REPO" | jq '{id, downloads, likes, pipeline_tag}'

# every file with sizes
curl -s "https://huggingface.co/api/models/$REPO/tree/main?recursive=true" \
  | jq -r '.[] | select(.type=="file") | "\(.lfs.size // .size)\t\(.path)"' \
  | sort -rn | head

# one file, directly
curl -L -O "https://huggingface.co/$REPO/resolve/main/Encoder.mlmodelc/weights/weight.bin"
```

The repo totals ~3 GB because it ships several variants of the same network — compiled
`.mlmodelc` bundles, the source `.mlpackage` form, and an INT4-quantized encoder.

**You don't download all of it.** Measured on a real first run, FluidAudio pulled exactly
four compiled models totalling **469 MB** into
`~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3/`:

| Component | Role | Weights |
|---|---|---|
| `Encoder.mlmodelc` | acoustic model (INT8) | 433 MB |
| `Decoder.mlmodelc` | transducer decoder | 23 MB |
| `JointDecisionv3.mlmodelc` | joint network | 12 MB |
| `Preprocessor.mlmodelc` | audio → mel features | <1 MB |

Note it takes the small `Preprocessor` rather than the 595 MB `MelEncoder`, and the INT8
encoder rather than the `.mlpackage` sources — which is why the download is a sixth of the
repo. Don't infer download size from repo size.

You never invoke any of this by hand — `AsrModels.downloadAndLoad(version: .v3)` fetches
and caches it. To pre-fetch or work offline, the official CLI mirrors the whole repo:

```bash
pip install -U "huggingface_hub[cli]"
hf download FluidInference/parakeet-tdt-0.6b-v3-coreml
```

Cache lands in `~/.cache/huggingface/`; FluidAudio's copy in
`~/Library/Application Support/FluidAudio/Models/`. Delete either to force a re-download.

---

## What's being measured

**Process seconds** — wall clock from "start transcribing" to final text. Model loading is
excluded, because the two are not comparable: Apple's models are resident in the OS, while
Parakeet pays a one-time load per process. Load time is reported separately.

**RTF** — audio seconds processed per wall-clock second. 100× means a 60-second clip
transcribes in 0.6s. Higher is faster.

**WER / CER** — word and character error rate against your reference, via Levenshtein
distance. Scored on *normalized* text: lowercased, punctuation stripped, whitespace
collapsed. This matters — Apple adds punctuation automatically, and against an unpunctuated
reference that would score as dozens of phantom errors and make the comparison worthless.
CER is included because WER counts a near-miss ("Kubernetes" → "cubernetties") as a wholly
wrong word, which overstates the damage for technical vocabulary.

### What this does *not* measure

Both engines run in **batch** here: whole file in, final text out. That's the fair way to
compare throughput, but it isn't how dictation feels.

`SpeechTranscriber` is natively streaming — with `.volatileResults` it shows words as you
speak, so perceived latency is near zero regardless of RTF. Parakeet's batch path can only
start after you stop talking. FluidAudio does offer `SlidingWindowAsrManager` for real
streaming, which would be the fair comparison for felt latency, but it's a different
measurement and isn't wired up here.

So: **RTF answers "which is faster at bulk transcription," not "which feels snappier
while dictating."** For a push-to-talk app where you release the key and wait, batch
latency is close to what you feel — but don't read these numbers as the whole story.
