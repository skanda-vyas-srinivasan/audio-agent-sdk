#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
DEFAULT_VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")
ARTIFACT_DIR=${1:-"$ROOT_DIR/.build/runtime-release/$DEFAULT_VERSION"}

error() {
    echo "runtime-artifacts: $*" >&2
    exit 1
}

[ -d "$ARTIFACT_DIR" ] && [ ! -L "$ARTIFACT_DIR" ] || \
    error "missing regular artifact directory: $ARTIFACT_DIR"
ARTIFACT_DIR=$(CDPATH= cd -- "$ARTIFACT_DIR" && pwd -P)
[ -f "$ARTIFACT_DIR/manifest.json" ] && [ ! -L "$ARTIFACT_DIR/manifest.json" ] || \
    error "missing regular manifest.json"
[ -f "$ARTIFACT_DIR/SHA256SUMS" ] && [ ! -L "$ARTIFACT_DIR/SHA256SUMS" ] || \
    error "missing regular SHA256SUMS"

# Validate the complete inventory before executing or unpacking any artifact. This
# deliberately derives the release version from the artifact manifest so a copied
# release can be verified without a matching source checkout.
export ARTIFACT_DIR
VERSION=$(/usr/bin/python3 - <<'PY'
import hashlib
import json
import os
import re
import stat
from pathlib import Path

root = Path(os.environ["ARTIFACT_DIR"])
maximum_metadata_bytes = 1024 * 1024
maximum_artifact_bytes = 512 * 1024 * 1024

def fail(message: str) -> None:
    raise SystemExit(f"runtime-artifacts: {message}")

try:
    if (root / "manifest.json").stat().st_size > maximum_metadata_bytes:
        fail("manifest.json exceeds 1 MiB")
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"invalid manifest.json: {error}")

required_keys = {
    "schema_version", "runtime_version", "protocol_version", "source_commit",
    "platform", "minimum_macos", "architectures", "signing", "artifacts",
}
if set(manifest) != required_keys:
    fail("manifest has missing or unexpected top-level fields")
if manifest["schema_version"] != 1 or manifest["protocol_version"] != 2:
    fail("unsupported artifact manifest or Runtime protocol version")
version = manifest["runtime_version"]
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail("invalid Runtime version in manifest")
if not isinstance(manifest["source_commit"], str) or not re.fullmatch(
    r"[0-9a-f]{40}", manifest["source_commit"]
):
    fail("source_commit must be a full lowercase Git object ID")
expected_commit = os.environ.get("SONEXIS_EXPECTED_SOURCE_COMMIT")
if expected_commit and manifest["source_commit"] != expected_commit:
    fail("source_commit differs from the trusted expected commit")
if manifest["platform"] != "macos" or manifest["minimum_macos"] != "14.4":
    fail("unexpected platform or deployment target")
if manifest["architectures"] != ["arm64", "x86_64"]:
    fail("unexpected architecture declaration")
signing = manifest["signing"]
expected_signing_keys = {
    "kind", "team_identifier", "runtime_identifier", "cli_identifier", "notarized",
}
if not isinstance(signing, dict) or set(signing) != expected_signing_keys:
    fail("invalid signing declaration")
if signing["kind"] != "Apple Development" or signing["notarized"] is not False:
    fail("unexpected signing kind or notarization declaration")
if signing["runtime_identifier"] != "com.sonexis.runtime":
    fail("unexpected Runtime signing identifier")
if signing["cli_identifier"] != "com.sonexis.ctl":
    fail("unexpected CLI signing identifier")
if not isinstance(signing["team_identifier"], str) or not re.fullmatch(
    r"[A-Z0-9]{10}", signing["team_identifier"]
):
    fail("invalid signing team identifier")
expected_team = os.environ.get("SONEXIS_EXPECTED_TEAM_ID")
if expected_team and signing["team_identifier"] != expected_team:
    fail("signing team differs from the trusted expected team")

expected_artifacts = {
    f"sonexis-runtime-{version}-macos-universal",
    f"sonexisctl-{version}-macos-universal",
    f"sonexis-{version}-py3-none-any.whl",
    f"sonexis-{version}.tar.gz",
    f"sonexis-runtime-{version}.tgz",
}
items = manifest["artifacts"]
if not isinstance(items, list) or len(items) != len(expected_artifacts):
    fail("manifest must contain exactly five release artifacts")
