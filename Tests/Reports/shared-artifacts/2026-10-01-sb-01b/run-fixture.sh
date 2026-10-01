#!/bin/zsh
# Isolated source fixture; the store method body is extracted, not a full app build.
set -euo pipefail
artifact_fixture_dir=$(mktemp -d /tmp/nextnotes-legacy-artifact-fixture.XXXXXX)
trap 'python3 -c '\''import shutil,sys; shutil.rmtree(sys.argv[1])'\'' "$artifact_fixture_dir"' EXIT
python3 - "$artifact_fixture_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
driver = Path('Tests/Reports/shared-artifacts/2026-09-30-sb-01a/DownloadDriver.swift').read_text()
driver = driver.replace('failures.append(contentsOf: ModelArtifactIdentitySelfTest.libraryFailures())',
    'failures.append(contentsOf: ModelArtifactIdentitySelfTest.libraryFailures())\n        failures.append(contentsOf: await ModelArtifactIdentitySelfTest.legacyAdoptionFailures())')
trial_source = Path('Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift').read_text()
trial_start = trial_source.index('enum ModelTrialResult:')
trial_brace = trial_source.index('{', trial_start)
trial_depth, trial_end = 1, trial_brace + 1
while trial_depth:
    trial_depth += (trial_source[trial_end] == '{') - (trial_source[trial_end] == '}')
    trial_end += 1
driver = driver.replace('struct ModelTrialResult: Codable, Sendable, Hashable { let answeredTokens: Int? }',
                        trial_source[trial_start:trial_end])
source = Path('Sources/NextNotes/Support/ModelLibrary/ModelLibraryStore.swift').read_text()
start = source.index('    func reusableArtifactBeforeDownload(')
brace = source.index('{', start)
depth = 1
end = brace + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end]
driver += '\nstruct HuggingFaceRepoFile: Sendable { let path: String; let sizeBytes: Int64; let sha256: String? }\n'
driver += '@MainActor final class ModelLibraryStore {\n    private let library: InstalledModelLibrary\n'
driver += '    init(library: InstalledModelLibrary) { self.library = library }\n' + method + '\n}\n'
(folder / 'Driver.swift').write_text(driver)
PY
swiftc -swift-version 6 -parse-as-library \
  Sources/NextNotes/Support/ModelDownloader.swift \
  Sources/NextNotes/Support/ModelLibrary/VerifiedModelArtifact.swift \
  Sources/NextNotes/Support/ModelLibrary/InstalledModelLibrary.swift \
  Sources/NextNotes/Support/ModelLibrary/ModelArtifactIdentitySelfTest.swift \
  "$artifact_fixture_dir/Driver.swift" -o "$artifact_fixture_dir/fixture"
"$artifact_fixture_dir/fixture"
