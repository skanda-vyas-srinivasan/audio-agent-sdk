#!/bin/sh
set -eu
export PIP_DISABLE_PIP_VERSION_CHECK=1

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sonexis-package-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM

cmp "$ROOT_DIR/LICENSE" "$ROOT_DIR/SDKs/python/LICENSE"
cmp "$ROOT_DIR/LICENSE" "$ROOT_DIR/SDKs/typescript/LICENSE"
"$ROOT_DIR/Scripts/check-runtime-version.py"
VERSION=$(sed -n '1p' "$ROOT_DIR/RUNTIME_VERSION")

copy_tracked_tree() {
    SOURCE_PREFIX=$1
    DESTINATION=$2
    mkdir "$DESTINATION"
    git -C "$ROOT_DIR" ls-files "$SOURCE_PREFIX" | while IFS= read -r path; do
        relative=${path#"$SOURCE_PREFIX/"}
        mkdir -p "$DESTINATION/$(dirname -- "$relative")"
        cp "$ROOT_DIR/$path" "$DESTINATION/$relative"
    done
}

mkdir "$TEST_DIR/python-dist"
copy_tracked_tree SDKs/python "$TEST_DIR/python-src"
(
    cd "$TEST_DIR/python-src"
    /usr/bin/python3 setup.py sdist --dist-dir "$TEST_DIR/python-dist" >/dev/null
    /usr/bin/python3 -m pip wheel --no-deps --no-build-isolation \
        --wheel-dir "$TEST_DIR/python-dist" . >/dev/null
)
PYTHON_WHEEL=$(find "$TEST_DIR/python-dist" -type f -name '*.whl' -print -quit)
PYTHON_SDIST=$(find "$TEST_DIR/python-dist" -type f -name '*.tar.gz' -print -quit)
[ -n "$PYTHON_WHEEL" ] && [ -n "$PYTHON_SDIST" ]
unzip -l "$PYTHON_WHEEL" | grep -E 'LICENSE|py\.typed' >/dev/null
tar -tzf "$PYTHON_SDIST" | grep -E '/LICENSE$' >/dev/null

/usr/bin/python3 -m venv "$TEST_DIR/python-wheel-env"
"$TEST_DIR/python-wheel-env/bin/python" -m pip install --no-deps "$PYTHON_WHEEL" >/dev/null
env -u PYTHONPATH "$TEST_DIR/python-wheel-env/bin/python" -c \
    "import audioplane, audioplane.agent, audioplane.providers, importlib.metadata, sonexis, sonexis.mcp_server; assert audioplane.__version__ == '$VERSION'; assert audioplane.AudioPlane is sonexis.Sonexis; assert importlib.metadata.version('audioplane') == '$VERSION'; assert 'python-wheel-env' in sonexis.__file__"
"$TEST_DIR/python-wheel-env/bin/python" - <<'PY'
from importlib.metadata import requires
from pip._vendor.packaging.requirements import Requirement
requirements = [Requirement(item) for item in requires("audioplane") or []]
for extra in ("gemini", "ai"):
    assert any(item.name == "webrtcvad-wheels" and item.marker.evaluate({"extra": extra})
               for item in requirements), "speech VAD dependency missing from " + extra
for extra in ("openai", "ai"):
    matches = [item for item in requirements if item.name == "openai"
               and item.marker.evaluate({"extra": extra, "python_version": "3.10"})]
    assert matches, "OpenAI dependency missing from " + extra
    for item in matches:
        assert "3.24.0" in item.specifier and "2.0.0" not in item.specifier
        assert "4.0.0" not in item.specifier, "unqualified OpenAI major version accepted"
PY
"$TEST_DIR/python-wheel-env/bin/audioplane" version | grep -F "AudioPlane $VERSION" >/dev/null
"$TEST_DIR/python-wheel-env/bin/audioplane" agent --help >/dev/null
test -x "$TEST_DIR/python-wheel-env/bin/audioplane-mcp"
PYTHON="$TEST_DIR/python-wheel-env/bin/python" SONEXIS_EXAMPLES_USE_INSTALLED=1 \
    "$ROOT_DIR/Scripts/test-runtime-examples.sh" >/dev/null

/usr/bin/python3 -m venv --system-site-packages "$TEST_DIR/python-sdist-env"
"$TEST_DIR/python-sdist-env/bin/python" -m pip install --no-deps --no-build-isolation \
    "$PYTHON_SDIST" >/dev/null
env -u PYTHONPATH "$TEST_DIR/python-sdist-env/bin/python" -c \
    "import audioplane, importlib.metadata, sonexis; assert audioplane.AudioPlane is sonexis.Sonexis; assert importlib.metadata.version('audioplane') == '$VERSION'"

copy_tracked_tree SDKs/typescript "$TEST_DIR/typescript-src"
(
    cd "$TEST_DIR/typescript-src"
    npm ci --ignore-scripts >/dev/null
    npm test
    npm pack --pack-destination "$TEST_DIR" >/dev/null
)
TYPESCRIPT_PACKAGE=$(find "$TEST_DIR" -type f -name 'sonexis-runtime-*.tgz' -print -quit)
[ -n "$TYPESCRIPT_PACKAGE" ]
tar -tzf "$TYPESCRIPT_PACKAGE" | grep -E '^package/dist/index\.js$' >/dev/null
tar -tzf "$TYPESCRIPT_PACKAGE" | grep -E '^package/dist/index\.d\.ts$' >/dev/null
tar -tzf "$TYPESCRIPT_PACKAGE" | grep -E '^package/LICENSE$' >/dev/null
if tar -tzf "$TYPESCRIPT_PACKAGE" | grep -E '^package/(src|test|node_modules|dist-test)/' >/dev/null; then
    echo "TypeScript package leaked development-only files" >&2
    exit 1
fi
tar -xOf "$TYPESCRIPT_PACKAGE" package/dist/index.d.ts > "$TEST_DIR/index.d.ts"
if grep -E '^[[:space:]]+(unsubscribe|cleanupCapture|cleanupSubscription|flushOutput|cleanupOutput|untrackOutput|trackCapture|untrackCapture|trackEventStream|untrackEventStream)\(' "$TEST_DIR/index.d.ts" >/dev/null; then
    echo "TypeScript declaration leaked internal lifecycle hooks" >&2
    exit 1
fi
mkdir "$TEST_DIR/typescript-consumer"
(
    cd "$TEST_DIR/typescript-consumer"
    npm init -y >/dev/null
    npm install --ignore-scripts "$TYPESCRIPT_PACKAGE" >/dev/null
    cp "$ROOT_DIR/Examples/typescript-duplex.mts" ./typescript-duplex.mts
    "$TEST_DIR/typescript-src/node_modules/.bin/tsc" --strict --noEmit \
        --module NodeNext --moduleResolution NodeNext --target ES2022 \
        --typeRoots "$TEST_DIR/typescript-src/node_modules/@types" \
        ./typescript-duplex.mts
    node --input-type=module -e \
        'import { Sonexis, AudioFormats } from "@sonexis/runtime"; const sx = new Sonexis("/tmp/not-running.sock"); if (AudioFormats.speech16k().sample_rate !== 16000 || sx.socketPath !== "/tmp/not-running.sock") process.exit(1);'
)

echo "Runtime Python wheel/sdist and TypeScript tarball package tests passed"
