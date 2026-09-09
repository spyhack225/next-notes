// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Speechify",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as local CoreML through FluidAudio. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        // Official llama.cpp XCFramework. S1-mini runs in-process on the CPU; the app does
        // not depend on Homebrew, Ollama, a local server, or any network request at inference.
        .binaryTarget(
            name: "LlamaFramework",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b10621/llama-b10621-xcframework.zip",
            checksum: "ea50671b3dfe86136be16448763f94642c53443df96964777b4e1c3d51f06e20"
        ),
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "SpeechifyDictionary",
            path: "Sources/SpeechifyDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Speechify",
            dependencies: [
                "SpeechifyDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
                "LlamaFramework",
            ],
            path: "Sources/Speechify",
            // The upstream licence for the vendored orb geometry. It lives beside the code
            // it covers rather than in a licences folder nobody opens, which means SwiftPM
            // finds a file in a source directory that it has no rule for.
            exclude: ["UI/Components/ThinkingOrbs/LICENSE"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SpeechifyDictionaryTests",
            dependencies: ["SpeechifyDictionary"],
            path: "Tests/SpeechifyDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
