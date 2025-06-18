import Vapor
import AppKit

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
            
            // Start the server in a background thread
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try app.run()
                    DispatchQueue.main.async {
                        self.isRunning = true
                        print("✅ Vapor server started on http://localhost:\(self.port)")
                    }
                } catch {
                    print("❌ Failed to start Vapor server: \(error)")
                    DispatchQueue.main.async {
                        self.isRunning = false
                    }
                }
            }
        } catch {
            print("❌ Failed to initialize Vapor application: \(error)")
        }
    }
    
    /// Stops the HTTP server
    func stop() {
        guard let app = app, isRunning else { return }
        
        app.shutdown()
        self.isRunning = false
        print("🛑 Vapor server stopped")
    }
    
    // MARK: - Private Methods
    
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
    
    // MARK: - Routes
    
    private func routes(_ app: Application) throws {
        // Set a high limit for streaming body collection to handle large audio files.
        // Vapor streams requests larger than 16KB to a temporary file on disk by default.
        app.routes.defaultMaxBodySize = "1gb"

        app.post("v1", "audio", "transcriptions") { req -> Response in
            
            struct WhisperRequest: Content {
                var file: File
                var language: String?
                var prompt: String?
                var response_format: String?
                var stream: Bool?
            }
            
            let whisperReq = try req.content.decode(WhisperRequest.self)
            
            // Generate a temporary file path
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = whisperReq.file.filename
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + "-" + fileName)

            // Write the file buffer to the temporary path
            try await req.fileio.writeFile(whisperReq.file.data, at: tempFileURL.path)
            
            let responseFormat = whisperReq.response_format ?? "json"
            
            guard let modelPaths = self.modelManager.getModelPaths() else {
                throw Abort(.internalServerError, reason: "Model not configured")
            }
            
            if whisperReq.stream == true {
                // Check if client supports SSE
                let useSSE = self.supportsSSE(req)
                
                print("🚀 Starting streaming transcription (SSE: \(useSSE), format: \(responseFormat))")
                
                // Choose the appropriate streaming method based on format
                if responseFormat == "srt" || responseFormat == "vtt" || responseFormat == "verbose_json" {
                    print("📊 Using timestamp streaming for format: \(responseFormat)")
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
                                    case "srt":
                                        let startTime = WhisperTranscriptionService.formatSRTTimestamp(segment.startTime)
                                        let endTime = WhisperTranscriptionService.formatSRTTimestamp(segment.endTime)
                                        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        output = "\(segmentCounter)\n\(startTime) --> \(endTime)\n\(text)\n\n"
                                    case "vtt":
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
                                    case "verbose_json":
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
                                    let finalOutput = useSSE ? self.formatSSEData(output) : output
                                    let chunkSize = finalOutput.utf8.count
                                    print("📤 Sending streaming chunk #\(segmentCounter) (\(chunkSize) bytes, format: \(responseFormat), SSE: \(useSSE))")
                                    if responseFormat == "text" || responseFormat == "json" {
                                        print("   Content preview: \(String(finalOutput.prefix(100)))")
                                    }
                                    
                                    var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                    buffer.writeString(finalOutput)
                                    streamWriter.write(.buffer(buffer), promise: nil)
                                    
                                    print("✅ Chunk #\(segmentCounter) written to stream successfully")
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    print("🏁 Streaming with timestamps completion called")
                                    if useSSE {
                                        // Send SSE end event
                                        let endEvent = "event: end\ndata: \n\n"
                                        print("📤 Sending SSE end event (\(endEvent.utf8.count) bytes)")
                                        var buffer = req.byteBufferAllocator.buffer(capacity: endEvent.utf8.count)
                                        buffer.writeString(endEvent)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                        print("✅ SSE end event written to stream")
                                    }
                                    streamWriter.write(.end, promise: nil)
                                    print("🔚 Stream ended, cleaning up temp file")
                                    try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                                }
                            }
                        )
                        if !success {
                            req.eventLoop.execute {
                                print("❌ Streaming with timestamps failed")
                                streamWriter.write(.end, promise: nil)
                                try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                            }
                        }
                    })
                    var headers = HTTPHeaders()
                    if useSSE {
                        headers.add(name: "Content-Type", value: "text/event-stream")
                        headers.add(name: "Cache-Control", value: "no-cache")
                        headers.add(name: "Connection", value: "keep-alive")
                        headers.add(name: "Access-Control-Allow-Origin", value: "*")
                    } else {
                        let contentType = responseFormat == "srt" ? "application/x-subrip" : 
                                         responseFormat == "vtt" ? "text/vtt" : "application/json"
                        headers.add(name: "Content-Type", value: contentType)
                    }
                    return Response(status: .ok, headers: headers, body: body)
                } else {
                    // Use regular streaming for simple formats (json, text)
                    print("📝 Using regular streaming for format: \(responseFormat)")
                    let body = Response.Body(stream: { streamWriter in
                        let success = WhisperTranscriptionService.transcribeAudioStream(
                            at: tempFileURL,
                            language: whisperReq.language,
                            prompt: whisperReq.prompt,
                            modelPaths: modelPaths,
                            onSegment: { segment in
                                req.eventLoop.execute {
                                    let output: String
                                    switch responseFormat {
                                    case "json":
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
                                    let finalOutput = useSSE ? self.formatSSEData(output) : output
                                    let chunkSize = finalOutput.utf8.count
                                    print("📤 Sending regular streaming chunk (\(chunkSize) bytes, format: \(responseFormat), SSE: \(useSSE))")
                                    print("   Content preview: \(String(finalOutput.prefix(100)))")
                                    
                                    var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
                                    buffer.writeString(finalOutput)
                                    streamWriter.write(.buffer(buffer), promise: nil)
                                    
                                    print("✅ Regular chunk written to stream successfully")
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    print("🏁 Regular streaming completion called")
                                    if useSSE {
                                        // Send SSE end event
                                        let endEvent = "event: end\ndata: \n\n"
                                        print("📤 Sending SSE end event (\(endEvent.utf8.count) bytes)")
                                        var buffer = req.byteBufferAllocator.buffer(capacity: endEvent.utf8.count)
                                        buffer.writeString(endEvent)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                        print("✅ SSE end event written to stream")
                                    }
                                    streamWriter.write(.end, promise: nil)
                                    print("🔚 Stream ended, cleaning up temp file")
                                    try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                                }
                            }
                        )
                        if !success {
                            req.eventLoop.execute {
                                print("❌ Regular streaming failed")
                                streamWriter.write(.end, promise: nil)
                                try? FileManager.default.removeItem(at: tempFileURL) // Clean up
                            }
                        }
                    })
                    var headers = HTTPHeaders()
                    if useSSE {
                        headers.add(name: "Content-Type", value: "text/event-stream")
                        headers.add(name: "Cache-Control", value: "no-cache")
                        headers.add(name: "Connection", value: "keep-alive")
                        headers.add(name: "Access-Control-Allow-Origin", value: "*")
                    } else {
                        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                    }
                    return Response(status: .ok, headers: headers, body: body)
                }
            } else {
                // Non-streaming case - determine which transcription method to use
                let responseBody: String
                let contentType: String
                
                // Handle subtitle formats that need timestamps
                if responseFormat == "srt" || responseFormat == "vtt" || responseFormat == "verbose_json" {
                    if let segments = WhisperTranscriptionService.transcribeAudioWithTimestamps(
                        at: tempFileURL, language: whisperReq.language, prompt: whisperReq.prompt, modelPaths: modelPaths
                    ) {
                        switch responseFormat {
                        case "srt":
                            responseBody = WhisperTranscriptionService.formatAsSRT(segments: segments)
                            contentType = "application/x-subrip"
                        case "vtt":
                            responseBody = WhisperTranscriptionService.formatAsVTT(segments: segments)
                            contentType = "text/vtt"
                        case "verbose_json":
                            responseBody = WhisperTranscriptionService.formatAsVerboseJSON(segments: segments)
                            contentType = "application/json"
                        default:
                            responseBody = "Unsupported response format"
                            contentType = "text/plain"
                        }
                    } else {
                        responseBody = "{\"error\": \"Failed to transcribe audio with timestamps\"}"
                        contentType = "application/json"
                    }
                } else {
                    // Handle regular formats (json, text) - use faster transcription without timestamps
                    if let transcription = WhisperTranscriptionService.transcribeAudio(
                        at: tempFileURL, language: whisperReq.language, prompt: whisperReq.prompt, modelPaths: modelPaths
                    ) {
                        switch responseFormat {
                        case "json":
                            let jsonResponse = ["text": transcription]
                            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                               let jsonString = String(data: jsonData, encoding: .utf8) {
                                responseBody = jsonString
                                contentType = "application/json"
                            } else {
                                responseBody = "{\"error\": \"Failed to create JSON response.\"}"
                                contentType = "application/json"
                            }
                        case "text":
                            responseBody = transcription
                            contentType = "text/plain"
                        default:
                            responseBody = "Unsupported response format"
                            contentType = "text/plain"
                        }
                    } else {
                        responseBody = "{\"error\": \"Transcription failed\"}"
                        contentType = "application/json"
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