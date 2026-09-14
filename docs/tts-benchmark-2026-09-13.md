# TTS benchmark decision record

This is a bounded local evaluation for v3 milestone 8 and v4 §§19–20. It does not
change the production voice path. The harness is [Tools/tts_benchmark.swift](../Tools/tts_benchmark.swift)
and has no package or model dependencies beyond macOS AVFoundation.

## Host and inventory

Run date: 2026-09-13, macOS 26.5.2, arm64 Apple M3, 8 cores, 16 GB installed RAM.

| Engine | Local state | Benchmark state |
| --- | --- | --- |
| `AVSpeechSynthesizer` | en-US system voice available; no model download | measured below |
| Kokoro ONNX | no `kokoro`/`kokoro-onnx` command; no `kokoro`, `kokoro_onnx`, or `onnxruntime` Python module; no local Kokoro ONNX model/voice files | not run |
| Piper | no `piper`/`piper-tts` command; no `piper`, `piper_phonemize`, or `onnxruntime` Python module; no local Piper `.onnx` voice/config files | not run |

The FluidAudio build cache contains KokoroAne source files, but it contains no runnable
Kokoro ONNX model or voice pack, so it is not counted as an installed engine. No weights
were downloaded.

## Measurement method

Build and inventory:

```bash
swiftc -parse-as-library -O -framework AVFoundation -framework Foundation \
  Tools/tts_benchmark.swift -o /tmp/tts-benchmark
/tmp/tts-benchmark --engine inventory
```

`AVSpeechSynthesizer.write(_:toBufferCallback:)` is used so the timer ends at the first
non-empty generated PCM buffer. This is a generated-audio callback, not an acoustic
speaker measurement; the probe deliberately does not route audio to the speakers. CPU
is process user/system time from `getrusage`. Memory is process peak RSS. Interruptibility
calls `stopSpeaking(at: .immediate)` after the first buffer and waits for the write path
to become idle.

## Results

Short response (`I found three matching files...`, 5 trials, no interruption):

| Metric | Cold trial | Warm median (trials 2–5) |
| --- | ---: | ---: |
| first generated PCM buffer | 450.3 ms | 201.8 ms |
| full write completion | 473.7 ms | 224.0 ms |
| CPU user + system | 66.3 ms | 35.6 ms |
| peak RSS | 40.1 MB | 40.5 MB |

Long response (6 sentences, 3 trials, interrupt 50 ms after first buffer):

| Metric | Median | Range |
| --- | ---: | ---: |
| first generated PCM buffer | 202.9 ms | 197.7–368.9 ms |
| stop requested | 254.8 ms | 250.9–420.4 ms |
| stop-to-idle | 0.085 ms | 0.083–0.131 ms |
| CPU user + system | 152.1 ms | 148.0–177.1 ms |
| peak RSS | 40.5 MB | 40.3–40.5 MB |

The raw JSON reports were produced with:

```bash
/tmp/tts-benchmark --engine all --trials 5 --interrupt-after-ms 10000 \
  --output /tmp/ttsbench/apple-warm.json
/tmp/tts-benchmark --engine apple --trials 3 --interrupt-after-ms 50 \
  --text 'I found three matching files. The latest is enclosure version seventeen. I also checked the project folder and prepared a concise summary for the meeting. The selected file was modified this morning and is ready to open, upload, or share with the team. I will keep listening while you decide what to do next. Please tell me if you want the calendar event changed or the document opened in the browser.' \
  --output /tmp/ttsbench/apple-interrupt.json
```

## Decision and remaining validation

Apple system speech is the only engine measured on this Mac. It meets the v4 first-audio
target on warm runs at roughly 200 ms for this short clause and has measured immediate
write-path interruption, with about 40 MB peak RSS. This supports keeping the existing
Apple baseline as the shipping path while alternative engines remain an open evaluation.

This record does not claim Kokoro/Piper quality, CPU, RAM, or interruption results. To
close that comparison, install one engine and a compatible local voice/model, then rerun
the inventory and add an engine adapter to the harness. Acoustic speaker latency,
naturalness/listener quality, and barge-in through the real app audio route still require
a supervised device session.
