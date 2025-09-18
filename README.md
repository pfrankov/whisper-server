# WhisperServer MacOS

<img src="https://github.com/user-attachments/assets/bf882d55-f1f6-4765-9124-e2cb351eabe0" alt="Demo" width="500"/>

_No speedup. MacBook Pro 13, M2, 16GB._

WhisperServer is a macOS application that runs in the background with only a menu bar icon. It provides an HTTP server compatible with the OpenAI Whisper API for audio transcription.

<img width="296" alt="image" src="https://github.com/user-attachments/assets/06a74992-fea3-438b-84e9-85aebdfd7247" />


## Key Features

- Works as a menu bar application (no dock icon)
- Displays a menu bar icon with status information
- Provides an API compatible with the OpenAI Whisper API
- Supports the `/v1/audio/transcriptions` endpoint for audio transcription
- HTTP server on port 12017
- **Streaming support with Server-Sent Events (SSE) and chunked response fallback**
- Also returns "OK" in response to any other HTTP request

## How to Use

1. Build and run the application in Xcode
2. Look for the server icon in the menu bar
3. The HTTP server will automatically start on port 12017
4. Use the API endpoint for transcription: `http://localhost:12017/v1/audio/transcriptions`
5. To exit the application, click on the menu bar icon and select "Quit"

## Example of Using the Whisper API

For audio transcription:

```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@/path/to/audio.mp3 \
  -F response_format=json
```

Supported parameters:
- `file` - audio file (required)
- `prompt` - text to guide the transcription style
- `response_format` - response format (json, text, srt, vtt, verbose_json)
- `temperature` - sampling temperature from 0 to 1
- `language` - input language (ISO-639-1)
- `stream` - enable streaming response (true/false)

## Response Formats

The server supports the following response formats:

1. **json** (default):
```json
{
  "text": "Transcription text."
}
```

2. **verbose_json**:
```json
{
  "task": "transcribe",
  "language": "en",
  "duration": 10.5,
  "text": "Full transcription text.",
  "segments": [
    {
      "id": 0,
      "seek": 0,
      "start": 0.0,
      "end": 5.0,
      "text": "First segment.",
      "tokens": [50364, 13, 11, 263, 6116],
      "temperature": 0.0,
      "avg_logprob": -0.45,
      "compression_ratio": 1.275,
      "no_speech_prob": 0.1
    },
    // Other segments...
  ]
}
```

3. **text**: Simple text output

4. **srt**: SubRip subtitle format

5. **vtt**: WebVTT subtitle format

## Streaming Support

WhisperServer supports real-time streaming transcription with automatic protocol detection:

### Server-Sent Events (SSE) - Priority
When the client sends `Accept: text/event-stream` header, the server uses SSE format:

```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -H "Accept: text/event-stream" \
  -F file=@audio.wav \
  -F response_format="text" \
  -F stream="true" \
  --no-buffer
```

Response format:
```
data: First transcribed segment
data: 

data: Second transcribed segment
data: 

event: end
data: 

```

### Chunked Response - Fallback
When SSE is not supported, the server automatically falls back to HTTP chunked transfer encoding:

```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@audio.wav \
  -F response_format="text" \
  -F stream="true" \
  --no-buffer
```

### Testing Streaming
Use the comprehensive test script:
- `test_api.sh` - Complete API and streaming test suite

## Technical Details

- The application uses the modern Network framework to create an HTTP server
- The default port value is 12017
- No window is displayed — the application works completely in the background
- Optimized code architecture for easy maintenance

## Code Architecture

The project is divided into the following main components:

- **WhisperServerApp.swift**: SwiftUI application entry point and AppDelegate
- **SimpleHTTPServer.swift**: HTTP server implementation with Whisper API support
- **ContentView.swift**: SwiftUI placeholder, not displayed to the user
- **Info.plist**: Application configuration and network permissions

## Requirements

- macOS 11.0 or newer
- Xcode 13.0 or newer (for building)

## Troubleshooting

If you have problems connecting to the server:

1. Make sure the application is running (icon in the menu bar)
2. Check if the firewall is blocking port 12017
3. Check if there are other applications using port 12017
4. If the server is not responding, restart the application

For detailed logs, run the application from Xcode and watch the console. 

## Versioning and release

This repository contains a small helper script to bump the app version using Xcode's MARKETING_VERSION and keep Info.plist in sync.

Script: `scripts/bump_version.sh`

Usage:

1) Bump the patch version (increments patch by 1):

```bash
./scripts/bump_version.sh patch
```

2) Bump the minor version (increments minor by 1, resets patch to 0):

```bash
./scripts/bump_version.sh minor
```

3) Bump the major version (increments major by 1, resets minor and patch to 0):

```bash
./scripts/bump_version.sh major
```

Optional flags:
- `--build <number>` — set an explicit `CFBundleVersion` (build number).
- `--tag` — create an annotated git tag named `v<new-version>`.
- `--push` — push commit (and tag, if `--tag` used) to `origin`.

Notes:
- The script updates MARKETING_VERSION in `WhisperServer.xcodeproj/project.pbxproj` and ensures `WhisperServer/Info.plist` uses `$(MARKETING_VERSION)` for `CFBundleShortVersionString`. It also updates `CFBundleVersion` (build number).
- After running the script, review changes and commit them (for example `git add WhisperServer.xcodeproj/project.pbxproj WhisperServer/Info.plist && git commit -m "Bump version to X.Y.Z"`).
- `--tag` will create an annotated tag named `v<version>` on the current HEAD — make sure you've committed first.
- `--push` will push the tag (if used with `--tag`) or push the current branch if used alone.
