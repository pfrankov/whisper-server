# WhisperServer Testing Guide

Comprehensive testing setup for WhisperServer's OpenAI Whisper API compatibility.

## Overview

This testing suite ensures that WhisperServer maintains full compatibility with the OpenAI Whisper API specification. The tests cover:

- **HTTP API Compatibility** - Ensures responses match OpenAI Whisper API format
- **Audio Processing** - Tests various audio format conversions
- **Error Handling** - Validates proper error responses
- **Performance** - Measures transcription response times
- **Model Management** - Tests model loading and configuration

## Test Types

### 1. Swift Testing Framework Tests

Located in `WhisperServerTests/` directory:

- `WhisperServerTests.swift` - Main HTTP API compatibility tests
- `AudioConverterTests.swift` - Audio conversion unit tests  
- `ModelManagerTests.swift` - Model management unit tests

### 2. Shell Script Tests

- `test_api.sh` - Command-line curl-based API testing

## Running Tests

### Swift Tests (Recommended)

```bash
# Run all tests
xcodebuild test -project WhisperServer.xcodeproj -scheme WhisperServer

# Run specific test target
xcodebuild test -project WhisperServer.xcodeproj -scheme WhisperServer -only-testing:WhisperServerTests

# Run with verbose output
xcodebuild test -project WhisperServer.xcodeproj -scheme WhisperServer -verbose
```

### Manual API Testing

1. **Start the WhisperServer app**
   - Launch the app from macOS menu bar
   - Select a model (tiny, medium, or large-v3-turbo)
   - Wait for the server to start on `http://localhost:12017`

2. **Run the shell test suite**
   ```bash
   ./test_api.sh
   ```

3. **Manual curl testing**
   ```bash
   # Test JSON response format
   curl -X POST http://localhost:12017/v1/audio/transcriptions \
     -F file=@jfk.wav \
     -F response_format="json"

   # Test text response format  
   curl -X POST http://localhost:12017/v1/audio/transcriptions \
     -F file=@jfk.wav \
     -F response_format="text"

   # Test with language parameter
   curl -X POST http://localhost:12017/v1/audio/transcriptions \
     -F file=@jfk.wav \
     -F language="en" \
     -F response_format="json"
   ```

## Test Requirements

### Prerequisites

- **Audio File**: Tests require `jfk.wav` file in the project root
  ```bash
  # Download test audio if missing
  curl -O https://github.com/openai/whisper/raw/main/tests/jfk.wav
  ```

- **Model**: At least one Whisper model must be downloaded and configured
- **macOS**: Tests use AVFoundation for audio processing
- **Xcode 15+**: Required for Swift Testing framework

### Test Data

The test suite creates synthetic audio data for unit tests, but integration tests use real audio files:

- **Test Audio**: 1-second 16kHz mono WAV with 440Hz sine wave
- **Large Test Audio**: 10-second audio for performance testing
- **Invalid Audio**: Non-audio data for error handling tests

## OpenAI Whisper API Compatibility

### Supported Endpoints

✅ `POST /v1/audio/transcriptions`

### Supported Parameters

- ✅ `file` (required) - Audio file in various formats
- ✅ `language` (optional) - Language code (e.g., "en")  
- ✅ `prompt` (optional) - Text prompt for better accuracy
- ✅ `response_format` (optional) - "json" or "text"
- ⚠️ `stream` (partial) - Streaming responses (implemented but not fully tested)

### Response Formats

**JSON Format (`response_format=json`)**:
```json
{
  "text": "And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country."
}
```

**Text Format (`response_format=text`)**:
```
And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.
```

### Supported Audio Formats

- ✅ WAV (16-bit PCM)
- ✅ M4A/AAC (via AVFoundation) 
- ✅ MP3 (via AVFoundation)
- ⚠️ Other formats depend on macOS codec support

## Test Configuration

### Test Server Configuration

- **Port**: 12018 (different from production port 12017)
- **Timeout**: 30 seconds for transcription
- **Max File Size**: 1GB (Vapor default)

### Performance Expectations

- **Small Audio (1-3 seconds)**: < 10 seconds response time
- **Medium Audio (30 seconds)**: < 30 seconds response time  
- **Large Audio (5+ minutes)**: Varies by model size

## Troubleshooting

### Common Issues

**"Server not running" error**:
- Ensure WhisperServer app is running
- Check that a model is selected and loaded
- Verify server is listening on correct port

**"No model configured" error**:
- Select a model from the app menu
- Wait for model download to complete
- Check application support directory for model files

**Test compilation errors**:
- Ensure Xcode 15+ with Swift Testing support
- Clean build folder: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Rebuild project: `xcodebuild clean build`

**Audio format errors**:
- Use 16-bit WAV mono for best compatibility
- Check that test audio files exist
- Verify file permissions

### Debug Mode

Enable verbose logging for debugging:

```bash
# Run tests with debug output
xcodebuild test -project WhisperServer.xcodeproj -scheme WhisperServer -destination 'platform=macOS' | grep -E "(PASS|FAIL|Error)"
```

## Continuous Integration

For automated testing environments:

```bash
#!/bin/bash
# CI test script

# Build project
xcodebuild build -project WhisperServer.xcodeproj -scheme WhisperServer -quiet

# Run unit tests (no server required)
xcodebuild test -project WhisperServer.xcodeproj -scheme WhisperServer -only-testing:AudioConverterTests -only-testing:ModelManagerTests

# Note: HTTP API tests require running server and are not suitable for CI
```

## Contributing

When adding new tests:

1. **Follow naming convention**: `test[Component][Functionality]()`
2. **Use descriptive test names**: `@Test("Component - Specific behavior")`
3. **Include error cases**: Test both success and failure paths
4. **Clean up resources**: Use `defer` for temporary files
5. **Document expectations**: Comment on expected behavior

### Test Categories

- **Unit Tests**: Test individual components in isolation
- **Integration Tests**: Test component interactions
- **API Tests**: Test HTTP endpoint compatibility  
- **Performance Tests**: Measure and validate response times
- **Error Tests**: Validate error handling and edge cases

---

*Generated by Valera, the ex-designer turned IT specialist who knows that proper testing saves more time than it takes to write.* 