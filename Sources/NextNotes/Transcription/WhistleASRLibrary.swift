import Foundation
import Darwin

/// Pinned custom CPU runtime. It never claims to run on Core ML.
/// Confined to NativeASRBackend, including all calls into the library's globals.
final class WhistleASRLibrary {
    private let library: UnsafeMutableRawPointer
    private let model: Data
    private typealias Load = @convention(c) (UnsafeRawPointer?, UInt64) -> Int32
    private typealias Infer = @convention(c) (UnsafePointer<Float>?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
    private let infer: Infer
    init(directory: URL) throws {
        let binary = directory.appendingPathComponent("libneedle3.dylib")
        if !FileManager.default.fileExists(atPath: binary.path) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", directory.appendingPathComponent("runtime.whl").path, "needle/libneedle3.dylib"]
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ASRModelError.runtime("Whistle could not be unpacked.") }
            try data.write(to: binary, options: .atomic)
        }
        _ = try VerifiedModelArtifact.verify(binary, bytes: 1087632, expectedSHA256: "0137354250a85fa52d100de948ccff9d9f7d8dd73ced0eea19c38f6e351aef55")
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else { throw ASRModelError.runtime("Whistle could not be opened.") }
        guard let loadSymbol = dlsym(handle, "needle_load"), let inferSymbol = dlsym(handle, "needle_transcribe") else {
            dlclose(handle); throw ASRModelError.runtime("Whistle speech functions are missing.")
        }
        let load = unsafeBitCast(loadSymbol, to: Load.self)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("whistle.cact"), options: .mappedIfSafe)
        guard bytes.withUnsafeBytes({ load($0.baseAddress, UInt64(bytes.count)) }) >= 0 else {
            dlclose(handle); throw ASRModelError.runtime("Whistle weights could not be loaded.")
        }
        model = bytes; library = handle; infer = unsafeBitCast(inferSymbol, to: Infer.self)
    }
    deinit { dlclose(library) }
    func transcribe(_ samples: [Float], englishOnly: Bool) throws -> String {
        var result = [UInt8](repeating: 0, count: 256 * 1024)
        let status = samples.withUnsafeBufferPointer { audio in
            result.withUnsafeMutableBytes { output in
                if englishOnly {
                    return "en".withCString { infer(audio.baseAddress, Int32(audio.count), $0, nil, 1, output.baseAddress, Int32(output.count)) }
                }
                return infer(audio.baseAddress, Int32(audio.count), nil, nil, 1, output.baseAddress, Int32(output.count))
            }
        }
        guard status >= 0 else { throw ASRModelError.runtime("Whistle could not transcribe this recording.") }
        let end = result.firstIndex(of: 0) ?? result.endIndex
        let object = try JSONSerialization.jsonObject(with: Data(result[..<end])) as? [String: Any]
        return object?["text"] as? String ?? ""
    }
}
