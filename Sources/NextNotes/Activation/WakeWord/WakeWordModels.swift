import Foundation

/// The sherpa-onnx keyword-spotting assets Qwen's desktop client downloads (~33 MB).
///
/// Same archive, hash and filenames as `references/qwen-audio-agent-main/desktop/src/wake-word/model-manager.mjs`.
/// Next Notes writes a user-chosen phrase into `keywords.txt` instead of baking “你好千问”.
enum WakeWordModels {
    static let name = "sherpa-onnx-kws-zipformer-zh-en-3M-2025-12-20"

    static let archive = ModelSpec(
        displayName: "Wake phrase",
        fileName: "\(name).tar.bz2",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/\(name).tar.bz2")!,
        expectedBytes: 32_885_699,
        expectedSHA256: "68447f4fbc67e70eee3a93961f36e81e98f47aef73ce7e7ca00885c6cd3616a6"
    )

    /// sherpa-onnx 1.13.8 C API + ONNX Runtime, no TTS. Downloaded beside the model.
    static let runtime = ModelSpec(
        displayName: "Wake runtime",
        fileName: "sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib.tar.bz2",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib.tar.bz2")!,
        expectedBytes: 17_827_519,
        expectedSHA256: "bdcc7c266d355697584dd4efb9dc766e45e18e87cec1fc553002a32cfcfab9a7"
    )

    static let encoderFile = "encoder-epoch-13-avg-2-chunk-8-left-64.int8.onnx"
    static let decoderFile = "decoder-epoch-13-avg-2-chunk-8-left-64.onnx"
    static let joinerFile = "joiner-epoch-13-avg-2-chunk-8-left-64.int8.onnx"
    static let tokensFile = "tokens.txt"
    static let keywordsFile = "keywords.txt"
    static let phoneLexiconFile = "en.phone"

    static let requiredModelFiles = [encoderFile, decoderFile, joinerFile, tokensFile]
}
