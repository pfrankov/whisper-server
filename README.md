# WhisperServer for macOS

<img src="https://github.com/user-attachments/assets/bf882d55-f1f6-4765-9124-e2cb351eabe0" alt="Demo" width="500"/>

_No speedup. MacBook Pro 13, M2, 16 GB._

WhisperServer is a lightweight macOS menu bar app that runs in the background.  
It exposes a local HTTP server compatible with the OpenAI Whisper API for audio transcription.

<img width="506" alt="menu bar demo" src="https://github.com/user-attachments/assets/7470e00a-3bc6-4cd3-ab95-d45606393954" />

## Key features
- Local HTTP server compatible with the OpenAI Whisper API
- Menu bar application (no Dock icon)
- Streaming via Server‑Sent Events (SSE) with automatic chunked fallback
- Automatic VAD-based chunking for Whisper models to prevent repeated text in long audio files — a common issue with standard whisper.cpp
- Automatically downloads models on first use
- Fast, high‑quality quantized models
- Parakeet model can transcribe ~1 hour of audio in about 1 minute

## Requirements
- macOS 14.6 or newer
- Apple Silicon (ARM64) only

## Recommended by
| Project | Platform | Key features |
|---------|----------|------------------------|
| [VibeScribe](https://github.com/pfrankov/vibe-scribe) | macOS | Automatic call summarization and transcription for meetings, interviews, and brainstorming. Key features: AI-powered summaries, easy export of notes, transcription. |

## Installation

### Download from GitHub Releases
1. Go to the [Releases page](https://github.com/pfrankov/whisper-server/releases).
2. Download the latest `.dmg` file.
3. Open the `.dmg` file.
4. Drag WhisperServer to your Applications folder.

### 🚨 First launch
This app is not signed by Apple. To open it the first time:
1. Control‑click (or right‑click) WhisperServer in Applications.
2. Choose Open.
3. In the warning dialog, click Open.
4. Or go to System Settings → Privacy & Security and allow the app.

## Usage
###  Apple Shortcut
[From Audio to SRT](https://www.icloud.com/shortcuts/064f7f2047524421b4b8b8e7f1612608)
<details>
  <summary>Example</summary>
  <p><video src="https://github.com/user-attachments/assets/1e75e284-f178-460c-a42b-182acea03480"/></p>
</details>

### HTTP
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@/path/to/audio.mp3
```

### Supported parameters
| Parameter        | Description                        | Values                              | Required |
|------------------|------------------------------------|-------------------------------------|----------|
| file             | Audio file                         | wav, mp3, m4a                       | yes      |
| model            | Model to use                       | model ID                            | no       |
| prompt           | Guide style/tone (Whisper)         | string                              | no       |
| response_format  | Output format                      | json, text, srt, vtt, verbose_json  | no       |
| language         | Input language (ISO 639‑1)         | 2‑letter code                       | no       |
| diarize          | Enable Fluid speaker diarization   | true, false (default false)         | no       |
| stream           | Enable streaming (SSE or chunked)  | true, false                         | no       |

### Models
| Model | Relative speed | Quality |
|--------------------------|----------------|---------------------------------------|
| `parakeet-tdt-0.6b-v3`   | Fastest        | Medium                                |
| `tiny-q5_1`              | Fast           | Good (English), Low (other languages) |
| `large-v3-turbo-q5_0`    | Slow           | Medium–Good                           |
| `medium-q5_0`            | Slowest        | Good                                  |

## Response formats

The server supports multiple response formats:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@/path/to/audio.mp3 \
  -F response_format=json
```

1. json (default)
```json
{
  "text": "Transcription text."
}
```

2. verbose_json
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
    }
  ]
}
```

3. text
```
And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.
```

4. srt
```
1
00:00:00,240 --> 00:00:07,839
And so, my fellow Americans, ask not what your country can do for you

2
00:00:07,839 --> 00:00:10,640
ask what you can do for your country.
```

5. vtt
```
WEBVTT

00:00:00.240 --> 00:00:07.839
And so, my fellow Americans, ask not what your country can do for you

00:00:07.839 --> 00:00:10.640
ask what you can do for your country.
```

## Streaming support

WhisperServer supports real‑time streaming with automatic protocol detection. Note: timestamped streaming (srt, vtt, verbose_json) requires the Whisper provider; the Fluid provider streams text/JSON only.

### Server‑Sent Events (SSE)
If the client sends the header `Accept: text/event-stream`, the server uses SSE:

```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -H "Accept: text/event-stream" \
  -F file=@audio.wav \
  -F stream=true \
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

### Chunked response
If SSE isn’t supported, the server falls back to HTTP chunked transfer encoding:

```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@audio.wav \
  -F stream=true \
  --no-buffer
```

## FluidAudio diarization

Add speaker labels (who is talking) when you use the FluidAudio provider. Diarization is off by default to stay compatible with the OpenAI Whisper API.

How to enable:
- Select the Fluid provider in the menu bar (or pass the Fluid model ID), and
- Add `diarize=true` to your request.

Example:
```bash
curl -X POST http://localhost:12017/v1/audio/transcriptions \
  -F file=@meeting.wav \
  -F model=parakeet-tdt-0.6b-v3 \
  -F response_format=json \
  -F diarize=true
```

What you get:
- For `response_format=json`, the server adds a `speaker_segments` array:
  ```json
  {
    "text": "Good morning everyone...",
    "speaker_segments": [
      {
        "speaker": "Speaker_1",
        "start": 0.0,
        "end": 4.2,
        "text": "Good morning everyone"
      },
      {
        "speaker": "Speaker_2",
        "start": 4.2,
        "end": 7.8,
        "text": "Morning! Shall we begin?"
      }
    ]
  }
  ```
- For `response_format=verbose_json`, `speaker_segments` is added as well. The existing `segments` field stays unchanged.

Streaming:
- Streaming sends one JSON chunk with `speaker_segments` when diarization completes.
- Then the standard `end` event is sent.

## Build from Source
If you want to build WhisperServer yourself:

1. Clone the repository:
```bash
git clone https://github.com/pfrankov/whisper-server.git
cd whisper-server
```

2. Open the project in Xcode.

3. Select your development team:
   - Click the project in Xcode
   - Select the WhisperServer target
  - Go to "Signing & Capabilities"
  - Choose your team

4. Build and run:
   - Press `Cmd + R` to build and run
   - Or use the menu: Product → Run

### Testing
- Run the app, then run the script: `test_api.sh` (complete API test suite)

### Importing Custom Models
- In the menu bar, open `Select Model` → `Import Whisper Model…`
- Choose a `.bin` model file (optionally add its `.mlmodelc` bundle in the same dialog)
- The model becomes selectable in the menu and is listed in `GET /v1/models`

## License
MIT
