"""Isolated Voz SDK paced prefix comparison; same policy as other batch models."""
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
import argparse
from asr_benchmark import ROOT
from asr_voz_compare import URL, run
from asr_live import rpc_driver

REVISION = "86b9b55fe8c61ec1c27c5b6383f545c6df1d6ceb"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    options = parser.parse_args()
    if options.output.exists():
        parser.error("new output required")
    cache = Path.home()/"Library/Caches/NextNotesASRBench"
    cache.mkdir(exist_ok=True, parents=True)
    with (cache/"serial.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if shutil.disk_usage(cache).free < 3*1024**3:
            raise RuntimeError("Voz source build and weights require 3GiB headroom")
        report = {"engine": "Voz SDK", "sdk_revision": REVISION,
            "free_disk_before_bytes": shutil.disk_usage(cache).free}
        options.output.parent.mkdir(exist_ok=True, parents=True)
        with tempfile.TemporaryDirectory(prefix="voz-live-", dir=cache) as owned:
            folder = Path(owned)
            env = {**os.environ, "CFFIXED_USER_HOME": str(folder/"home"),
                "TMPDIR": str(folder/"tmp"), "XDG_CACHE_HOME": str(folder/"xdg"),
                "XDG_CONFIG_HOME": str(folder/"config")}
            for name in ("home", "tmp", "xdg", "config"):
                (folder/name).mkdir()
            def unpack(url, target, maximum):
                with urllib.request.urlopen(url, timeout=90) as response:
                    data = response.read(maximum+1)
                if len(data)>maximum:
                    raise RuntimeError("archive exceeds diagnostic size bound")
                with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                    archive.extractall(target, filter="data")
                return hashlib.sha256(data).hexdigest()
            report["source_archive_sha256"] = unpack(
                f"https://api.github.com/repos/Desert-Ant-Labs/desert-ant-core/tarball/{REVISION}", folder/"sdk", 32*1024**2)
            source = next((folder/"sdk").iterdir())
            # Original SDK manifest/targets retained; only append a diagnostic
            # executable edge. MLX/Xet traits stay off. No app dependency edits.
            with (source/"Package.swift").open("a") as manifest:
                manifest.write('\npackage.targets.append(.executableTarget(name: "ASRLiveProbe", dependencies: ["Voz"], path: "ASRLiveProbe"))\n')
                manifest.write('package.products.append(.executable(name: "ASRLiveProbe", targets: ["ASRLiveProbe"]))\n')
            (source/"ASRLiveProbe").mkdir()
            shutil.copyfile(ROOT/"Tools/VozASRLiveProbe.swift", source/"ASRLiveProbe/Probe.swift")
            command = ["xcrun", "swift", "build", "--package-path", str(source),
                "--scratch-path", str(folder/"build"), "-c", "release", "--jobs", "1",
                "--cache-path", str(folder/"spm-cache"), "--config-path", str(folder/"spm-config"),
                "--security-path", str(folder/"spm-security"),
                "--disable-default-traits", "--product", "ASRLiveProbe"]
            report["build_command"] = command
            report["build"] = run(command, env, timeout=300)
            if report["build"]["exit"]:
                options.output.write_text(json.dumps(report, indent=2)+"\n")
                raise RuntimeError(report["build"]["stderr"][-3000:])
            report["cli_archive_sha256"] = unpack(URL, folder/"cli", 15*1024**2)
            cli = next(p for p in (folder/"cli").rglob("desertant") if p.is_file())
            probe = next(p for p in (folder/"build").rglob("ASRLiveProbe") if p.is_file() and os.access(p, os.X_OK))
            location = run([str(cli), "cache", "--path"], env)
            cachepath = Path(location["stdout"].strip())
            if location["exit"] or not cachepath.resolve().is_relative_to(folder.resolve()):
                raise RuntimeError("Voz cache isolation failed")
            report["prepare"] = run([str(cli), "pull", "voz", "--json"], env, timeout=240)
            if report["prepare"]["exit"]:
                raise RuntimeError(report["prepare"]["stderr"][-2000:])
            model = next(p.parent for p in cachepath.rglob("embedding.f16"))
            report["artifacts"] = [{"path": str(p.relative_to(model)), "bytes": p.stat().st_size,
                "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in model.rglob("*") if p.is_file()]
            child = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", str(probe), str(model)],
                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                rpc_driver(child, folder/"result.json")
                stdout, stderr = child.communicate(timeout=30)
            except BaseException:
                child.kill()
                child.wait()
                raise
            report.update(child_exit=child.returncode, child_joined=True,
                stderr=stderr.decode(errors="replace"), benchmark=json.loads((folder/"result.json").read_text()))
            options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n")
        report.update(temporary_assets_deleted=not folder.exists(), free_disk_after_bytes=shutil.disk_usage(cache).free)
        options.output.write_text(json.dumps(report, indent=2, ensure_ascii=False)+"\n")
        print("Voz saved; candidate/model/source/build deleted", flush=True)


if __name__ == "__main__":
    main()
