#!/bin/bash
# Build the public native SDK at the revision used by the 2.9.0 release.
set -euo pipefail
: "${CI:?This script is intended for a disposable CI runner}"
: "${RUNNER_TEMP:?}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK_ROOT="$ROOT/../../calls/whisper.cpp"
WHISPER_REVISION=1da4dc82fa7996d4edda05890dca65aeceaafd6d
if [ -e "$SDK_ROOT" ]; then
    echo "Refusing to replace an existing SDK checkout: $SDK_ROOT" >&2
    exit 1
fi
mkdir -p "$SDK_ROOT"
git -C "$SDK_ROOT" init -q
git -C "$SDK_ROOT" remote add origin https://github.com/ggerganov/whisper.cpp.git
git -C "$SDK_ROOT" fetch --depth 1 origin "$WHISPER_REVISION"
git -C "$SDK_ROOT" checkout --detach FETCH_HEAD
test "$(git -C "$SDK_ROOT" rev-parse HEAD)" = "$WHISPER_REVISION"
cd "$SDK_ROOT"
# Reuse the upstream helpers and exact macOS build options without building iOS,
# tvOS and visionOS slices that this macOS-only app cannot use.
python3 - <<'PY'
from pathlib import Path
source = Path('build-xcframework.sh').read_text()
common = source[:source.index('echo "Building for iOS simulator..."')]
macos = source[source.index('echo "Building for macOS..."'):source.index('echo "Building for visionOS..."')]
Path('build-ci-macos.sh').write_text(common + macos + '''
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"
combine_static_libraries "build-macos" "Release" "macos" "false"
xcodebuild -create-xcframework -framework "$(pwd)/build-macos/framework/whisper.framework" -output "$(pwd)/build-apple/whisper.xcframework"
''')
PY
bash build-ci-macos.sh
cd "$ROOT"
COMMON=(-project WhisperServer.xcodeproj -scheme WhisperServer -destination 'platform=macOS,arch=arm64' -derivedDataPath "$RUNNER_TEMP/whisper-build" -clonedSourcePackagesDirPath "$RUNNER_TEMP/whisper-packages" -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO)
xcodebuild test "${COMMON[@]}" -only-testing:WhisperServerTests -skip-testing:WhisperServerUITests
xcodebuild build "${COMMON[@]}" -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
APP="$RUNNER_TEMP/whisper-build/Build/Products/Release/WhisperServer.app"
codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign - --entitlements WhisperServer/WhisperServerRelease.entitlements "$APP"
codesign --verify --deep --strict "$APP"
test "$(lipo -archs "$APP/Contents/MacOS/WhisperServer")" = arm64
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = 2.9.1
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = 11
git diff --exit-code -- WhisperServer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
mkdir -p "$RUNNER_TEMP/whisper-artifact"
export APP WHISPER_REVISION
python3 - <<'PY'
import hashlib, json, os, pathlib, subprocess
root = pathlib.Path.cwd()
lock = root / 'WhisperServer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
pins = json.loads(lock.read_text())['pins']
checkouts = pathlib.Path(os.environ['RUNNER_TEMP']) / 'whisper-packages/checkouts'
actual = {subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip() for path in checkouts.iterdir() if path.is_dir()}
assert all(pin['state']['revision'] in actual for pin in pins), 'A built package checkout does not match the reviewed lockfile'
app = pathlib.Path(os.environ['APP'])
proof = {
    'app_version': '2.9.1', 'build': '11', 'architecture': 'arm64',
    'app_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'whisper_cpp_revision': os.environ['WHISPER_REVISION'],
    'signing': 'ad-hoc; not notarized', 'packages': pins,
    'executable_sha256': hashlib.sha256((app / 'Contents/MacOS/WhisperServer').read_bytes()).hexdigest(),
    'whisper_framework_sha256': hashlib.sha256((app / 'Contents/Frameworks/whisper.framework/whisper').read_bytes()).hexdigest(),
}
(pathlib.Path(os.environ['RUNNER_TEMP']) / 'whisper-artifact/build-provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
PY
ditto -c -k --sequesterRsrc --keepParent "$APP" "$RUNNER_TEMP/whisper-artifact/WhisperServer.zip"
shasum -a 256 "$RUNNER_TEMP/whisper-artifact/WhisperServer.zip"
