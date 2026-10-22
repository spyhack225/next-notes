#!/usr/bin/env python3
"""Exact prior/current SHA producer, sequential fresh processes; model is read-only."""
import argparse
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("model", type=pathlib.Path)
args = parser.parse_args()
here = pathlib.Path(__file__).resolve().parent
repo = here.parents[3]
source = (repo / "Sources/NextNotes/Support/ModelDownloader.swift").read_text()
start = source.index("    static func sha256(of url: URL) throws -> String {")
end = source.index("\n    /// Reports byte progress", start)
with tempfile.TemporaryDirectory(prefix="nextnotes-sha256-probe-") as raw:
    temp = pathlib.Path(raw)
    current = temp / "CurrentHash.swift"
    current.write_text("import CryptoKit\nimport Foundation\nenum HashAfter {\n" + source[start:end] + "\n}\n")
    binary = temp / "probe"
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-module-cache-path", str(temp / "modules"),
                    str(here / "BeforeHash.swift"), str(current), str(here / "Probe.swift"),
                    "-o", str(binary)], check=True)
    for arm in ("before", "after", "contracts"):
        subprocess.run([str(binary), arm, str(args.model)], check=True)
