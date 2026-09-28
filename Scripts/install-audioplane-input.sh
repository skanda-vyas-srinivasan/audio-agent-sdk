#!/bin/bash
set -euo pipefail

bundle_id="com.audioplane.input.driver"
bundle_name="AudioPlaneInput.driver"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_bundle="$repo_root/AudioPlaneHALDriver/.build/$bundle_name"
install_root="/Library/Audio/Plug-Ins/HAL"
target_bundle="$install_root/$bundle_name"

usage() {
  echo "Usage: $0 [--bundle PATH]"
  echo
  echo "Explicitly installs the built AudioPlane Input HAL driver."
  echo "This command invokes sudo but does not restart Core Audio automatically."
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "${1:-}" == "--bundle" ]]; then
  [[ $# -eq 2 ]] || { usage >&2; exit 64; }
  source_bundle="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
elif [[ $# -ne 0 ]]; then
  usage >&2
  exit 64
fi

[[ -d "$source_bundle" ]] || {
  echo "AudioPlane Input bundle not found: $source_bundle" >&2
  echo "Build it first: make -C '$repo_root/AudioPlaneHALDriver' clean all test inspect" >&2
  exit 66
}

actual_id="$(plutil -extract CFBundleIdentifier raw "$source_bundle/Contents/Info.plist")"
[[ "$actual_id" == "$bundle_id" ]] || {
  echo "Refusing to install unexpected bundle ID: $actual_id" >&2
  exit 65
}
codesign --verify --strict --verbose=2 "$source_bundle"

if [[ -e "$target_bundle" ]]; then
  [[ -d "$target_bundle" && ! -L "$target_bundle" ]] || {
    echo "Refusing to replace non-directory or symlink: $target_bundle" >&2
    exit 73
  }
  installed_id="$(plutil -extract CFBundleIdentifier raw "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$installed_id" == "$bundle_id" ]] || {
    echo "Refusing to replace bundle with unexpected ID: ${installed_id:-missing}" >&2
    exit 73
  }
fi

echo "Installing $source_bundle"
echo "       to $target_bundle"
echo "sudo will be requested explicitly for this system-wide Core Audio plug-in."
sudo install -d -o root -g wheel -m 755 "$install_root"
if [[ -e "$target_bundle" ]]; then
  sudo rm -rf -- "$target_bundle"
fi
sudo ditto --noqtn "$source_bundle" "$target_bundle"
sudo chown -R root:wheel "$target_bundle"
sudo chmod -R a+rX,go-w "$target_bundle"

installed_id="$(plutil -extract CFBundleIdentifier raw "$target_bundle/Contents/Info.plist")"
[[ "$installed_id" == "$bundle_id" ]]
codesign --verify --strict --verbose=2 "$target_bundle"

echo
echo "Installed AudioPlane Input successfully."
echo "Restart the Mac to load it safely, then verify it in Audio MIDI Setup."
echo "This script did not change the default input/output device."
