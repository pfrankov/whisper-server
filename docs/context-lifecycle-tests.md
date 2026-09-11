# Context lifecycle regression tests

The tests use XCTest and do not require model files, network access, audio files, or waiting for an inactivity timeout.
They are included automatically in the existing file-system-synchronized `WhisperServerTests` target.

## Run on macOS

Use the same Xcode/dependency setup as the app, including its local `whisper.xcframework`:

```sh
xcodebuild test \
  -project WhisperServer.xcodeproj \
  -scheme WhisperServer \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:WhisperServerTests/WhisperContextLifecycleTests \
  -only-testing:WhisperServerTests/WhisperTranscriptionFailureTests
```

The app and its native dependencies still need to build; avoiding model loading in these tests does not remove that requirement.

## Coverage

`WhisperContextLifecycleTests` checks timeout eligibility during an active lease, deferred reinitialization until the final release,
idle reinitialization, repeated requests, additional leases, and underflow protection.

`WhisperTranscriptionFailureTests` calls the real `transcribeChunk` and `transcribeChunkToSegments` entry points with per-call,
internal `ChunkDependencies`. Production defaults continue to call `WhisperContextManager` and whisper.cpp.
There are no mutable global mock hooks and no `#if DEBUG` paths.

The fixture records acquisition/inference/extraction/release order and checks:

- Nonzero inference statuses (-1, 1, -7) return nil, release exactly once, and never read results.
- A failure completes any pending reinitialization on the final lease.
- Failed acquisition never runs inference and does not release a nonexistent lease.
- Isolated contexts are freed once without touching the shared lease count.
- Changing isolation mode during inference does not change the cleanup chosen at acquisition.
- Successful inference retains ownership through result extraction and then releases it.
- Samples, language, prompt, and timestamp settings reach the inference callback intact.

Context handles in the fixture point to fixture-owned storage, never to a real Whisper model. They must only reach the injected
callbacks, not native whisper.cpp inference/free/result accessors. The fixture deallocates its own storage separately.

## Scope

These are deterministic lifecycle and call-site tests, not a replacement for native app validation, GPU/Metal inference,
audio-quality checks, or `./test_api.sh` against a running server. The lifecycle-state tests do not drive a real run-loop timer.
A successful model-free or platform-adapted run must not be reported as a successful native macOS build or audio soak test.
