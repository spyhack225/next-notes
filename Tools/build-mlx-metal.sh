#!/bin/bash
# SwiftPM's native backend does not compile .metal resources. Build exactly the
# generated kernels from the resolved MLX checkout, and retain their shared cache.
set -euo pipefail
scratch="${1:?expected SwiftPM scratch directory}"
configuration="${2:-release}"
source_root="$scratch/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
product="$scratch/$configuration"
bundle="$product/mlx-swift_Cmlx.bundle"
resources="$bundle/Contents/Resources"
work="$scratch/mlx-metal-$configuration"
mkdir -p "$resources" "$work"
fingerprint=$(find "$source_root" -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256 | cut -d ' ' -f 1)
if compiler=$(xcrun metal --version 2>/dev/null) && [[ "$compiler" != *"error:"* ]]; then
    local_compiler=1
else
    compiler="publisher-cmlx-0.32.3"
    local_compiler=0
fi
stamp="$fingerprint $compiler"
if [ -s "$resources/default.metallib" ] && [ -f "$work/source-pin" ] && [ "$(cat "$work/source-pin")" = "$stamp" ]; then
    exit 0
fi
objects=()
if [ "$local_compiler" = 1 ]; then
while IFS= read -r shader; do
    name="${shader#"$source_root/"}"
    object="$work/${name//\//_}.air"
    xcrun -sdk macosx metal -std=metal3.1 -I "$source_root" -c "$shader" -o "$object"
    objects+=("$object")
done < <(find "$source_root" -name '*.metal' -type f | LC_ALL=C sort)
[ "${#objects[@]}" -gt 0 ]
xcrun -sdk macosx metallib "${objects[@]}" -o "$resources/default.metallib.partial"
mv "$resources/default.metallib.partial" "$resources/default.metallib"
else
    # Reuse the matching publisher-built kernels instead of installing an entire
    # Metal toolchain on a nearly full laptop. Extract just the macOS library.
    python3 - "$scratch" "$resources" "$work" <<'PYTHON'
import hashlib, pathlib, shutil, sys, urllib.request, zipfile
scratch, resources, work = map(pathlib.Path, sys.argv[1:])
import subprocess
version = subprocess.check_output(["git", "-C", str(scratch / "checkouts/mlx-swift"), "describe", "--tags", "--exact-match"], text=True).strip()
if version != "0.32.3":
    raise SystemExit("Update the pinned Metal artifact for the resolved MLX version before building.")
archive = work / "Cmlx.xcframework.zip"
print("Preparing matching Metal kernels from MLX 0.32.3 release (temporary archive).", flush=True)
try:
    urllib.request.urlretrieve("https://github.com/ml-explore/mlx-swift/releases/download/0.32.3/Cmlx.xcframework.zip", archive)
    with archive.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    if digest != "731dbfeebcba686e8c8face9c967eaa127e8c4d8611b5601d5d54f8f1fb4aa78":
        raise SystemExit("Metal artifact checksum mismatch")
    with zipfile.ZipFile(archive) as package:
        candidates = [p for p in package.namelist() if "macos-" in p and p.endswith(("/default.metallib", "/mlx.metallib"))]
        if len(candidates) != 1:
            raise SystemExit("Expected one macOS Metal library: " + repr(candidates))
        temporary = resources / "default.metallib.partial"
        with package.open(candidates[0]) as source, temporary.open("wb") as output:
            shutil.copyfileobj(source, output)
        temporary.replace(resources / "default.metallib")
finally:
    archive.unlink(missing_ok=True)
PYTHON
fi
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>ai.pivotstudio.nextnotes.mlx-kernels</string><key>CFBundlePackageType</key><string>BNDL</string><key>CFBundleVersion</key><string>1</string></dict></plist>
PLIST
printf '%s' "$stamp" > "$work/source-pin"
# AIR files are disposable once linked; retain just the library and compact pin.
if [ "${#objects[@]}" -gt 0 ]; then rm -f "${objects[@]}"; fi
