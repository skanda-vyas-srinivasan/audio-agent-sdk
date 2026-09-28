#!/bin/bash
set -euo pipefail

bundle_id="com.audioplane.input.driver"
target_bundle="/Library/Audio/Plug-Ins/HAL/AudioPlaneInput.driver"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0"
  echo "Explicitly removes only the AudioPlane Input HAL driver."
  exit 0
fi
[[ $# -eq 0 ]] || { echo "Usage: $0" >&2; exit 64; }

if [[ ! -e "$target_bundle" ]]; then
  echo "AudioPlane Input is not installed."
  exit 0
fi
[[ -d "$target_bundle" && ! -L "$target_bundle" ]] || {
  echo "Refusing to remove non-directory or symlink: $target_bundle" >&2
  exit 73
}
installed_id="$(plutil -extract CFBundleIdentifier raw "$target_bundle/Contents/Info.plist" 2>/dev/null || true)"
[[ "$installed_id" == "$bundle_id" ]] || {
  echo "Refusing to remove bundle with unexpected ID: ${installed_id:-missing}" >&2
  exit 73
}

echo "Removing exactly: $target_bundle"
echo "sudo will be requested explicitly."
sudo rm -rf -- "$target_bundle"
echo "Removed AudioPlane Input. Restart the Mac to unload it safely."
