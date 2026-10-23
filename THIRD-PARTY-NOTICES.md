# Third-party notices

Next Notes is licensed under the GNU Affero General Public License v3.0 or later
(see [`LICENSE`](LICENSE)). Everything it vendors, links, or bundles is under a
permissive licence that is one-way compatible with the AGPL, so the combined work
can be — and is — distributed under the AGPL. Nothing here imposes a term the AGPL
does not already satisfy beyond the attribution notices reproduced below.

The vendored copies carry their own licence files inside the tree; those files are
authoritative and are shipped inside the built `.app`.

## Vendored source (in this repository)

| Component | Where | Licence |
|---|---|---|
| Xiph SpeexDSP (acoustic echo canceller) | `Sources/SpeexEcho/` | BSD 3-Clause — `Sources/SpeexEcho/LICENSE` |
| Thinking orbs animation (Jakub Antalik) | `Sources/NextNotes/UI/Components/ThinkingOrbs/` | MIT — that directory's `LICENSE` |
| WebRTC audio processing bridge sources | `Vendor/WebRTCAudio/NextNotesAEC.{h,cpp}` | Part of Next Notes, AGPL-3.0-or-later |

## Built and bundled at package time

`Tools/build-webrtc-audio.sh` builds these from pinned, hash-verified sources; `make app`
copies their licence files into `Next Notes.app/Contents/Resources/WebRTCAudio/`.

| Component | Licence |
|---|---|
| Freedesktop `webrtc-audio-processing` 2.1 | BSD 3-Clause — `Vendor/WebRTCAudio/WEBRTC-AUDIO-PROCESSING-LICENSE` |
| WebRTC (upstream) | BSD 3-Clause + patent grant — `Vendor/WebRTCAudio/WEBRTC-LICENSE`, `WEBRTC-PATENTS` |
| Abseil 20240722.0 | Apache-2.0 — `Vendor/WebRTCAudio/ABSEIL-LICENSE` |
| Ooura FFT and other WebRTC third-party code | see `Vendor/WebRTCAudio/THIRD-PARTY-LICENSE` |

## macOS dependencies

The meeting notes editor bundles Tiptap 3, its ProseMirror dependencies, and markdown-it
from `Web/MeetingEditor/`. They and most transitive packages are MIT licensed; `entities`
is BSD-2-Clause and `argparse` is PSF-2.0. Their licence texts are shipped in
`Resources/MeetingEditor/licenses/`. The editor bundle is built locally and makes no
network request while a meeting is open.

| Component | Licence |
|---|---|
| llama.cpp XCFramework (`ggml-org/llama.cpp`) | MIT |
| FluidAudio (`FluidInference/FluidAudio`) | Apache-2.0 |
| sherpa-onnx C API (`k2-fsa/sherpa-onnx`), dlopened at runtime | Apache-2.0 |

## Windows dependencies

| Component | Licence |
|---|---|
| Avalonia 11.3.20 | MIT |
| NAudio 2.3.0 | MIT |
| `org.k2fsa.sherpa.onnx` 1.13.5 (bundles ONNX Runtime) | Apache-2.0 |
| xunit, Shouldly, NetArchTest.Rules (test only, not shipped) | Apache-2.0 / BSD-3-Clause / MIT |

## Landing page (`site/`)

React, React DOM, Framer Motion, Tailwind CSS (v4, via `@tailwindcss/vite`), Vite and
TypeScript are MIT; `lucide-react` is ISC; Oxlint and `@shadcn/lint` (the site's lint
gate) are MIT; the Fontsource packages redistribute Inter and
Instrument Serif under the SIL Open Font License 1.1. `border-beam` and `voice-glow`
(the hero card's border beam and the demo composer's voice glow, same author as the
thinking-orbs library the app's orb geometry is ported from) are MIT with zero runtime
dependencies. The fonts keep their OFL terms when
the site is copied; the OFL's only real constraint — do not sell the fonts on their own and
do not rename them — is untouched by the AGPL.

## Downloaded at runtime, not distributed

Nothing in this section ships in the repository or inside the `.app`. Each item is fetched
from its publisher on the user's machine, against a pinned SHA-256, and keeps its own terms —
which the AGPL here neither extends nor restricts.

| Component | What it is | Licence |
|---|---|---|
| Apple on-device models, Parakeet TDT, Gemma 4 E4B, S1-mini, the wake-word model | speech and language model weights | each publisher's own |
| Needle 3 (`Cactus-Compute/needle3`) — `needle3.cact` weights (35.3 MB) | on-device function-calling model | Apache-2.0 |
| Needle 3 — `macos-arm64/needle` (825 KB) | the engine that runs those weights, kept resident as a child process (`needle --serve`) while the feature is in use | Apache-2.0 |
| Any GGUF the user chooses from the Hugging Face Hub | model weights | whatever that repository states; gated repositories require the user to accept the publisher's terms first |

The Needle engine is the only **executable** in this table rather than a set of weights, so
it is called out separately: it is Apache-2.0, which is one-way compatible with
AGPL-3.0-or-later, it is never committed, and it runs as a separate process rather than being
linked in. Verified against the Hub's own metadata on 2026-09-20 (`license: apache-2.0`,
`gated: false`).

