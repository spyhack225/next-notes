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

React, React DOM, Framer Motion, Tailwind CSS, PostCSS, Autoprefixer, Vite and TypeScript
are MIT; `lucide-react` is ISC; the Fontsource packages redistribute Inter and
Instrument Serif under the SIL Open Font License 1.1. The fonts keep their OFL terms when
the site is copied; the OFL's only real constraint — do not sell the fonts on their own and
do not rename them — is untouched by the AGPL.

## Models

Speech and language models (Apple's own, Parakeet TDT, Qwen, S1-mini, the wake-word model)
are **downloaded at runtime and are not distributed with this source or with the app**.
Each carries its own licence from its publisher, which the AGPL here neither extends nor
restricts. Check the model's own terms before redistributing weights.

## Cloud services

OpenRouter, Google Workspace (`gws`), Composio and any MCP server the user configures are
optional, opt-in, and reached over the network. They are services, not code in this work.
