import Foundation
import Vapor
import FluidAudio

/// HTTP server for processing Whisper API requests using Vapor
final class VaporServer {
    // MARK: - Properties
    
    /// The Vapor application
    private var app: Application?
    
    /// The port the server listens on
    private let port: Int
    
    /// Model manager instance
    private let modelManager: ModelManager
    
    /// Flag indicating whether the server is running
    private(set) var isRunning = false
    
    // MARK: - Initialization
    
    /// Creates a new instance of the Vapor server
    /// - Parameter port: Port to listen for connections
    /// - Parameter modelManager: The manager for Whisper models
    init(port: Int, modelManager: ModelManager) {
        self.port = port
        self.modelManager = modelManager
    }
    
    // MARK: - Public Methods
    
    /// Starts the HTTP server
    func start() {
        guard !isRunning else { return }
        do {
            let env = try Environment.detect()
            let app = Application(env)
            self.app = app

            // Configure the server
            app.http.server.configuration.hostname = "localhost"
            app.http.server.configuration.port = port

            // Register routes
            try routes(app)

            // Start without blocking the current thread
            try app.start()
            DispatchQueue.main.async {
                self.isRunning = true
                print("✅ Vapor server started on http://localhost:\(self.port)")
            }
        } catch {
            print("❌ Failed to start Vapor server: \(error)")
            DispatchQueue.main.async { self.isRunning = false }
        }
    }
    
    /// Stops the HTTP server
    func stop() {
        guard let app = app else { return }
        app.shutdown()
        self.isRunning = false
        print("🛑 Vapor server stopped")
    }
    
    // MARK: - Private Methods

    /// Supported providers
    private enum Provider: String { case whisper, fluid }

    /// Parses response format string to enum with safe default
    private func parseResponseFormat(_ raw: String?) -> WhisperSubtitleFormatter.ResponseFormat {
        WhisperSubtitleFormatter.ResponseFormat(rawValue: raw ?? "") ?? .json
    }

    /// Maps response format to content-type when not using SSE
    private func contentType(for format: WhisperSubtitleFormatter.ResponseFormat) -> String {
        switch format {
        case .json: return "application/json"
        case .text: return "text/plain; charset=utf-8"
        case .srt: return "application/x-subrip"
        case .vtt: return "text/vtt"
        case .verboseJson: return "application/json"
        }
    }

    /// Wrap data for SSE if needed
    private func wrapForSSE(_ data: String, enabled: Bool) -> String {
        return enabled ? formatSSEData(data) : data
    }

    /// Checks if the client supports Server-Sent Events
    /// - Parameter request: The incoming HTTP request
    /// - Returns: True if SSE is supported, false otherwise
    private func supportsSSE(_ request: Request) -> Bool {
        guard let acceptHeader = request.headers.first(name: .accept) else { return false }
        return acceptHeader.contains("text/event-stream")
    }
    
    /// Formats data for SSE transmission
    /// - Parameter data: The data to format
    /// - Returns: SSE-formatted string
    private func formatSSEData(_ data: String) -> String {
        let lines = data.components(separatedBy: .newlines)
        let formattedLines = lines.map { "data: \($0)" }.joined(separator: "\n")
        return "\(formattedLines)\n\n"
    }

