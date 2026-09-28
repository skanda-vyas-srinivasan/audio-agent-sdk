#!/bin/bash
set -euo pipefail

bundle_id="com.audioplane.input.driver"
bundle_name="AudioPlaneInput.driver"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_bundle="$repo_root/AudioPlaneHALDriver/.build/$bundle_name"
install_root="/Library/Audio/Plug-Ins/HAL"
target_bundle="$install_root/$bundle_name"

usage() {
  echo "Usage: $0 [--bundle PATH] [--check]"
  echo
  echo "Explicitly installs the built AudioPlane Input HAL driver."
  echo "--check validates the exact bundle and target without invoking sudo."
  echo "This command invokes sudo but does not restart Core Audio automatically."
}

check_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --check) check_only=true; shift ;;
    --bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 64; }
      source_bundle="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
      shift 2
      ;;
    *) usage >&2; exit 64 ;;
  esac
done

[[ -d "$source_bundle" ]] || {
  echo "AudioPlane Input bundle not found: $source_bundle" >&2
  echo "Build it first: make -C '$repo_root/AudioPlaneHALDriver' clean all test inspect" >&2
  exit 66
}
[[ ! -L "$source_bundle" ]] || {
  echo "Refusing to install a symlinked driver bundle: $source_bundle" >&2
  exit 65
}

actual_id="$(plutil -extract CFBundleIdentifier raw "$source_bundle/Contents/Info.plist")"
[[ "$actual_id" == "$bundle_id" ]] || {
  echo "Refusing to install unexpected bundle ID: $actual_id" >&2
  exit 65
}
codesign --verify --strict --verbose=2 "$source_bundle"
signature_info="$(codesign -dvv "$source_bundle" 2>&1)"
team_id="$(printf '%s\n' "$signature_info" | sed -n 's/^TeamIdentifier=//p')"
[[ -n "$team_id" && "$team_id" != "not set" ]] || {
  echo "Refusing to install an ad-hoc-signed driver." >&2
  echo "Build it with: '$repo_root/Scripts/build-audioplane-input-dev.sh'" >&2
  exit 65
}
printf '%s\n' "$signature_info" \
  | grep -E '^Authority=(Apple Development|Developer ID Application):' >/dev/null || {
    echo "Refusing driver without an Apple Development or Developer ID signature." >&2
    exit 65
  }

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

if [[ "$check_only" == true ]]; then
  echo "AudioPlane Input install preflight passed."
  echo "  source: $source_bundle"
  echo "  target: $target_bundle"
  echo "  team:   $team_id"
  exit 0
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