listed = {}
for item in items:
    if not isinstance(item, dict) or set(item) != {"name", "size_bytes", "sha256"}:
        fail("invalid artifact entry")
    name = item["name"]
    if name in listed or name not in expected_artifacts:
        fail(f"duplicate or unexpected artifact: {name!r}")
    if not isinstance(item["size_bytes"], int) or isinstance(item["size_bytes"], bool) \
            or item["size_bytes"] <= 0 or item["size_bytes"] > maximum_artifact_bytes:
        fail(f"invalid size for artifact: {name}")
    if not isinstance(item["sha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", item["sha256"]
    ):
        fail(f"invalid digest for artifact: {name}")
    listed[name] = item
if set(listed) != expected_artifacts:
    fail("artifact manifest inventory is incomplete")

actual_names = {path.name for path in root.iterdir()}
expected_names = expected_artifacts | {"manifest.json", "SHA256SUMS"}
if actual_names != expected_names:
    fail(f"artifact directory inventory differs: {sorted(actual_names ^ expected_names)}")

def require_regular_file(path: Path) -> None:
    mode = path.lstat().st_mode
    if not stat.S_ISREG(mode):
        fail(f"artifact is not a regular file: {path.name}")

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()

for name, item in listed.items():
    path = root / name
    require_regular_file(path)
    if path.stat().st_size != item["size_bytes"]:
        fail(f"artifact size differs: {name}")
    if sha256_file(path) != item["sha256"]:
        fail(f"artifact digest differs: {name}")

checksum_path = root / "SHA256SUMS"
require_regular_file(checksum_path)
try:
    if checksum_path.stat().st_size > maximum_metadata_bytes:
        fail("SHA256SUMS exceeds 1 MiB")
    checksum_lines = checksum_path.read_text(encoding="ascii").splitlines()
except (OSError, UnicodeError) as error:
    fail(f"invalid SHA256SUMS: {error}")
expected_checksum_names = sorted(expected_artifacts | {"manifest.json"})
if len(checksum_lines) != len(expected_checksum_names):
    fail("SHA256SUMS has an unexpected number of entries")
checksums = {}
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
    if not match or match.group(2) in checksums:
        fail("SHA256SUMS contains an invalid or duplicate entry")
    checksums[match.group(2)] = match.group(1)
if sorted(checksums) != expected_checksum_names:
    fail("SHA256SUMS inventory differs from the manifest")
for name, expected in checksums.items():
    path = root / name
    require_regular_file(path)
    if sha256_file(path) != expected:
        fail(f"SHA256SUMS digest differs: {name}")

print(version)
PY
)

RUNTIME="$ARTIFACT_DIR/sonexis-runtime-$VERSION-macos-universal"
CTL="$ARTIFACT_DIR/sonexisctl-$VERSION-macos-universal"
MANIFEST_TEAM=$(/usr/bin/python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["signing"]["team_identifier"])' \
    "$ARTIFACT_DIR/manifest.json")
EXPECTED_TEAM=${SONEXIS_EXPECTED_TEAM_ID:-}
if [ -n "$EXPECTED_TEAM" ] && [ "$MANIFEST_TEAM" != "$EXPECTED_TEAM" ]; then
    error "signing team differs from trusted SONEXIS_EXPECTED_TEAM_ID"
fi

verify_product() {
    product=$1
    expected_identifier=$2
    [ -f "$product" ] && [ ! -L "$product" ] && [ -x "$product" ] || \
        error "missing executable product: $product"
    codesign --verify --strict "$product" || error "invalid code signature: $product"
    metadata=$(codesign -dvv "$product" 2>&1)
    printf '%s\n' "$metadata" | grep -F "Identifier=$expected_identifier" >/dev/null || \
        error "unexpected signing identifier: $product"
    printf '%s\n' "$metadata" | grep -F 'Authority=Apple Development:' >/dev/null || \
        error "product is not Apple Development signed: $product"
    team=$(printf '%s\n' "$metadata" | sed -n 's/^TeamIdentifier=//p')
    [ -n "$team" ] || error "missing signing team: $product"
    [ "$team" = "$MANIFEST_TEAM" ] || error "signing team differs from manifest: $product"
    archs=$(lipo -archs "$product")
    case " $archs " in *' arm64 '*) ;; *) error "missing arm64 slice: $product" ;; esac
    case " $archs " in *' x86_64 '*) ;; *) error "missing x86_64 slice: $product" ;; esac
    [ "$(xcrun vtool -show-build "$product" | grep -c 'minos 14.4')" -eq 2 ] || \
        error "expected macOS 14.4 for both slices: $product"
    entitlements=$(codesign -d --entitlements :- "$product" 2>&1 || true)
    if printf '%s\n' "$entitlements" | grep -F 'com.apple.security.get-task-allow' >/dev/null; then
        error "Release product contains get-task-allow: $product"
    fi
}

verify_product "$RUNTIME" com.sonexis.runtime
verify_product "$CTL" com.sonexis.ctl
plutil -p "$RUNTIME" | grep -F \
    '"CFBundleShortVersionString" => "'"$VERSION"'"' >/dev/null || \
    error "Runtime embedded version differs from manifest"
strings "$CTL" | grep -Fx "$VERSION" >/dev/null || \
    error "CLI embedded version differs from manifest"
