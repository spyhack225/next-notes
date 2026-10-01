#!/bin/zsh
# From the repo root; isolated compilation only, no app build or model load.
set -euo pipefail
artifact_fixture_dir=$(mktemp -d /tmp/nextnotes-artifact-fixture.XXXXXX)
trap 'rm -rf "$artifact_fixture_dir"' EXIT
swiftc -swift-version 6 -parse-as-library \
  Sources/NextNotes/Support/ModelDownloader.swift \
  Sources/NextNotes/Support/ModelLibrary/VerifiedModelArtifact.swift \
  Sources/NextNotes/Support/ModelLibrary/InstalledModelLibrary.swift \
  Sources/NextNotes/Support/ModelLibrary/ModelArtifactIdentitySelfTest.swift \
  Tests/Reports/shared-artifacts/2026-09-30-sb-01a/DownloadDriver.swift \
  -o "$artifact_fixture_dir/fixture"
"$artifact_fixture_dir/fixture"
