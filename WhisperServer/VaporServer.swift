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
            var env = try Environment.detect()
            try LoggingSystem.bootstrap(from: &env)
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
                    self.isRunning = true
                    print("✅ Vapor server started on http://localhost:\(self.port)")
                } catch {
                    print("❌ Failed to start Vapor server: \(error)")
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
                // Choose the appropriate streaming method based on format
                if responseFormat == "srt" || responseFormat == "vtt" || responseFormat == "verbose_json" {
                    // Use timestamp streaming for subtitle formats
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
                                    var buffer = req.byteBufferAllocator.buffer(capacity: output.utf8.count)
                                    buffer.writeString(output)
                                    streamWriter.write(.buffer(buffer), promise: nil)
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    streamWriter.write(.end, promise: nil)
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
                    var headers = HTTPHeaders()
                    let contentType = responseFormat == "srt" ? "application/x-subrip" : 
                                     responseFormat == "vtt" ? "text/vtt" : "application/json"
                    headers.add(name: "Content-Type", value: contentType)
                    return Response(status: .ok, headers: headers, body: body)
                } else {
                    // Use regular streaming for simple formats (json, text)
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
                                    var buffer = req.byteBufferAllocator.buffer(capacity: output.utf8.count)
                                    buffer.writeString(output)
                                    streamWriter.write(.buffer(buffer), promise: nil)
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    streamWriter.write(.end, promise: nil)
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
                    var headers = HTTPHeaders()
                    headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
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