Check a model's own terms before redistributing weights.

## Optional native speech runtimes

- [Phonon / ptts 0.4.0](https://github.com/gradium-ai/xn-ptts/tree/v0.4.0): MIT or Apache-2.0; the selected Phonon 31m English weights are Apache-2.0. The noncommercial Phonon 40m weights are not selected or downloaded.
- [MLX Audio Swift 0.1.6](https://github.com/Blaizzy/mlx-audio-swift/tree/v0.1.6): MIT; uses Apple's [MLX Swift](https://github.com/ml-explore/mlx-swift), MIT.
- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS): Apache-2.0; the selected [MLX 0.6B CustomVoice 4-bit conversion](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit) is pinned by commit, size and SHA-256 in `NativeVoiceAssets.swift`.

These models download only after selection, or one at a time into the benchmark's disposable folder. Runtime packages do not contain model weights.

## Cloud services

OpenRouter, Google Workspace (`gws`), Composio and any MCP server the user configures are
optional, opt-in, and reached over the network. They are services, not code in this work.

## Mac app headline fonts

Inter and Instrument Serif (Fontsource packages 5.3.0) are included in the Mac app.
Local WOFF TrueType outlines were unwrapped into TTF containers without changing glyphs, character maps or PostScript names. The original copyright and SIL Open Font License 1.1 texts are bundled in `Resources/ThemeFonts/`. The provenance manifest records the source and output hashes. These are Latin subsets; the operating system supplies other glyphs. No font is installed into the user’s Fonts directory.

## Additional local speech recognition

Phonon-2 Core ML runtime by Fermion Research: Apache License 2.0; the pinned
runtime's LICENSE and NOTICE are retained in Vendor/PhononASR. Phonon-2 weights
are downloaded separately from FermionResearch/Phonon-2-CoreML; attribution:
Fermion Research, Phonon-2, https://www.fermionresearch.com/models/phonon-2/.

Voz by Desert Ant Labs — https://desertant.com/models/voz/.
SDK revision 86b9b55fe8c61ec1c27c5b6383f545c6df1d6ceb; Desert Ant Labs
Source-Available License 1.0, https://license.desertant.com/1.0.
Voz model artifacts are downloaded separately. The attribution is also shown
beside the speech-model comparison in Settings.

Whistle and its Needle runtime by Cactus Compute are downloaded separately
from their pinned official Cactus-Compute Hugging Face repositories.
Qwen3-ASR by Qwen and the MLX community runs through MLX Audio Swift's
MLXAudioSTT product. Parakeet Redux and Ultra artifacts are by Moondream,
converted to Core ML by Fluid Inference; their original source credits and
licenses remain with the separately downloaded models.

## Voice turn detection models (downloaded at runtime)

- [Smart Turn v3.2 CoreML](https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/tree/75f069717f500947195fa1945c46ddb472559cff), derived from Daily/Pipecat Smart Turn v3: BSD 2-Clause, copyright (c) 2024–2025 Daily. The export contains the raw-audio front end; its compiled files are individually pinned in `VoiceTurnModels.swift`. [Upstream licence](https://huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML/blob/75f069717f500947195fa1945c46ddb472559cff/LICENSE).
- [Silero VAD 6.0.0, 32 ms CoreML export](https://huggingface.co/FluidInference/silero-vad-coreml/tree/b419383c55c110e2c9271fa6ee0ea83d03c70d96): MIT, Silero Team, converted by FluidInference. [Upstream licence](https://github.com/snakers4/silero-vad/blob/master/LICENSE). These weights are fetched separately; no ONNX/Python runtime is shipped.
