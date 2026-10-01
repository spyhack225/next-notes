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

    @MainActor
    static func legacyAdoptionFailures() async -> [String] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-legacy-artifact-\(UUID().uuidString)")
        let suite = "NextNotesSelfTest-legacy-artifact-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return ["isolated defaults unavailable"] }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var failures: [String] = []
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let alias = directory.appendingPathComponent("old-custom-basename.gguf")
            try Data("abc".utf8).write(to: alias)
            let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            let file = HuggingFaceRepoFile(path: "canonical-Q4_K_M.gguf", sizeBytes: 3, sha256: digest)
            let support = LlamaProbeResult(verdict: .opens, detail: "fixture",
                                          llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: 3)
            let legacy = InstalledLocalModel(id: "old/import/model-id", displayName: "Preserved legacy import",
                fileURL: alias, parameterBillions: 2, quantization: "Q4_K_M", bytes: 3,
                isBuiltIn: false, support: support,
                lastTrial: .opensButCannotAnswer("Keep the original fixture verdict"))
            let manifest = directory.appendingPathComponent("library.json")
            try JSONEncoder().encode([legacy]).write(to: manifest)
            defaults.set(legacy.id, forKey: "modelLibrary.activeAgentModelID")
            let library = InstalledModelLibrary(manifestURL: manifest, defaults: defaults)
            let store = ModelLibraryStore(library: library)
            let reused = try await store.reusableArtifactBeforeDownload(file)
            if reused?.id != legacy.id || reused?.fileURL != alias {
                failures.append("legacy alias reached fetch boundary instead of reusing original row/path")
            }
            if reused?.verifiedArtifact?.matches(sha256: digest, bytes: 3, at: alias) != true {
                failures.append("legacy alias did not persist checked-byte proof")
            }
            if reused?.displayName != legacy.displayName || reused?.parameterBillions != legacy.parameterBillions
                || reused?.quantization != legacy.quantization || reused?.support != legacy.support
                || reused?.lastTrial != legacy.lastTrial {
                failures.append("legacy adoption changed metadata or promoted the existing trial verdict")
            }
            let reopened = InstalledModelLibrary(manifestURL: manifest, defaults: defaults)
            if reopened.reusableModel(sha256: digest, bytes: 3)?.id != legacy.id {
                failures.append("legacy adoption did not survive manifest reopen")
            }
            if library.activeSelectionWrites != 0 || library.activeAgentModelID != legacy.id {
                failures.append("legacy verification rewrote the selection")
            }
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
                != ["library.json", "old-custom-basename.gguf"] {
                failures.append("legacy adoption copied or fetched a second physical file")
            }

            // Current proof takes the existing stat-only path, even on a later action.
            library.beforeArtifactVerificationForTesting = { _ in
                failures.append("current proof was hashed again")
            }
            let again = try await store.reusableArtifactBeforeDownload(file)
            if again != reused { failures.append("current-proof reuse changed the original row") }

            func makeCase(_ name: String, text: String = "abc", filename: String = "legacy.gguf",
                          verdict: LlamaProbeVerdict = .opens)
                throws -> (InstalledModelLibrary, ModelLibraryStore, InstalledLocalModel, URL) {
                let folder = directory.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(filename)
                try Data(text.utf8).write(to: url)
                let model = InstalledLocalModel(id: "old/import/\(name)", displayName: "Keep this name",
                    fileURL: url, parameterBillions: 2, quantization: "Q4_K_M", bytes: 3,
                    isBuiltIn: false, support: LlamaProbeResult(verdict: verdict, detail: "fixture",
                        llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: 3))
                let path = folder.appendingPathComponent("library.json")
                try JSONEncoder().encode([model]).write(to: path)
                let candidateLibrary = InstalledModelLibrary(manifestURL: path, defaults: defaults)
                return (candidateLibrary, ModelLibraryStore(library: candidateLibrary), model, path)
            }
            for (name, text, filename, verdict) in [
                ("wrong-bytes", "abd", "canonical-Q4_K_M.gguf", LlamaProbeVerdict.opens),
                ("auxiliary", "abc", "mmproj-fixture.gguf", .opens),
                ("unrunnable", "abc", "legacy.gguf", .failedToOpen)
            ] {
                let (candidateLibrary, candidateStore, model, _) = try makeCase(
                    name, text: text, filename: filename, verdict: verdict)
                let originalBytes = try Data(contentsOf: model.fileURL)
                let writes = candidateLibrary.activeSelectionWrites
                if try await candidateStore.reusableArtifactBeforeDownload(file) != nil {
                    failures.append("\(name) reached successful alias reuse")
                }
                if candidateLibrary.model(withID: model.id)?.verifiedArtifact != nil {
                    failures.append("\(name) acquired proof without matching runnable bytes")
                }
                if try Data(contentsOf: model.fileURL) != originalBytes
                    || candidateLibrary.activeSelectionWrites != writes {
                    failures.append("\(name) changed existing bytes or selection")
                }
            }
            let (quantLibrary, quantStore, quantModel, _) = try makeCase("different-quantization")
            let wrongDigest = HuggingFaceRepoFile(path: "canonical-Q8_0.gguf", sizeBytes: 3,
                                                 sha256: String(repeating: "0", count: 64))
            if try await quantStore.reusableArtifactBeforeDownload(wrongDigest) != nil
                || quantLibrary.model(withID: quantModel.id)?.verifiedArtifact != nil {
                failures.append("different quantization/version digest adopted legacy bytes")
            }
            let (missingLibrary, missingStore, missingModel, _) = try makeCase("missing-metadata")
            missingLibrary.beforeArtifactVerificationForTesting = { _ in
                failures.append("missing trusted identity started hashing")
            }
            for request in [HuggingFaceRepoFile(path: "model.gguf", sizeBytes: 3, sha256: nil),
                            HuggingFaceRepoFile(path: "model.gguf", sizeBytes: 4, sha256: digest)] {
                if try await missingStore.reusableArtifactBeforeDownload(request) != nil {
                    failures.append("missing/wrong metadata acquired a reusable file")
                }
            }
            if missingLibrary.model(withID: missingModel.id)?.verifiedArtifact != nil {
                failures.append("missing metadata upgraded a legacy row")
            }
            // Deterministic awaits around the real hash exercise actor reentry. None of
            // these hooks returns a fake proof or touches another library/store.
            for name in ["changed-file", "changed-metadata", "removed-row", "cancelled"] {
                let (candidateLibrary, candidateStore, model, path) = try makeCase(name)
                let writes = candidateLibrary.activeSelectionWrites
                candidateLibrary.afterArtifactVerificationForTesting = { _ in
                    switch name {
                    case "changed-file":
                        try Data("abd".utf8).write(to: model.fileURL)
                        try FileManager.default.setAttributes(
                            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: model.fileURL.path)
                    case "changed-metadata":
                        let renamed = InstalledLocalModel(id: model.id, displayName: "Owner changed name",
                            fileURL: model.fileURL, parameterBillions: model.parameterBillions,
                            quantization: model.quantization, bytes: model.bytes,
                            isBuiltIn: false, support: model.support)
                        candidateLibrary.add(renamed)
                    case "removed-row":
                        try Data("[]".utf8).write(to: path)
                        candidateLibrary.refresh()
                    default: throw CancellationError()
                    }
                }
                do {
                    _ = try await candidateStore.reusableArtifactBeforeDownload(file)
                    failures.append("\(name) did not abort before recording/use/fetch")
                } catch is CancellationError { }
                catch { failures.append("\(name) failed with the wrong error: \(error)") }
                if candidateLibrary.model(withID: model.id)?.verifiedArtifact != nil {
                    failures.append("\(name) persisted obsolete proof")
                }
                if name == "removed-row", candidateLibrary.model(withID: model.id) != nil {
                    failures.append("removed row was recreated by adoption")
                }
                if name == "changed-metadata",
                   candidateLibrary.model(withID: model.id)?.displayName != "Owner changed name" {
                    failures.append("adoption overwrote newer owner metadata")
                }
                if candidateLibrary.activeSelectionWrites != writes {
                    failures.append("\(name) changed a choice while aborting adoption")
                }
            }
            let (mismatchRaceLibrary, mismatchRaceStore, mismatchRaceModel, mismatchRacePath)
                = try makeCase("mismatch-removed-row", text: "abd")
            mismatchRaceLibrary.afterArtifactVerificationForTesting = { _ in
                try Data("[]".utf8).write(to: mismatchRacePath)
                mismatchRaceLibrary.refresh()
            }
            do {
                _ = try await mismatchRaceStore.reusableArtifactBeforeDownload(file)
                failures.append("digest mismatch plus removed row fell through to fetch")
            } catch is CancellationError { }
            catch { failures.append("mismatch/removal race used the wrong error: \(error)") }
            let mismatchBytes = try Data(contentsOf: mismatchRaceModel.fileURL)
            if mismatchRaceLibrary.model(withID: mismatchRaceModel.id) != nil
                || mismatchBytes != Data("abd".utf8) {
                failures.append("mismatch/removal race recreated a row or changed existing bytes")
            }
            let (staleProbeLibrary, staleProbeStore, staleProbeModel, _) = try makeCase("stale-probe")
            staleProbeLibrary.add(InstalledLocalModel(id: staleProbeModel.id,
                displayName: staleProbeModel.displayName, fileURL: staleProbeModel.fileURL,
                parameterBillions: 2, quantization: "Q4_K_M", bytes: 3, isBuiltIn: false,
                support: LlamaProbeResult(verdict: .opens, detail: "fixture",
                    llamaBuildTag: "older-fixture-backend", fileBytes: 3)))
            staleProbeLibrary.beforeArtifactVerificationForTesting = { _ in
                failures.append("stale probe metadata started legacy adoption")
            }
            if try await staleProbeStore.reusableArtifactBeforeDownload(file) != nil {
                failures.append("legacy row with stale backend probe was adopted")
            }
            // Cancellation is not an integrity mismatch: a complete partial stays resumable.
            let partialDestination = directory.appendingPathComponent("cancelled-partial.gguf")
            let cancelledPartial = ModelDownloader.RemoteFile(url: URL(string: "http://127.0.0.1:1/no-fetch")!,
                destination: partialDestination, expectedBytes: 3, expectedSHA256: digest,
                bearerToken: nil, allowLowDiskSpace: true)
            try Data("abc".utf8).write(to: cancelledPartial.partialURL)
            let cancelledDownload = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await ModelDownloader.download(cancelledPartial)
            }
            do {
                try await cancelledDownload.value
                failures.append("cancelled hash completed as a successful download")
            } catch is CancellationError { }
            catch { failures.append("hash cancellation became an integrity/download error: \(error)") }
            if try Data(contentsOf: cancelledPartial.partialURL) != Data("abc".utf8)
                || FileManager.default.fileExists(atPath: partialDestination.path) {
                failures.append("hash cancellation removed or promoted the resumable partial")
            }
        } catch { failures.append("legacy adoption fixture failed: \(error)") }
        return failures
    }

}
