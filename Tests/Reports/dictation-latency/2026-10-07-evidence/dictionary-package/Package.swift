// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DictationDictionaryProof", platforms: [.macOS(.v26)], targets: [
    .target(name: "NextNotesDictionary", path: "Sources/NextNotesDictionary", swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "NextNotesDictionaryTests", dependencies: ["NextNotesDictionary"], path: "Tests/NextNotesDictionaryTests", resources: [.copy("dictionary-test-vectors.json"), .copy("spoken-forms-test-vectors.json")], swiftSettings: [.swiftLanguageMode(.v6)])
])
