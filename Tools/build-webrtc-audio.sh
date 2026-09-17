#!/usr/bin/env bash
set -euo pipefail

# Build the pinned, on-device WebRTC AEC3 C ABI outside the iCloud worktree.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_dir="${NEXTNOTES_WEBRTC_CACHE:-$HOME/Library/Caches/NextNotesBuild/webrtc}"
archive="$cache_dir/downloads/webrtc-audio-processing-2.1.tar.xz"
source_hash=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
abseil_source_hash=f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
abseil_patch_hash=12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b
source_url=https://gstreamer.freedesktop.org/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
mkdir -p "$cache_dir/downloads"

fail() { echo "WebRTC AEC build: $*" >&2; exit 1; }
verify_hash() {
  local expected="$1" file="$2" actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "SHA-256 mismatch for $file: $actual"
}

if [[ ! -f "$archive" ]]; then
  curl --fail --location --retry 3 --output "$archive.partial" "$source_url" || fail "source download failed: $source_url"
  mv "$archive.partial" "$archive"
fi
verify_hash "$source_hash" "$archive"

# Source, bridge, tool versions and CPU architecture all participate in the
# cache key. A stale or partially written build cannot count as a cache hit.
fingerprint="$(
  { shasum -a 256 "$repo_dir/Tools/build-webrtc-audio.sh" "$repo_dir/Vendor/WebRTCAudio/NextNotesAEC.cpp" "$repo_dir/Vendor/WebRTCAudio/NextNotesAEC.h";
    printf '%s\n' "$source_hash" "$abseil_source_hash" "$abseil_patch_hash" "meson=1.12.0" "ninja=1.13.2" "$(uname -m)";
  } | shasum -a 256 | awk '{print $1}'
)"
work_dir="$cache_dir/build-$fingerprint"
output_dir="$work_dir/output"
apm_name=libwebrtc-audio-processing-2.1.dylib
bridge_name=libNextNotesAEC.dylib
publish_current() {
  ln -sfn "$output_dir" "$cache_dir/current.next"
  # BSD mv otherwise follows the existing directory symlink and moves the
  # new link *inside* output, breaking the second cached invocation.
  mv -fh "$cache_dir/current.next" "$cache_dir/current"
}
if [[ -f "$output_dir/manifest.sha256" ]]; then
  if (cd "$output_dir" && shasum -a 256 -c manifest.sha256 >/dev/null 2>&1); then
    publish_current
    echo "$output_dir"
    exit 0
  fi
  fail "cached output failed checksum verification: $output_dir"
fi
# A previous interrupted build may have left these directories. Neither can
# be reused without a valid manifest, and each lives under this fingerprint.
rm -rf "$output_dir" "$work_dir/output.partial"

[[ "$(uname -s)" == Darwin ]] || fail "macOS is required"
mkdir -p "$work_dir"
venv_dir="$cache_dir/venv-meson-1.12.0-ninja-1.13.2"
if [[ ! -x "$venv_dir/bin/meson" || ! -x "$venv_dir/bin/ninja" ]]; then
  python3 -m venv "$venv_dir"
  "$venv_dir/bin/python" -m pip install --disable-pip-version-check 'meson==1.12.0' 'ninja==1.13.2' || fail "could not install pinned build tools into $venv_dir"
fi
[[ "$("$venv_dir/bin/meson" --version)" == 1.12.0 ]] || fail "Meson version mismatch"
[[ "$("$venv_dir/bin/ninja" --version)" == 1.13.2* ]] || fail "Ninja version mismatch"
export PATH="$venv_dir/bin:$PATH"

src_dir="$work_dir/webrtc-audio-processing-2.1"
if [[ ! -f "$src_dir/meson.build" ]]; then
  tar -xJf "$archive" -C "$work_dir" || fail "could not unpack verified source archive"
fi
wrap="$src_dir/subprojects/abseil-cpp.wrap"
[[ -f "$wrap" ]] || fail "upstream archive lacks Abseil wrap"
grep -q "source_hash = $abseil_source_hash" "$wrap" || fail "upstream Abseil source pin changed"
grep -q "patch_hash = $abseil_patch_hash" "$wrap" || fail "upstream Abseil patch pin changed"

build_dir="$work_dir/meson-build"
if [[ ! -f "$build_dir/build.ninja" ]]; then
  "$venv_dir/bin/meson" setup "$build_dir" "$src_dir" \
    --buildtype=release --force-fallback-for=absl_base,absl_flags,absl_strings,absl_numeric,absl_synchronization,absl_bad_optional_access \
    || fail "Meson setup failed; pinned Abseil must be obtainable"
fi
"$venv_dir/bin/ninja" -C "$build_dir" -j "${NEXTNOTES_WEBRTC_JOBS:-4}" || fail "WebRTC APM compilation failed"
apm_path="$build_dir/webrtc/modules/audio_processing/$apm_name"
[[ -f "$apm_path" ]] || fail "Meson did not produce $apm_name"

bridge_path="$work_dir/$bridge_name"
# The diagnostic EchoControlFactory includes AEC3's concrete type. Its layout
# must use the same release/platform definitions as the pinned Meson library,
# including the debug-only race checker and audio-dump members.
bridge_platform_defines=(-DNDEBUG -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_APM_DEBUG_DUMP=0)
if [[ "$(uname -m)" == arm64 ]]; then
  bridge_platform_defines+=(-DWEBRTC_ARCH_ARM64)
else
  bridge_platform_defines+=(-DWEBRTC_ARCH_X86_64)
fi
c++ -std=c++17 -O3 -dynamiclib \
  "${bridge_platform_defines[@]}" \
  -I"$repo_dir/Vendor/WebRTCAudio" \
  -I"$src_dir" -I"$src_dir/webrtc" -I"$build_dir" -I"$build_dir/webrtc" \
  -I"$src_dir/subprojects/abseil-cpp-20240722.0" \
  -I"$build_dir/subprojects/abseil-cpp-20240722.0" \
  "$repo_dir/Vendor/WebRTCAudio/NextNotesAEC.cpp" \
  -L"$(dirname "$apm_path")" -lwebrtc-audio-processing-2.1 \
  -Wl,-install_name,@rpath/$bridge_name \
  -Wl,-rpath,@loader_path \
  -o "$bridge_path" || fail "Next Notes AEC bridge compilation failed"

# Only a successful, complete build is published to output/.
staging="$work_dir/output.partial"
rm -rf "$staging"
mkdir -p "$staging"
cp "$apm_path" "$staging/$apm_name"
cp "$bridge_path" "$staging/$bridge_name"
cp "$src_dir/COPYING" "$staging/WEBRTC-AUDIO-PROCESSING-LICENSE"
cp "$src_dir/webrtc/LICENSE" "$staging/WEBRTC-LICENSE"
cp "$src_dir/webrtc/PATENTS" "$staging/WEBRTC-PATENTS"
cp "$src_dir/subprojects/abseil-cpp-20240722.0/LICENSE" "$staging/ABSEIL-LICENSE"
(cd "$staging" && shasum -a 256 "$apm_name" "$bridge_name" WEBRTC-AUDIO-PROCESSING-LICENSE WEBRTC-LICENSE WEBRTC-PATENTS ABSEIL-LICENSE > manifest.sha256)
mv "$staging" "$output_dir"
publish_current
echo "$output_dir"
