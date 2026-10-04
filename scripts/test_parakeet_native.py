"""Hosted macOS model QA. Uses synthetic speech and the existing Fluid API suite."""
import json
import hashlib
import plistlib
import os
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

root = Path(os.environ['QA_ROOT'])
evidence = root / 'evidence'
audio = root / 'sample.wav'
models = ['parakeet-tdt-0.6b-v2', 'parakeet-tdt-0.6b-v3']


def run(args, **kwargs):
    return subprocess.run(args, check=True, timeout=kwargs.pop('timeout', 60), **kwargs)


if sys.argv[1] == 'prepare':
    voices = subprocess.check_output(['say', '-v', '?'], text=True)
    voice = next(line.split('en_US')[0].strip() for line in voices.splitlines() if 'en_US' in line)
    run(['say', '-v', voice, '-r', '140', '-o', str(root / 'sample.aiff'),
         'The quick brown fox jumps over the lazy dog. Today is a good day to test speech recognition.'])
    run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(root / 'sample.aiff'), str(audio)])
    (evidence / 'voice.txt').write_text(voice)
    project = Path('WhisperServer.xcodeproj/project.pbxproj')
    old = '../../calls/whisper.cpp/build-apple/whisper.xcframework'
    source = project.read_text()
    assert source.count(old) == 1
    project.write_text(source.replace(old, str(root / 'whisper.cpp/build-apple/whisper.xcframework')))
    scheme = Path('WhisperServer.xcodeproj/xcshareddata/xcschemes/WhisperServer.xcscheme')
    tree = ET.parse(scheme)
    action = tree.getroot().find('TestAction')
    action.set('shouldUseLaunchSchemeArgsEnv', 'NO')
    env = ET.SubElement(action, 'EnvironmentVariables')
    ET.SubElement(env, 'EnvironmentVariable', key='PARAKEET_QA_AUDIO', value=str(audio), isEnabled='YES')
    # This checkout has no UI test sources; run the existing unit test target.
    for test in list(action.find('Testables')):
        if test.find('BuildableReference').get('BlueprintName') == 'WhisperServerUITests':
            action.find('Testables').remove(test)
    tree.write(scheme, encoding='unicode')
    sys.exit(0)

assert sys.argv[1] == 'api'
configuration = sys.argv[2] if len(sys.argv) > 2 else 'Debug'
assert configuration in ['Debug', 'Release']
evidence = evidence / configuration
evidence.mkdir(parents=True, exist_ok=True)
bundle = root / 'DerivedData/Build/Products' / configuration / 'WhisperServer.app'
app = bundle / 'Contents/MacOS/WhisperServer'
info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
provenance = {
    'configuration': configuration,
    'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'executable_sha256': hashlib.sha256(app.read_bytes()).hexdigest(),
    'architecture': subprocess.check_output(['lipo', '-archs', str(app)], text=True).strip(),
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'signing': 'unsigned CI build, not a distribution artifact',
}
assert provenance['architecture'] == 'arm64'
(evidence / 'provenance.json').write_text(json.dumps(provenance, indent=2))
print(json.dumps(provenance), flush=True)
# Use v2 for startup preparation and requests without a model parameter.
run(['defaults', 'write', 'pfrankov.WhisperServer', 'selectedProvider', 'fluid'])
run(['defaults', 'write', 'pfrankov.WhisperServer', 'selectedFluidModelID', models[0]])
base = 'http://localhost:12017'
listener = subprocess.run(['lsof', '-nP', '-iTCP:12017', '-sTCP:LISTEN', '-t'], capture_output=True, text=True)
assert listener.returncode == 1 and not listener.stdout.strip(), 'Port 12017 already occupied'
with (evidence / 'app.log').open('w') as log:
    process = subprocess.Popen([str(app)], stdout=log, stderr=subprocess.STDOUT)
    try:
        for _ in range(120):
            assert process.poll() is None, 'App exited during startup'
            ready = subprocess.run(['curl', '-sf', '--max-time', '2', base + '/v1/models'], capture_output=True, text=True)
            if ready.returncode == 0:
                break
            time.sleep(1)
        else:
            raise AssertionError('Server startup timed out')
        catalog = json.loads(ready.stdout)['data']
        (evidence / 'models.json').write_text(ready.stdout)
        assert next(m for m in catalog if m['id'] == models[0])['default']
        assert not next(m for m in catalog if m['id'] == models[1])['default']
        v3_aliases = next(m for m in catalog if m['id'] == models[1])['aliases']
        assert {'default', 'fluid-default'} <= set(v3_aliases)
        print(configuration + ': catalog, v2 persisted startup selection and v3 aliases passed', flush=True)
        # Existing validators cover all five formats, SSE/chunked and opt-in diarization.
        env = dict(os.environ, TEST_AUDIO=str(audio), FLUID_MODELS_OVERRIDE=','.join(models))
        with (evidence / 'api-suite.log').open('w') as output:
            run(['bash', 'test_api.sh', '--only=fluid'], env=env, stdout=output, stderr=subprocess.STDOUT, timeout=1800)
        print(configuration + ': Fluid suite passed for v2 and v3 (formats, streaming, diarization)', flush=True)
        for model in [None, models[1], models[0], 'default', 'fluid-default']:
            args = ['curl', '-sf', '--max-time', '180', '-F', 'file=@' + str(audio), '-F', 'response_format=json']
            if model:
                args += ['-F', 'model=' + model]
            result = run(args + [base + '/v1/audio/transcriptions'], capture_output=True, text=True, timeout=190)
            assert json.loads(result.stdout)['text'].strip()
            (evidence / ((model or 'selected') + '.json')).write_text(result.stdout)
            print(configuration + ': transcription passed for ' + (model or 'persisted selection'), flush=True)
        for model in models:
            for fmt in ['srt', 'vtt', 'verbose_json']:
                result = run(['curl', '-sS', '--max-time', '30', '-w', '\n%{http_code}',
                              '-F', 'file=@' + str(audio), '-F', 'model=' + model, '-F', 'stream=true',
                              '-F', 'response_format=' + fmt, base + '/v1/audio/transcriptions'], capture_output=True, text=True)
                body, status = result.stdout.rsplit('\n', 1)
                assert status == '400' and 'only text/json' in json.loads(body)['error']
        print(configuration + ': six timestamp-streaming rejections passed', flush=True)
        (evidence / 'api-passed.txt').write_text('Fluid suite, selected/default aliases, sequential switching and timestamp streaming rejection passed.\n')
    finally:
        process.terminate()
        try:
            process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
