import Foundation

/// Tiny on-disk fixtures through the real downloader. No model, network or owner store.
enum ModelArtifactIdentitySelfTest {
    static func downloadFailures() async -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-artifact-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("same-name.gguf")
            let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            let remote = ModelDownloader.RemoteFile(
                // A reuse or rejection must finish without attempting a fetch.
                url: URL(string: "http://127.0.0.1:1/must-not-fetch")!,
                destination: destination, expectedBytes: 3, expectedSHA256: expected,
                bearerToken: nil)
            try Data("abd".utf8).write(to: destination)
            do {
                try await ModelDownloader.download(remote)
                failures.append("same-length substituted bytes were accepted as the pinned artifact")
            } catch ModelDownloadError.invalidChecksum { }
            catch { failures.append("wrong bytes failed for a reason other than integrity: \(error)") }
            if try Data(contentsOf: destination) != Data("abd".utf8) {
                failures.append("failed verification changed the existing file")
            }
            try Data("abc".utf8).write(to: destination)
            try await ModelDownloader.download(remote)
            if try Data(contentsOf: destination) != Data("abc".utf8) {
                failures.append("matching verified destination was not reused unchanged")
            }
            let uppercase = ModelDownloader.RemoteFile(
                url: remote.url, destination: destination, expectedBytes: 3,
                expectedSHA256: expected.uppercased(), bearerToken: nil)
            try await ModelDownloader.download(uppercase)
            // Built-in download/adoption has the same existing-file branch. Use a unique
            // harness file, never the real built-in model or another role's artifact.
            let spec = ModelSpec(displayName: "Artifact fixture", fileName: "fixture-\(UUID().uuidString).gguf",
                                 url: remote.url, expectedBytes: 3, expectedSHA256: expected)
            try FileManager.default.createDirectory(at: ModelSpec.directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: spec.fileURL) }
            try Data("abd".utf8).write(to: spec.fileURL)
            do {
                try await ModelDownloader.download(spec)
                failures.append("built-in adoption accepted same-length substituted bytes")
            } catch ModelDownloadError.invalidChecksum { }
            catch { failures.append("built-in integrity check failed for the wrong reason: \(error)") }
            if try Data(contentsOf: spec.fileURL) != Data("abd".utf8) {
                failures.append("built-in verification failure changed installed bytes")
            }
            try Data("abc".utf8).write(to: spec.fileURL)
            try await ModelDownloader.download(spec)
            // The full-length partial leg must still verify before its atomic promotion.
            try FileManager.default.removeItem(at: destination)
            try Data("abd".utf8).write(to: remote.partialURL)
            let partial = ModelDownloader.RemoteFile(
                url: remote.url, destination: destination, expectedBytes: 3,
                expectedSHA256: expected, bearerToken: nil, allowLowDiskSpace: true)
            do {
                try await ModelDownloader.download(partial)
                failures.append("corrupt complete partial was promoted")
            } catch ModelDownloadError.invalidChecksum { }
            catch { failures.append("partial verification failed for the wrong reason: \(error)") }
            if FileManager.default.fileExists(atPath: destination.path)
                || FileManager.default.fileExists(atPath: remote.partialURL.path) {
                failures.append("corrupt partial survived or was promoted")
            }
            try Data("abc".utf8).write(to: remote.partialURL)
            try await ModelDownloader.download(partial)
            if try Data(contentsOf: destination) != Data("abc".utf8) {
                failures.append("verified complete partial did not reach the real consumer destination")
            }
        } catch { failures.append("fixture setup or matching-artifact reuse failed: \(error)") }
        return failures
    }
    @MainActor
    static func libraryFailures() -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-artifact-library-\(UUID().uuidString)")
        let suiteName = "NextNotesSelfTest-artifact-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ["could not create isolated defaults"]
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let alias = directory.appendingPathComponent("already-imported.gguf")
            try Data("abc".utf8).write(to: alias)
            let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            guard let proof = try VerifiedModelArtifact.verify(alias, bytes: 3, expectedSHA256: digest) else {
                return ["checked fixture did not produce proof"]
            }
            let support = LlamaProbeResult(verdict: .opens, detail: "fixture",
                                           llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: 3)
            func row(_ id: String, _ url: URL, _ verdict: LlamaProbeResult = support,
                     _ identity: VerifiedModelArtifact? = proof) -> InstalledLocalModel {
                InstalledLocalModel(id: id, displayName: "Original import", fileURL: url,
                                    parameterBillions: 2, quantization: "Q4_K_M", bytes: 3,
                                    isBuiltIn: false, support: verdict, verifiedArtifact: identity)
            }
            let original = row("existing/import/original-id", alias)
            let manifest = directory.appendingPathComponent("library.json")
            defaults.set(original.id, forKey: "modelLibrary.activeAgentModelID")
            try JSONEncoder().encode([original]).write(to: manifest)
            let library = InstalledModelLibrary(manifestURL: manifest, defaults: defaults)
            let reused = library.reusableModel(sha256: digest.uppercased(), bytes: 3)
            check(reused == original, "alias did not preserve original row, ID, path and metadata")
            check(library.activeSelectionWrites == 0 && library.activeAgentModelID == original.id,
                  "alias resolution rewrote stored selection")
            check(library.reusableModel(sha256: String(repeating: "0", count: 64), bytes: 3) == nil,
                  "different bytes/version/quantization digest was accepted")
            check(library.reusableModel(sha256: digest, bytes: 4) == nil,
                  "different artifact length was accepted")
            check(library.reusableModel(sha256: nil, bytes: 3) == nil,
                  "missing trusted metadata was accepted as exact identity")
            try library.addVerifiedDownload(original)
            let reopened = InstalledModelLibrary(manifestURL: manifest, defaults: defaults)
            check(reopened.reusableModel(sha256: digest, bytes: 3) == original,
                  "persisted proof did not survive library reopening")
            check(reopened.models.filter { $0.id == original.id }.count == 1,
                  "reuse or recording created duplicate identity rows")
            check(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                  == ["already-imported.gguf", "library.json"], "reuse created another physical file")
            // Remove the new field entirely, as a pre-change manifest really looks.
            let encoded = try JSONEncoder().encode(original)
            var legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacyJSON.removeValue(forKey: "verifiedArtifact")
            let legacy = try JSONDecoder().decode(InstalledLocalModel.self,
                from: JSONSerialization.data(withJSONObject: legacyJSON))
            check(legacy.verifiedArtifact == nil && legacy.id == original.id
                  && legacy.fileURL == original.fileURL && legacy.quantization == original.quantization,
                  "legacy row no longer decodes losslessly or was silently verified")
            library.add(legacy)
            check(library.model(withID: original.id) != nil
                  && library.reusableModel(sha256: digest, bytes: 3) == nil,
                  "legacy row disappeared or unverified bytes were reused")
            check(library.activeSelectionWrites == 0, "legacy migration rewrote selection")
            let auxiliary = directory.appendingPathComponent("mmproj-fixture.gguf")
            try Data("abc".utf8).write(to: auxiliary)
            let auxiliaryProof = try VerifiedModelArtifact.verify(auxiliary, bytes: 3, expectedSHA256: digest)
            library.add(row("fixture/auxiliary", auxiliary, support, auxiliaryProof))
            check(library.reusableModel(sha256: digest, bytes: 3) == nil,
                  "verified auxiliary file became an answer model")
            let unsupported = LlamaProbeResult(verdict: .failedToOpen, detail: "fixture",
                                              llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: 3)
            library.add(row("fixture/unrunnable", alias, unsupported))
            check(library.reusableModel(sha256: digest, bytes: 3) == nil,
                  "verified but unrunnable file was reused")
            library.add(original)
            // Guaranteed timestamp change, with the same inode, basename and length.
            try Data("abd".utf8).write(to: alias)
            try FileManager.default.setAttributes(
                [.modificationDate: proof.stamp.modified.addingTimeInterval(60)], ofItemAtPath: alias.path)
            do {
                try library.addVerifiedDownload(row("fixture/must-not-record", alias))
                failures.append("changed verified file was registered as a finished download")
            } catch ModelDownloadError.invalidChecksum { }
            catch { failures.append("stale registration failed for the wrong reason: \(error)") }
            check(library.model(withID: "fixture/must-not-record") == nil,
                  "failed verification created a library row")
            check(try Data(contentsOf: alias) == Data("abd".utf8),
                  "failed registration changed or deleted installed bytes")
            check(!proof.isCurrent(at: alias)
                  && library.reusableModel(sha256: digest, bytes: 3) == nil,
                  "same-length modification retained old verified identity")
            check(library.activeSelectionWrites == 0, "failed reuse rewrote selection")
            check(try VerifiedModelArtifact.verify(alias, bytes: 3, expectedSHA256: nil) == nil,
                  "unpinned file acquired verified identity without checking a digest")
        } catch { failures.append("library fixture failed: \(error)") }
        return failures
    }

}
