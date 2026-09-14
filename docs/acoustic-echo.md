# Acoustic echo measurement (2026-09-14)

The 08:31 Agent log showed Next's spoken reply returning through SpeechAnalyzer as a new user turn. The 0.2.17 transcript filter reduced simple reflections but missed short two-word fragments and later revisions of SpeechAnalyzer's cumulative transcript. The 09:06–09:07 log still shows a reply fragment becoming a turn and the whole earlier conversation being submitted again. Version 0.2.19 adds those cases to the duplex and realtime self-tests and corrects the transcript boundary. None of this cancels speaker sound in the microphone signal; VAD still sees speaker energy.

Apple's [voice-processing audio engine](https://developer.apple.com/videos/play/wwdc2019/510/) provides acoustic echo cancellation when enabled on an I/O node while the engine is stopped. It switches both I/O nodes. [AVSpeechSynthesizer can render PCM buffers](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write%28_%3Atobuffercallback%3A%29), so routing all voices through one managed graph is technically possible, but must be measured before changing the shared microphone engine.

On a MacBook Air (Mac15,12), macOS 26.5.2, default built-in microphone and built-in speakers, a 5.53-second spoken sample at 48 kHz and mixer gain 0.65 gave:

| Condition | Mic room baseline RMS | Mic during playback RMS | Result |
| --- | ---: | ---: | --- |
| Untreated input, same graph playback | 0.00143 | 0.02018 | Speaker bleed about 23 dB over baseline |
| Voice-processing input, same graph playback | — | — | `AVAudioEngine.start()` failed, Core Audio `-10875` |
| Voice-processing input, separate output engine | 0.00021 | 0.00068 | Mic playback excess 29.8 dB below untreated input |

This first run disabled voice-processing automatic gain control. Repeating with Apple's default gain control still failed to start the same graph; untreated mic RMS was 0.00167 at baseline and 0.01473 during playback, while separate-output voice processing measured 0.00042 and 0.00168 (19.1 dB lower playback excess). The different gain-control setting and room conditions make the two attenuation numbers unsuitable as a performance benchmark.

The attenuation is **not proven AEC**. Voice processing may also change output gain, noise suppression, or device routing; the probe does not independently measure the acoustic speaker level. Its separate output engine approximates, but does not use, the current Apple/Pocket/Kokoro playback backends. The same-graph failure occurred after `setVoiceProcessingEnabled(true)` succeeded. Core Audio logged an aggregate-device channel-layout failure (`Input: index 1 >= originalLayout size 1`). This makes an unconditional switch to voice processing unsafe on the current machine. The probe's first revision also crashed because its tap closure inherited `MainActor`; the callback is now formed in a `nonisolated` function, and the user's crash report matches that test-only defect.

The repeatable probe is `--selftest-acoustic-measure <audio-file>`. Launch it through LaunchServices to use the app's microphone grant. It fails if the input delivers no frames or untreated playback is not detectably above baseline; it reports voice-processing setup errors separately from the valid untreated measurement.

```bash
say -v Samantha -o /tmp/nextnotes-acoustic-probe.aiff \
  'Next Notes found the file. I can open it for you now. Please tell me if you want another action.'
afconvert /tmp/nextnotes-acoustic-probe.aiff /tmp/nextnotes-acoustic-probe-48k.wav \
  -f WAVE -d LEF32@48000 -c 1
open -n -a 'Next Notes' --args --selftest-acoustic-measure \
  /tmp/nextnotes-acoustic-probe-48k.wav --selftest-out /tmp/nextnotes-acoustic-measure.txt
```

Before calling the Agent acoustically full duplex, measure physical output gain in each condition, test actual Apple/Pocket/Kokoro playback, test a person interrupting while the speaker plays, and repeat across built-in, external, and Bluetooth devices. If the managed graph can start reliably and preserve audible output, route TTS PCM through it and use processed mic samples for Agent VAD/ASR while keeping dictation and meeting capture behavior unchanged.
