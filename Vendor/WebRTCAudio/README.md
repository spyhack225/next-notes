# Local AEC3 bridge

`Tools/build-webrtc-audio.sh` builds two dylibs for the current macOS architecture (arm64 or x86_64) in
`~/Library/Caches/NextNotesBuild/webrtc` (override with `NEXTNOTES_WEBRTC_CACHE`).
It prints the output directory. `make app` bundles and signs both dylibs in `Frameworks/`; the processor remains
opt-in for acoustic self-tests until the cold near-speech gates pass. The bridge keeps a C ABI
because the upstream WebRTC C++ ABI is not stable. No model, microphone sample,
or speaker sample is sent to a server.

Pinned dependencies:

- Freedesktop `webrtc-audio-processing` 2.1, SHA-256
  `ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe`.
- Its Abseil Meson wrap, release 20240722.0: source SHA-256
  `f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3`,
  patch SHA-256 `12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b`.
- Isolated build tools: Meson 1.12.0 and Ninja 1.13.2.

The script verifies the source archive and Abseil wrap hashes, forces bundled
Abseil instead of a local Homebrew library, and verifies every cached output
against `manifest.sha256`. It builds outside this iCloud-synced repository and
does not alter the app's selected echo processor. Runtime linkage is only the
bundled APM dylib and macOS system libraries. Use `otool -L` to confirm after
building on each target architecture. Both libraries require signing with the
app identity before packaging.

`NextNotesAEC.h` specifies 16 kHz mono Float32 in 160-sample blocks. Feed the
rendered speaker reference with `aec_feed_render`, then the matching captured
mic block with `aec_process_capture`; dispose and create a new instance between
voice sessions. The delay argument uses WebRTC's stream delay semantics: it is
the capture/render timing gap known to the application, not a guessed acoustic
echo peak. The bridge config enables desktop AEC3 and disables its enforced
high-pass filter, which preserved near speech better in a fixed-latency offline
double-talk fixture. It leaves standalone high-pass, noise suppression,
transient suppression, and gain controllers off.

License texts are adjacent to this README and copied into the build output:
`WEBRTC-AUDIO-PROCESSING-LICENSE`, `WEBRTC-LICENSE`, `WEBRTC-PATENTS`, and
`ABSEIL-LICENSE`. They must accompany distributed binaries, along with any
`THIRD-PARTY-LICENSE`, collected from the pinned upstream Ooura, integer square
root, PFFFT, RNNoise and FFT components. `make app` includes these in Resources.
