"""Package and verify the existing ad-hoc macOS distribution in hosted CI."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess

root = Path(os.environ['QA_ROOT'])
app = root / 'DerivedData/Build/Products/Release/WhisperServer.app'
output = root / 'distribution'
output.mkdir()
extracted = root / 'extracted'
entitlements = Path('WhisperServer/WhisperServerRelease.entitlements')
lock = Path('WhisperServer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved')


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(bundle):
    run('codesign', '--verify', '--deep', '--strict', str(bundle))
    info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'pfrankov.WhisperServer'
    assert info['CFBundleShortVersionString'] == '2.10.0'
    assert info['CFBundleVersion'] == '11'
    assert info['LSMinimumSystemVersion'] == '14.6'
    executable = bundle / 'Contents/MacOS/WhisperServer'
    framework = bundle / 'Contents/Frameworks/whisper.framework/whisper'
    assert run('lipo', '-archs', str(executable)).decode().strip() == 'arm64'
    assert 'arm64' in run('lipo', '-archs', str(framework)).decode().split()
    actual = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
    assert plistlib.loads(actual) == plistlib.loads(entitlements.read_bytes())
    for code in [bundle, bundle / 'Contents/Frameworks/whisper.framework']:
        assert 'Signature=adhoc' in run('codesign', '-dvv', str(code)).decode()
    return {'info': info, 'entitlements': plistlib.loads(actual),
            'executable_sha256': digest(executable), 'whisper_framework_sha256': digest(framework)}


# Sign nested code first; the app alone receives its existing Release entitlements.
run('codesign', '--force', '--sign', '-', str(app / 'Contents/Frameworks/whisper.framework'))
run('codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app))
before = inspect(app)
archive = output / 'WhisperServer.zip'
run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
run('ditto', '-x', '-k', str(archive), str(extracted))
assert inspect(extracted / app.name) == before, 'ZIP changed signed app metadata or binaries'
# Verify every regular file and symlink survived packaging, not only the executable.
for path in app.rglob('*'):
    copy = extracted / app.name / path.relative_to(app)
    if path.is_symlink():
        assert copy.is_symlink() and os.readlink(copy) == os.readlink(path)
    elif path.is_file():
        assert digest(copy) == digest(path)
assert lock.read_bytes() == (root / 'evidence/Package.resolved').read_bytes()
pins = json.loads(lock.read_text())['pins']
checkouts = root / 'DerivedData/SourcePackages/checkouts'
actual = {run('git', '-C', str(path), 'rev-parse', 'HEAD').decode().strip()
          for path in checkouts.iterdir() if path.is_dir()}
assert all(pin['state']['revision'] in actual for pin in pins), 'Resolved package revision mismatch'
revision = run('git', '-C', str(root / 'whisper.cpp'), 'rev-parse', 'HEAD').decode().strip()
assert revision == os.environ['WHISPER_REVISION']
proof = dict(before, app_commit=run('git', 'rev-parse', 'HEAD').decode().strip(),
             whisper_cpp_revision=revision, packages=pins, archive_sha256=digest(archive),
             signing='ad-hoc; not notarized', architecture='arm64',
             validation='Extracted signature, entitlements, metadata and file hashes verified; API QA runs next.')
(output / 'build-provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
(output / 'SHA256SUMS').write_text(digest(archive) + '  WhisperServer.zip\n')
print(json.dumps(proof, indent=2))
