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

    /// Tracks the Whisper model currently loaded in the transcription context
    private var activeWhisperModelID: String?
    
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

    /// REST response model for GET /v1/models
    private struct APIModelListResponse: Content {
        let object: String
        let data: [APIModelResource]
    }

    /// Individual model descriptor for API responses
    private struct APIModelResource: Content {
        let id: String
        let object: String
        let ownedBy: String
        let created: Int
        let provider: String
        let name: String
        let type: String
        let aliases: [String]?
        let supportsStreaming: Bool
        let isDefault: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case ownedBy = "owned_by"
            case created
            case provider
            case name
            case type
            case aliases
            case supportsStreaming = "supports_streaming"
            case isDefault = "default"
        }
    }

    /// Parses response format string, returning json as default when nil
    /// - Throws: Abort(.badRequest) for unsupported formats provided by the client
    private func parseResponseFormat(_ raw: String?) throws -> WhisperSubtitleFormatter.ResponseFormat {
        guard let raw = raw else { return .json }
        print("📦 parseResponseFormat called with \(raw)")
        if let format = WhisperSubtitleFormatter.ResponseFormat(rawValue: raw) {
            return format
        }
        throw Abort(.badRequest, reason: "Unsupported response_format '\(raw)'")
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
    /// Writes a text chunk to the stream, wrapping as SSE if needed
    private func writeChunk(_ output: String, req: Request, useSSE: Bool, writer: (ByteBuffer) -> Void) {
        let finalOutput = self.wrapForSSE(output, enabled: useSSE)
        var buffer = req.byteBufferAllocator.buffer(capacity: finalOutput.utf8.count)
        buffer.writeString(finalOutput)
        writer(buffer)
    }

    /// Finishes the streaming response, optionally emitting SSE end event, then executes cleanup
    private func finishStream(req: Request, useSSE: Bool, writer: (String) -> Void, end: () -> Void, cleanup: @escaping () -> Void) {
        if useSSE {
            let endEvent = "event: end\ndata: \n\n"
            writer(endEvent)
        }
        end()
        cleanup()
    }

    /// Encodes a JSON object to String (UTF-8). Returns nil on failure.
    private func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Ensures the requested Whisper model is available and resets the context if needed
    private func prepareWhisperModelForRequest(_ requestedModelID: String?) async throws -> (binPath: URL, encoderDir: URL) {
        let paths = try await modelManager.prepareModelForUse(modelID: requestedModelID)
        if let selectedID = modelManager.selectedModelID {
            if activeWhisperModelID != selectedID {
                WhisperTranscriptionService.reinitializeContext()
            }
            activeWhisperModelID = selectedID
        } else {
            WhisperTranscriptionService.reinitializeContext()
            activeWhisperModelID = nil
        }
        return paths
    }

    // MARK: - Routes
    
    private func routes(_ app: Application) throws {
        // Set a high limit for streaming body collection to handle large audio files.
        // Vapor streams requests larger than 16KB to a temporary file on disk by default.
        app.routes.defaultMaxBodySize = "1gb"

        app.get("v1", "models") { [self] _ -> APIModelListResponse in
            let currentProvider = self.modelManager.selectedProvider
            let selectedWhisperID = self.modelManager.selectedModelID
            let resolvedWhisperSelection = selectedWhisperID ?? self.modelManager.availableModels.first?.id

            let whisperModels = self.modelManager.availableModels.map { model -> APIModelResource in
                let isDefault = (currentProvider == .whisper && resolvedWhisperSelection == model.id)
                return APIModelResource(
                    id: model.id,
                    object: "model",
                    ownedBy: "whisperserver",
                    created: 0,
                    provider: Provider.whisper.rawValue,
                    name: model.name,
                    type: "audio.transcription",
                    aliases: nil,
                    supportsStreaming: true,
                    isDefault: isDefault
                )
            }

            let fluidDefaultModelID = FluidTranscriptionService.defaultModel.id
            let fluidModels = FluidTranscriptionService.availableModels.map { descriptor -> APIModelResource in
                let aliasCandidates = descriptor.allIdentifiers.filter { $0.caseInsensitiveCompare(descriptor.id) != .orderedSame }
                let aliases = aliasCandidates.isEmpty ? nil : aliasCandidates
                let isDefault = (currentProvider == .fluid && descriptor.id == fluidDefaultModelID)
                return APIModelResource(
                    id: descriptor.id,
                    object: "model",
                    ownedBy: "fluidaudio",
                    created: 0,
                    provider: Provider.fluid.rawValue,
                    name: descriptor.displayName,
                    type: "audio.transcription",
                    aliases: aliases,
                    supportsStreaming: true,
                    isDefault: isDefault
                )
            }

            let models = whisperModels + fluidModels
            return APIModelListResponse(object: "list", data: models)
        }

        app.post("v1", "audio", "transcriptions") { [self] req async throws -> Response in
            
            struct WhisperRequest: Content {
                var file: File
                var language: String?
                var prompt: String?
                var response_format: String?
                var stream: Bool?
                var model: String?    // optional model identifier; resolves across Whisper and FluidAudio catalogs
            }
            
            let whisperReq = try req.content.decode(WhisperRequest.self)
            
            // Generate a temporary file path
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = whisperReq.file.filename
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString + "-" + fileName)

            // Write the file buffer to the temporary path
            try await req.fileio.writeFile(whisperReq.file.data, at: tempFileURL.path)
            
            // Ensure temp file is cleaned on early error paths; disabled for streaming below
            var shouldCleanupTempFileOnExit = true
            let isStreaming = (whisperReq.stream == true)
            if isStreaming {
                // Streaming responses manage cleanup on completion
                shouldCleanupTempFileOnExit = false
            }
            defer {
                if shouldCleanupTempFileOnExit {
                    try? FileManager.default.removeItem(at: tempFileURL)
                }
            }
            
            let responseFormat: WhisperSubtitleFormatter.ResponseFormat
            do {
                responseFormat = try self.parseResponseFormat(whisperReq.response_format)
            } catch {
                try? FileManager.default.removeItem(at: tempFileURL)
                throw error
            }
            let requestedModelID = whisperReq.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModelID = (requestedModelID?.isEmpty ?? true) ? nil : requestedModelID

            // Early preflight: ensure the requested model (if any) exists across Fluid and Whisper catalogs
            let isKnownFluid = (normalizedModelID != nil) && (FluidTranscriptionService.modelDescriptor(for: normalizedModelID!) != nil)
            let isKnownWhisper = (normalizedModelID != nil) && (modelManager.availableModels.contains {
                $0.id.caseInsensitiveCompare(normalizedModelID!) == .orderedSame ||
                $0.name.caseInsensitiveCompare(normalizedModelID!) == .orderedSame
            })
            if let requested = normalizedModelID, !(isKnownFluid || isKnownWhisper) {
                let errorBody = "{\"error\": \"Model '\(requested)' is not available\"}"
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: self.contentType(for: .json))
                try? FileManager.default.removeItem(at: tempFileURL)
                return Response(status: .badRequest, headers: headers, body: .init(string: errorBody))
            }

            var provider: Provider
            var whisperModelID: String? = nil
            var fluidModelDescriptor: FluidTranscriptionService.ModelDescriptor?

            if let normalizedModelID,
               let descriptor = FluidTranscriptionService.modelDescriptor(for: normalizedModelID) {
                provider = .fluid
                fluidModelDescriptor = descriptor
            } else if normalizedModelID == nil,
                      modelManager.selectedProvider == .fluid {
                provider = .fluid
            } else {
                provider = .whisper
                whisperModelID = normalizedModelID
            }

            var modelPaths: (binPath: URL, encoderDir: URL)? = nil
            if provider == .whisper {
                do {
                    modelPaths = try await self.prepareWhisperModelForRequest(whisperModelID)
                } catch let error as ModelManager.ModelPreparationError {
                    switch error {
                    case .modelNotFound, .noModelSelected:
                        throw Abort(.badRequest, reason: error.localizedDescription)
                    default:
                        throw Abort(.internalServerError, reason: error.localizedDescription)
                    }
                } catch {
                    throw Abort(.internalServerError, reason: "Failed to prepare model: \(error.localizedDescription)")
                }

                if modelPaths == nil {
                    throw Abort(.internalServerError, reason: "Model not configured")
                }
            }

            var fluidLanguage = whisperReq.language
            if provider == .fluid {
                if fluidModelDescriptor == nil {
                    fluidModelDescriptor = FluidTranscriptionService.defaultModel
                }
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
                        if useSSE {
                            let prelude = ":ok\n\n"
                            var buffer = req.byteBufferAllocator.buffer(capacity: prelude.utf8.count)
                            buffer.writeString(prelude)
                            streamWriter.write(.buffer(buffer), promise: nil)
                        }
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
                                        output = (self.jsonString(segmentDict) ?? "") + "\n"
                                    default:
                                        output = segment.text
                                    }
                                    
                                    // Format output based on streaming method
                                    self.writeChunk(output, req: req, useSSE: useSSE) { buffer in
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                    }
                                    
                                    // Chunk written
                                }
                            },
                            onCompletion: {
                                req.eventLoop.execute {
                                    // Streaming completed
                                    self.finishStream(
                                        req: req,
                                        useSSE: useSSE,
                                        writer: { str in
                                            var buffer = req.byteBufferAllocator.buffer(capacity: str.utf8.count)
                                            buffer.writeString(str)
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        },
                                        end: {
                                            streamWriter.write(.end, promise: nil)
                                        },
                                        cleanup: {
                                            try? FileManager.default.removeItem(at: tempFileURL)
                                        }
                                    )
                                }
                            }
                        )
                        if !success {
                            req.eventLoop.execute {
                                self.finishStream(
                                    req: req,
                                    useSSE: useSSE,
                                    writer: { str in
                                        var buffer = req.byteBufferAllocator.buffer(capacity: str.utf8.count)
                                        buffer.writeString(str)
                                        streamWriter.write(.buffer(buffer), promise: nil)
                                    },
                                    end: {
                                        streamWriter.write(.end, promise: nil)
                                    },
                                    cleanup: {
                                        try? FileManager.default.removeItem(at: tempFileURL)
                                    }
                                )
                            }
                        }
                    })
                    let headers = self.buildHeaders(useSSE: useSSE, format: responseFormat)
                    return Response(status: .ok, headers: headers, body: body)
                case .json, .text:
                    // Streaming contract: send chunks as they are ready.
                    // For FluidAudio we will send a single chunk when final result is ready, then close.
                    let body = Response.Body(stream: { streamWriter in
                        if useSSE {
                            let prelude = ":ok\n\n"
                            var buffer = req.byteBufferAllocator.buffer(capacity: prelude.utf8.count)
                            buffer.writeString(prelude)
                            streamWriter.write(.buffer(buffer), promise: nil)
                        }
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
                                            output = (self.jsonString(jsonSegment) ?? "") + "\n"
                                        default: // text
                                            output = segment
                                        }

                                        // Format output based on streaming method
                                        self.writeChunk(output, req: req, useSSE: useSSE) { buffer in
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        }

                                        // Regular chunk written
                                    }
                                },
                                onCompletion: {
                                    req.eventLoop.execute {
                                        // Regular streaming completed
                                        self.finishStream(
                                            req: req,
                                            useSSE: useSSE,
                                            writer: { str in
                                                var buffer = req.byteBufferAllocator.buffer(capacity: str.utf8.count)
                                                buffer.writeString(str)
                                                streamWriter.write(.buffer(buffer), promise: nil)
                                            },
                                            end: {
                                                streamWriter.write(.end, promise: nil)
                                            },
                                            cleanup: {
                                                try? FileManager.default.removeItem(at: tempFileURL)
                                            }
                                        )
                                    }
                                }
                            )
                            if !success {
                                req.eventLoop.execute {
                                    self.finishStream(
                                        req: req,
                                        useSSE: useSSE,
                                        writer: { str in
                                            var buffer = req.byteBufferAllocator.buffer(capacity: str.utf8.count)
                                            buffer.writeString(str)
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        },
                                        end: {
                                            streamWriter.write(.end, promise: nil)
                                        },
                                        cleanup: {
                                            try? FileManager.default.removeItem(at: tempFileURL)
                                        }
                                    )
                                }
                            }
                        case .fluid:
                            // Do the work asynchronously, then emit a single chunk
                            Task {
                                let descriptor = fluidModelDescriptor ?? FluidTranscriptionService.defaultModel
                                let selectedLanguage = fluidLanguage
                                defer {
                                    req.eventLoop.execute {
                                        self.finishStream(
                                            req: req,
                                            useSSE: useSSE,
                                            writer: { str in
                                                var buffer = req.byteBufferAllocator.buffer(capacity: str.utf8.count)
                                                buffer.writeString(str)
                                                streamWriter.write(.buffer(buffer), promise: nil)
                                            },
                                            end: {
                                                streamWriter.write(.end, promise: nil)
                                            },
                                            cleanup: {
                                                try? FileManager.default.removeItem(at: tempFileURL)
                                            }
                                        )
                                    }
                                }

                                if let transcription = await FluidTranscriptionService.transcribeText(
                                    at: tempFileURL,
                                    language: selectedLanguage,
                                    model: descriptor
                                ) {
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

                                    req.eventLoop.execute {
                                        self.writeChunk(output, req: req, useSSE: useSSE) { buffer in
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        }
                                    }
                                } else {
                                    let errorJSON = "{\"error\": \"Transcription failed\"}\n"
                                    req.eventLoop.execute {
                                        self.writeChunk(errorJSON, req: req, useSSE: useSSE) { buffer in
                                            streamWriter.write(.buffer(buffer), promise: nil)
                                        }
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
                        let descriptor = fluidModelDescriptor ?? FluidTranscriptionService.defaultModel
                        if let transcription = await FluidTranscriptionService.transcribeText(
                            at: tempFileURL,
                            language: fluidLanguage,
                            model: descriptor
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