    /// Builds response headers depending on streaming mode/content type
    private func buildHeaders(useSSE: Bool, format: WhisperSubtitleFormatter.ResponseFormat) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if useSSE {
            headers.add(name: "Content-Type", value: "text/event-stream")
            headers.add(name: "Cache-Control", value: "no-cache")
            headers.add(name: "Connection", value: "keep-alive")
            headers.add(name: "Access-Control-Allow-Origin", value: "*")
        } else {
            headers.add(name: "Content-Type", value: self.contentType(for: format))
        }
        return headers
    }

    /// Resolve provider from request or UI selection
    private func resolveProvider(_ raw: String?) -> Provider {
        if let raw, let val = Provider(rawValue: raw.lowercased()) { return val }
        return (self.modelManager.selectedProvider == .fluid) ? .fluid : .whisper
    }

    // MARK: - Routes
    
    private func routes(_ app: Application) throws {
        // Set a high limit for streaming body collection to handle large audio files.
        // Vapor streams requests larger than 16KB to a temporary file on disk by default.
        app.routes.defaultMaxBodySize = "1gb"

        app.post("v1", "audio", "transcriptions") { [self] req async throws -> Response in
            
            struct WhisperRequest: Content {
                var file: File
                var language: String?
                var prompt: String?
                var response_format: String?
                var stream: Bool?
                var provider: String? // "whisper" (default) or "fluid"
                var model: String?    // optional model hint; for Fluid treated as locale if provided
            }
            
            let whisperReq = try req.content.decode(WhisperRequest.self)
            
            // Generate a temporary file path
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = whisperReq.file.filename
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + "-" + fileName)

            // Write the file buffer to the temporary path
            try await req.fileio.writeFile(whisperReq.file.data, at: tempFileURL.path)
            
            let responseFormat = self.parseResponseFormat(whisperReq.response_format)
            let provider: Provider = self.resolveProvider(whisperReq.provider)

            // Resolve whisper model paths only when needed
            let modelPaths: (binPath: URL, encoderDir: URL)? = {
                if provider == .whisper {
                    return self.modelManager.getPathsForSelectedModel()
                } else {
                    return nil
                }
            }()
            if provider == .whisper && modelPaths == nil {
                throw Abort(.internalServerError, reason: "Model not configured")
            }
            
            if whisperReq.stream == true {
                // Check if client supports SSE
                let useSSE = self.supportsSSE(req)
                // Choose the appropriate streaming method based on format
                switch responseFormat {
                case .srt, .vtt, .verboseJson:
                    guard provider == .whisper else {
                        // FluidAudio currently supports streaming only for text/json
                        let errorBody = "{\"error\": \"FluidAudio provider supports only text/json for streaming\"}"
                        var headers = HTTPHeaders()
                        headers.add(name: "Content-Type", value: self.contentType(for: .json))
                        try? FileManager.default.removeItem(at: tempFileURL)
                        return Response(status: .badRequest, headers: headers, body: .init(string: errorBody))
                    }
                    // Timestamp streaming mode
                    var segmentCounter = 0
                    let body = Response.Body(stream: { streamWriter in
                        let success = WhisperTranscriptionService.transcribeAudioStreamWithTimestamps(
                            at: tempFileURL,
                            language: whisperReq.language,
                            prompt: whisperReq.prompt,
                            modelPaths: modelPaths,
                            onSegment: { segment in
                                req.eventLoop.execute {
                                    segmentCounter += 1
                                    let output: String
                                    switch responseFormat {
                                    case .srt:
                                        let startTime = WhisperTranscriptionService.formatSRTTimestamp(segment.startTime)
                                        let endTime = WhisperTranscriptionService.formatSRTTimestamp(segment.endTime)
                                        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        output = "\(segmentCounter)\n\(startTime) --> \(endTime)\n\(text)\n\n"
                                    case .vtt:
                                        if segmentCounter == 1 {
                                            // Add VTT header only for first segment
                                            let startTime = WhisperTranscriptionService.formatVTTTimestamp(segment.startTime)
                                            let endTime = WhisperTranscriptionService.formatVTTTimestamp(segment.endTime)
                                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                            output = "WEBVTT\n\n\(startTime) --> \(endTime)\n\(text)\n\n"
                                        } else {
                                            let startTime = WhisperTranscriptionService.formatVTTTimestamp(segment.startTime)
                                            let endTime = WhisperTranscriptionService.formatVTTTimestamp(segment.endTime)
                                            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                            output = "\(startTime) --> \(endTime)\n\(text)\n\n"
                                        }
                                    case .verboseJson:
                                        let segmentDict: [String: Any] = [
                                            "start": segment.startTime,
                                            "end": segment.endTime,
                                            "text": segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        ]
                                        if let jsonData = try? JSONSerialization.data(withJSONObject: segmentDict),
                                           let jsonString = String(data: jsonData, encoding: .utf8) {
                                            output = jsonString + "\n"
                                        } else {
                                            output = ""
                                        }
                                    default:
                                        output = segment.text
                                    }
                                    
                                    // Format output based on streaming method
                                    let finalOutput = self.wrapForSSE(output, enabled: useSSE)
                                    var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                    buffer.writeString(finalOutput)
                                    streamWriter.write(.buffer(buffer), promise: nil)
                                    
                                    // Chunk written
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    // Streaming completed
                                    if useSSE {
                                        // Send SSE end event
                                        let endEvent = "event: end\ndata: \n\n"
                                        var buffer = req.byteBufferAllocator.buffer(capacity: endEvent.utf8.count)
                                        buffer.writeString(endEvent)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                        // SSE end event written
                                    }
                                    streamWriter.write(.end, promise: nil)
                                    // Stream ended, clean up temp file
                                    try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                                }
                            }
                        )
                        if !success {
                            req.eventLoop.execute {
                                streamWriter.write(.end, promise: nil)
                                try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                            }
                        }
                    })
                    let headers = self.buildHeaders(useSSE: useSSE, format: responseFormat)
                    return Response(status: .ok, headers: headers, body: body)
                case .json, .text:
                    // Streaming contract: send chunks as they are ready.
                    // For FluidAudio we will send a single chunk when final result is ready, then close.
                    let body = Response.Body(stream: { streamWriter in
                        switch provider {
                        case .whisper:
                            let success = WhisperTranscriptionService.transcribeAudioStream(
                                at: tempFileURL,
                                language: whisperReq.language,
                                prompt: whisperReq.prompt,
                            modelPaths: modelPaths,
                                onSegment: { segment in
                                    req.eventLoop.execute {
                                        let output: String
                                        switch responseFormat {
                                        case .json:
                                            let jsonSegment = ["text": segment]
                                            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonSegment),
                                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                                output = jsonString + "\n"
                                            } else {
                                                output = ""
                                            }
                                        default: // text
                                            output = segment
                                        }

                                        // Format output based on streaming method
                                        let finalOutput = self.wrapForSSE(output, enabled: useSSE)
                                        var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                        buffer.writeString(finalOutput)
                                        streamWriter.write(.buffer(buffer), promise: nil)

                                        // Regular chunk written
                                    }
                                },
                                onCompletion: {
                                    req.eventLoop.execute {
                                        // Regular streaming completed
                                        if useSSE {
                                            // Send SSE end event
                                            let endEvent = "event: end\ndata: \n\n"
                                            var buffer = req.byteBufferAllocator.buffer(capacity: endEvent.utf8.count)
                                            buffer.writeString(endEvent)
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                            // SSE end event written
                                        }
                                        streamWriter.write(.end, promise: nil)
                                        // Stream ended, clean up temp file
                                        try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                                    }
                                }
                            )
                            if !success {
                                req.eventLoop.execute {
                                    streamWriter.write(.end, promise: nil)
                                    try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                                }
                            }
                        case .fluid:
                            // Do the work asynchronously, then emit a single chunk
                            Task {
                                defer {
                                    req.eventLoop.execute {
                                        if useSSE {
                                            let endEvent = "event: end\ndata: \n\n"
                                            var buffer = req.byteBufferAllocator.buffer(capacity: endEvent.utf8.count)
                                            buffer.writeString(endEvent)
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        }
                                        streamWriter.write(.end, promise: nil)
                                        try? FileManager.default.removeItem(at: tempFileURL)
                                    }
                                }

                                if let transcription = await FluidTranscriptionService.transcribeText(at: tempFileURL, language: whisperReq.model ?? whisperReq.language) {
                                    let trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let output: String
                                    switch responseFormat {
                                    case .json:
                                        if trimmed.isEmpty {
                                            let jsonResponse: [String: Any] = ["error": "Empty transcription", "text": ""]
                                            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                                output = jsonString + "\n"
                                            } else {
                                                output = "{\"error\":\"Empty transcription\",\"text\":\"\"}\n"
                                            }
                                        } else {
                                            let jsonResponse = ["text": trimmed]
                                            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                                output = jsonString + "\n"
                                            } else {
                                                output = "\n"
                                            }
                                        }
                                    default:
                                        output = trimmed.isEmpty ? "No speech detected\n" : (trimmed + "\n")
                                    }

                                    let finalOutput = self.wrapForSSE(output, enabled: useSSE)
                                    req.eventLoop.execute {
                                        var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                        buffer.writeString(finalOutput)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                    }
                                } else {
                                    let errorJSON = "{\"error\": \"Transcription failed\"}\n"
                                    let finalOutput = self.wrapForSSE(errorJSON, enabled: useSSE)
                                    req.eventLoop.execute {
                                        var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                        buffer.writeString(finalOutput)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                    }
                                }
                            }
                        }
                    })
                    let headers = self.buildHeaders(useSSE: useSSE, format: responseFormat)
                    return Response(status: .ok, headers: headers, body: body)
                }
            } else {
                // Non-streaming case - determine which transcription method to use
                let responseBody: String
                let contentType: String
                
                // Handle subtitle formats that need timestamps
                switch responseFormat {
                case .srt, .vtt, .verboseJson:
                    guard provider == .whisper else {
                        responseBody = "{\"error\": \"FluidAudio provider supports only json/text formats\"}"
                        contentType = self.contentType(for: .json)
                        break
                    }
                    if let segments = WhisperTranscriptionService.transcribeAudioWithTimestamps(
                        at: tempFileURL, language: whisperReq.language, prompt: whisperReq.prompt, modelPaths: modelPaths
                    ) {
                        switch responseFormat {
                        case .srt:
                            responseBody = WhisperTranscriptionService.formatAsSRT(segments: segments)
                            contentType = self.contentType(for: .srt)
                        case .vtt:
                            responseBody = WhisperTranscriptionService.formatAsVTT(segments: segments)
                            contentType = self.contentType(for: .vtt)
                        case .verboseJson:
                            responseBody = WhisperTranscriptionService.formatAsVerboseJSON(segments: segments)
                            contentType = self.contentType(for: .verboseJson)
                        default:
                            responseBody = "{\"error\": \"Unsupported response format\"}"
                            contentType = self.contentType(for: .json)
                        }
                    } else {
                        responseBody = "{\"error\": \"Failed to transcribe audio with timestamps\"}"
                        contentType = self.contentType(for: .json)
                    }
                case .json, .text:
                    // Handle regular formats (json, text)
                    switch provider {
                    case .whisper:
                        if let transcription = WhisperTranscriptionService.transcribeAudio(
                            at: tempFileURL, language: whisperReq.language, prompt: whisperReq.prompt, modelPaths: modelPaths
                        ) {
                            switch responseFormat {
                            case .json:
                                let jsonResponse = ["text": transcription]
                                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                                   let jsonString = String(data: jsonData, encoding: .utf8) {
                                    responseBody = jsonString
                                    contentType = self.contentType(for: .json)
                                } else {
                                    responseBody = "{\"error\": \"Failed to create JSON response.\"}"
                                    contentType = self.contentType(for: .json)
                                }
                            case .text:
                                responseBody = transcription
                                contentType = self.contentType(for: .text)
                            default:
                                responseBody = "Unsupported response format"
                                contentType = self.contentType(for: .text)
                            }
                        } else {
                            responseBody = "{\"error\": \"Transcription failed\"}"
                            contentType = self.contentType(for: .json)
                        }
                    case .fluid:
                        if let transcription = await FluidTranscriptionService.transcribeText(at: tempFileURL, language: whisperReq.model ?? whisperReq.language) {
                            switch responseFormat {
                            case .json:
                                let jsonResponse = ["text": transcription]
                                if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                                   let jsonString = String(data: jsonData, encoding: .utf8) {
                                    responseBody = jsonString
                                    contentType = self.contentType(for: .json)
                                } else {
                                    responseBody = "{\"error\": \"Failed to create JSON response.\"}"
                                    contentType = self.contentType(for: .json)
                                }
                            case .text:
                                responseBody = transcription
                                contentType = self.contentType(for: .text)
                            default:
                                responseBody = "Unsupported response format"
                                contentType = self.contentType(for: .text)
                            }
                        } else {
                            responseBody = "{\"error\": \"Transcription failed\"}"
                            contentType = self.contentType(for: .json)
                        }
                    }
                }
                
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: contentType)
                
                let response = Response(status: .ok, headers: headers, body: .init(string: responseBody))
                try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                return response
            }
        }
    }
}
