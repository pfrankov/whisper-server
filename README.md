# WhisperServer

<img src="https://github.com/user-attachments/assets/bf882d55-f1f6-4765-9124-e2cb351eabe0" alt="Demo" width="500"/>

WhisperServer is a macOS application that runs in the background with only a menu bar icon. It provides an HTTP server compatible with the OpenAI Whisper API for audio transcription.

## Key Features

- Works as a menu bar application (no dock icon)
- Displays a menu bar icon with status information
- Provides an API compatible with the OpenAI Whisper API
- Supports the `/v1/audio/transcriptions` endpoint for audio transcription
- HTTP server on port 12017
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
