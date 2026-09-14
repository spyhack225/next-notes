# TTS benchmark decision record

This is a bounded local evaluation for v3 milestone 8 and v4 §§19–20. It does not
change the production voice path. The harness is [Tools/tts_benchmark.swift](../Tools/tts_benchmark.swift)
and has no package or model dependencies beyond macOS AVFoundation.

## Host and inventory

Run date: 2026-09-13, macOS 26.5.2, arm64 Apple M3, 8 cores, 16 GB installed RAM.

| Engine | Local state | Benchmark state |
| --- | --- | --- |
| `AVSpeechSynthesizer` | en-US system voice available; no model download | measured below |
| Kokoro ONNX | isolated cache: `kokoro-onnx` 0.4.7, `kokoro-v1.0.onnx`, `af_sarah` voice | measured below; not part of the app |
| Piper | isolated cache: `piper-tts` 1.8.0, `en_US-lessac-medium` voice | measured below; not part of the app |

The alternative runners and weights were installed under
`~/Library/Caches/NextNotesTTS/`; nothing was copied into the repository or the installed
app. Kokoro uses the [kokoro-onnx runner](https://github.com/thewh1teagle/kokoro-onnx)
and its v1.0 release assets; Piper uses [OHF-Voice/piper1-gpl](https://github.com/OHF-Voice/piper1-gpl)
and the [`rhasspy/piper-voices` model](https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_US/lessac/medium)
for `en_US-lessac-medium`.
The downloaded files were verified in the cache with SHA-256: Kokoro model
`7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5`, Kokoro voices
`bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d`, Piper model
`5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f`, and Piper config
`efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0`.

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

Kokoro was measured through `Kokoro.create`, which returns one complete NumPy buffer and
therefore cannot report an earlier streaming callback; its first-audio value below is the
full generation time. Piper was measured through `PiperVoice.synthesize`, which yields
PCM chunks and reports the first yielded chunk separately. Both alternative probes used
the same five-sentence text as the Apple long-response run, with one cold model load and
four warm generations. They did not route audio to the speakers or claim acoustic
interruptibility.

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

Alternative-engine measurements (Python 3.14.6, arm64, same host):

| Engine / model | Cold load | Warm first generated PCM | Warm completion | Warm CPU | Peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Kokoro ONNX v1.0 / `af_sarah` | 761 ms | 3.2–3.4 s* | 3.2–3.4 s | 11.2–12.1 s | 862 MB |
| Piper 1.8.0 / `en_US-lessac-medium` | 592 ms | 98–109 ms | 420–476 ms | 1.48–1.58 s | 241 MB |

\* Kokoro's API is whole-buffer only, so its first-PCM number is not comparable to a
streaming callback. Repeated Kokoro generation also grew the probe's peak RSS from about
662 MB to 862 MB; this is a runner-process observation, not an app integration result.

The Piper voice is a single-speaker, medium-quality English model. Kokoro v1.0 requires
phonemization and exposes voice selection, but this probe did not evaluate naturalness,
prosody, voice cloning, or multilingual quality. Neither runner has been connected to
the app's playback or barge-in path.

## Decision and remaining validation

Apple system speech meets the v4 first-audio target on warm runs at roughly 200 ms for
the short clause and has measured immediate write-path interruption, with about 40 MB peak
RSS. Piper has the fastest alternative first yielded PCM and the smallest model-process
footprint in this probe, while Kokoro's whole-buffer API is substantially slower and
heavier here. These numbers support keeping Apple as the shipping path until an
alternative is integrated and tested through the app's playback route.

Acoustic speaker latency, naturalness/listener quality, and barge-in through the real app
audio route still require a supervised device session. The alternative probes establish
local generation metrics only; they do not claim that either engine can replace the
shipping voice path without an adapter and an interruption test.
