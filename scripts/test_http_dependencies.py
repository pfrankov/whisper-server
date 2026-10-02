#!/usr/bin/env python3
"""Exercise the HTTP stack using the app's exact package pins, without models/SDKs."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LOCK = ROOT / 'WhisperServer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lock-file', type=Path, default=DEFAULT_LOCK)
args = parser.parse_args()
pins = json.loads(args.lock_file.read_text())['pins']
# FluidAudio is unrelated to the HTTP stack and needs the native app to validate.
http_pins = [pin for pin in pins if pin['identity'] != 'fluidaudio']
with tempfile.TemporaryDirectory(prefix='whisper-http-tests-') as directory:
    root = Path(directory)
    dependencies = ',\n'.join(
        f'        .package(url: "{pin["location"]}", exact: "{pin["state"]["version"]}")'
        for pin in http_pins
    )
    (root / 'Package.swift').write_text('''// swift-tools-version:6.1
import PackageDescription
let package = Package(
    name: "WhisperHTTPDependencyTests",
    platforms: [.macOS(.v14)],
    dependencies: [
''' + dependencies + '''
    ],
    targets: [.testTarget(name: "HTTPDependencyTests", dependencies: [
        .product(name: "XCTVapor", package: "vapor"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOEmbedded", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOHTTPCompression", package: "swift-nio-extras")
    ])]
)
''')
    shutil.copytree(ROOT / 'Tests/HTTPDependencies', root / 'Tests/HTTPDependencyTests')
    subprocess.run(['swift', 'package', '--package-path', str(root), 'resolve'], check=True)
    resolved = json.loads((root / 'Package.resolved').read_text())['pins']
    expected = {pin['identity']: pin['state'] for pin in http_pins}
    actual = {pin['identity']: pin['state'] for pin in resolved}
    if actual != expected:
        raise SystemExit(f'Resolver changed the reviewed package graph: {actual!r}')
    print('Verified exact versions and revisions for all HTTP dependency pins', flush=True)
    subprocess.run(['swift', 'test', '--package-path', str(root)], check=True)
