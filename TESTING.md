# WhisperServer — Testing Guide (Simple)

This document shows how to test WhisperServer quickly and reliably. The server is compatible with the OpenAI Whisper API and runs on your Mac.

## TL;DR
1) Start the app (menu bar) and wait until the server is ready at http://localhost:12017
2) Put a small audio file in the project root (for example `jfk.wav`)
3) Run the test script: `./test_api.sh`

## Requirements
- macOS 14.6 or newer (Apple Silicon only)
- WhisperServer is running (menu bar app) on `http://localhost:12017`
- At least one model is available/selected (the app can download models automatically)
- Test audio file in the repo root
  - If you don’t have it, download: `curl -O https://github.com/openai/whisper/raw/main/tests/jfk.wav`

## What the tests cover
- Endpoint compatibility with the OpenAI Whisper API
  - GET `/v1/models`
  - POST `/v1/audio/transcriptions`
- Response formats: `json` (default), `text`, `srt`, `vtt`, `verbose_json`
- Streaming: Server‑Sent Events (SSE) and HTTP chunked fallback
- Optional diarization when using the Fluid provider (adds `speaker_segments` to JSON)

## Run the script tests
The script uses `curl` and checks multiple paths and formats.

- Run everything:
  - `./test_api.sh`

- Run specific groups:
  - `./test_api.sh --list-groups`
  - `./test_api.sh --only=models`
  - `./test_api.sh --only=whisper`
  - `./test_api.sh --only=fluid`
  - You can combine: `./test_api.sh --only=models,negative`

Notes
- The script talks to `http://localhost:12017`
- It discovers models from `WhisperServer/Models.json` (Whisper) and from `FluidTranscriptionService.swift` (Fluid)
- Exit code is non‑zero if a check fails

## Manual API testing (quick examples)

Basic JSON (default format):
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav
```

Text format:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F response_format=text
```

Verbose JSON (with segments):
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F response_format=verbose_json
```

SRT subtitles:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F response_format=srt
```

VTT subtitles:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F response_format=vtt
```

Streaming (SSE), JSON chunks:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -H "Accept: text/event-stream" \
  -F file=@jfk.wav \
  -F response_format=json \
  -F stream=true \
  --no-buffer
```

Streaming (chunked), text chunks:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F response_format=text \
  -F stream=true \
  --no-buffer
```

Diarization (Fluid provider only):
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@jfk.wav \
  -F model=parakeet-tdt-0.6b-v3 \
  -F response_format=json \
  -F diarize=true
```
Response will include `speaker_segments` in JSON when diarization is enabled and a Fluid model is used.

## Endpoint and parameters

GET `/v1/models` — lists available models from both providers (Whisper and Fluid). Useful to check IDs and defaults.

POST `/v1/audio/transcriptions` — multipart form fields:
- `file` (required): audio file (wav, mp3, m4a)
- `model` (optional): model ID (works for both providers)
- `response_format` (optional): `json` (default), `text`, `srt`, `vtt`, `verbose_json`
- `language` (optional): ISO‑639‑1 code, e.g. `en`
- `prompt` (optional): text prompt
- `stream` (optional): `true`/`false` — enables streaming
- `diarize` (optional): `true`/`false` — Fluid provider only; adds `speaker_segments` in JSON

Content‑type returned depends on `response_format`. SSE responses use `text/event-stream` and always end with an `end` event.

## Building (optional)
Most tests are HTTP-level and do not require building from source. If you want to build:
- Build: `xcodebuild build -project WhisperServer.xcodeproj -scheme WhisperServer`
- There is a small Swift test target; you can run tests from Xcode if available for your setup.

## Troubleshooting
- Server not running
  - Start the app and wait for “server started”
  - Ensure it is on `http://localhost:12017`
- No model configured
  - Pick a model in the menu bar (the app can download it)
  - Check `GET /v1/models` to see available models and defaults
- Audio file problems
  - Use small files first (e.g. `jfk.wav`)
  - Supported: wav, mp3, m4a (macOS codecs)
- Streaming issues
  - For SSE, set header `Accept: text/event-stream` and `-F stream=true`
  - If SSE is blocked, remove the header; the server falls back to chunked

## Notes
- Default port: `12017`
- Temporary files are cleaned after each request
- The server serializes transcription requests to keep things stable