strings "$RUNTIME" | grep -F '<key>NSAudioCaptureUsageDescription</key>' >/dev/null || \
    error "Runtime is missing NSAudioCaptureUsageDescription"

export VERSION
/usr/bin/python3 - <<'PY'
import email.parser
import io
import json
import os
import pathlib
import tarfile
import zipfile

root = pathlib.Path(os.environ["ARTIFACT_DIR"])
version = os.environ["VERSION"]
maximum_entries = 10_000
maximum_uncompressed_bytes = 256 * 1024 * 1024
maximum_metadata_bytes = 1024 * 1024

def fail(message: str) -> None:
    raise SystemExit(f"runtime-artifacts: {message}")

def safe_archive_name(name: str) -> bool:
    path = pathlib.PurePosixPath(name)
    return bool(name) and not path.is_absolute() and ".." not in path.parts

wheel = root / f"sonexis-{version}-py3-none-any.whl"
try:
    with zipfile.ZipFile(wheel) as archive:
        entries = archive.infolist()
        if len(entries) > maximum_entries:
            fail("Python wheel has too many entries")
        if sum(entry.file_size for entry in entries) > maximum_uncompressed_bytes:
            fail("Python wheel expands beyond 256 MiB")
        names = [entry.filename for entry in entries]
        if any(not safe_archive_name(name) for name in names):
            fail("Python wheel contains an unsafe path")
        required = {"sonexis/__init__.py", "sonexis/py.typed"}
        if not required.issubset(names):
            fail("Python wheel is missing package or typing metadata")
        metadata_names = [name for name in names if name.endswith(".dist-info/METADATA")]
        license_names = [name for name in names if name.endswith(".dist-info/LICENSE")]
        if len(metadata_names) != 1 or len(license_names) != 1:
            fail("Python wheel has unexpected distribution metadata")
        if archive.getinfo(metadata_names[0]).file_size > maximum_metadata_bytes:
            fail("Python wheel metadata exceeds 1 MiB")
        metadata = email.parser.BytesParser().parsebytes(archive.read(metadata_names[0]))
        if metadata.get("Name") != "sonexis" or metadata.get("Version") != version:
            fail("Python wheel name/version differs from manifest")
except (OSError, zipfile.BadZipFile) as error:
    fail(f"invalid Python wheel: {error}")

sdist = root / f"sonexis-{version}.tar.gz"
try:
    with tarfile.open(sdist, "r:gz") as archive:
        members = archive.getmembers()
        if len(members) > maximum_entries:
            fail("Python sdist has too many entries")
        if sum(member.size for member in members) > maximum_uncompressed_bytes:
            fail("Python sdist expands beyond 256 MiB")
        if any(not safe_archive_name(member.name) for member in members):
            fail("Python sdist contains an unsafe path")
        if any(member.issym() or member.islnk() or member.isdev() for member in members):
            fail("Python sdist contains links or device entries")
        names = {member.name for member in members}
        prefix = f"sonexis-{version}/"
        if prefix + "LICENSE" not in names or prefix + "pyproject.toml" not in names:
            fail("Python sdist is missing release metadata")
except (OSError, tarfile.TarError) as error:
    fail(f"invalid Python sdist: {error}")

npm_package = root / f"sonexis-runtime-{version}.tgz"
try:
    with tarfile.open(npm_package, "r:gz") as archive:
        members = archive.getmembers()
        if len(members) > maximum_entries:
            fail("TypeScript package has too many entries")
        if sum(member.size for member in members) > maximum_uncompressed_bytes:
            fail("TypeScript package expands beyond 256 MiB")
        if any(not safe_archive_name(member.name) for member in members):
            fail("TypeScript package contains an unsafe path")
        if any(member.issym() or member.islnk() or member.isdev() for member in members):
            fail("TypeScript package contains links or device entries")
        names = {member.name for member in members}
        required = {
            "package/package.json", "package/LICENSE", "package/dist/index.js",
            "package/dist/index.d.ts",
        }
        if not required.issubset(names):
            fail("TypeScript package is missing runtime or type declarations")
        if any(name.startswith(("package/src/", "package/test/", "package/node_modules/"))
               for name in names):
            fail("TypeScript package contains development-only files")
        package_member = archive.extractfile("package/package.json")
        if package_member is None:
            fail("TypeScript package.json is not a regular file")
        package_info = archive.getmember("package/package.json")
        if package_info.size > maximum_metadata_bytes:
            fail("TypeScript package metadata exceeds 1 MiB")
        package = json.load(io.TextIOWrapper(package_member, encoding="utf-8"))
        if package.get("name") != "@sonexis/runtime" or package.get("version") != version:
            fail("TypeScript package name/version differs from manifest")
except (OSError, tarfile.TarError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"invalid TypeScript package: {error}")
PY

echo "Sonexis Runtime $VERSION signed artifacts, packages, manifest, and checksums passed"
