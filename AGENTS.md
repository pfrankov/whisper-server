# Repository Guidelines

## Project Structure & Module Organization
- `WhisperServer/`: Swift sources (e.g., `WhisperServerApp.swift`, `VaporServer.swift`, `WhisperTranscriptionService.swift`, `ModelManager.swift`, `Assets.xcassets/`).
- `WhisperServer.xcodeproj/`: Xcode project and build settings.
- `test_api.sh`: Curl-based API smoke/streaming tests.
- `jfk.wav`: Sample audio used by tests.
- `Resources/`, `BuildPhases/`: Supporting assets and scripts.

## Build, Test, and Development Commands
- Build (CLI): `xcodebuild build -project WhisperServer.xcodeproj -scheme WhisperServer`.
- Run (GUI): Open in Xcode and press Run (⌘R). The app starts a server on `http://localhost:12017`.
- API test suite: `./test_api.sh` (app must be running). Example: `curl -X POST http://localhost:12017/v1/audio/transcriptions -F file=@jfk.wav -F response_format=json`.
- App icon generation: `./GenerateAppIcon.sh` (uses `icon.png`).

## Coding Style & Naming Conventions
- Swift 5, 4-space indentation, keep lines readable (~120 cols).
- Types: PascalCase; methods/properties: lowerCamelCase; one primary type per file named after the type.
- Prefer `guard` for early exits; avoid force-unwraps; keep async work off the main thread.
- Do not commit model binaries: `.gitignore` excludes `*.bin`, `*.mlmodelc`.
 - Comments and strings in code must be written in English only.
 - Favor enums and strong types over string literals for modes and formats (e.g., response formats).
 - Centralize shared constants (e.g., notification names) in a single place.
 - Limit logging to actionable or error information; avoid verbose debug prints in production paths.

## Testing Guidelines
- Primary: run the app, then `./test_api.sh` to validate JSON/text/SRT/VTT and streaming (SSE/chunked).
- Manual checks: use `curl` with `-F file=@jfk.wav` and `response_format` (`json|text|srt|vtt|verbose_json`).
- If adding Xcode tests, follow `test[Component][Behavior]()` naming and keep tests independent of network state.

## Commit & Pull Request Guidelines
- Commit style (per history): concise, imperative present tense, mention affected components (e.g., “Refactor WhisperTranscriptionService…”), include the “why” when useful.
- PRs: clear description, scope of change, testing steps (`xcodebuild build`, `./test_api.sh` results), linked issues, and screenshots if UI/menu-bar behavior changes.

## Security & Configuration Tips
- Default port is `12017`; avoid exposing beyond localhost in development.
- Large Whisper models live outside the repo; configure via the app UI; never commit model files.

## Platform Assumptions
- Target platform is modern macOS only. Cross‑platform fallbacks and conditional compilation are not required.

## Server & API Conventions
- Vapor route handlers should use async/await.
- Prefer streaming SSE for incremental results; always terminate SSE with an explicit `end` event.
- Ensure temporary files are cleaned up after each request (success or failure).

## Crash Safety Practices
- When bridging Swift strings to C APIs, allocate stable C strings (e.g., via `strdup`) and free them after use.
- Always validate and unwrap external resources (contexts, files, model paths) before use; return early on failure.
- Avoid blocking calls on UI threads; dispatch UI changes to the main thread.
