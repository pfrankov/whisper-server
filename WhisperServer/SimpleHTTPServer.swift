//
//  SimpleHTTPServer.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import Foundation
import Network

/// HTTP server for processing Whisper API requests
final class SimpleHTTPServer {
    // MARK: - Types
    
    /// API response formats
    private enum ResponseFormat: String {
        case json, text, srt, vtt, verbose_json
        
        static func from(string: String?) -> ResponseFormat {
            guard let string = string, !string.isEmpty else { return .json }
            return ResponseFormat(rawValue: string) ?? .json
        }
    }
    
    /// Whisper API request structure
    private struct WhisperAPIRequest {
        var audioData: Data?
        var prompt: String?
        var responseFormat: ResponseFormat = .json
        var temperature: Double = 0.0
        var language: String?
        
        var isValid: Bool {
            return audioData != nil && !audioData!.isEmpty
        }
    }
    
    // MARK: - Properties
    
    /// Port on which the server listens
    private let port: UInt16
    
    /// Flag indicating whether the server is running
    private(set) var isRunning = false
    
    /// Network listener for accepting incoming connections
    private var listener: NWListener?
    
    /// Queue for processing server operations
    private let serverQueue = DispatchQueue(label: "com.whisperserver.server", qos: .userInitiated)
    
    /// Maximum request size (50 MB for large audio files)
    private let maxRequestSize = 50 * 1024 * 1024
    
    // MARK: - Initialization
    
    /// Creates a new instance of HTTP server
    /// - Parameter port: Port to listen for connections
    init(port: UInt16) {
        self.port = port
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    /// Starts the HTTP server
    func start() {
        guard !isRunning else { return }
        
        do {
            // Create TCP parameters
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .loopback
            
            // Create the listener
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: self.port)!)
            
            // Configure state handler
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                
                switch state {
                case .ready:
                    self.isRunning = true
                    print("✅ HTTP server started on http://localhost:\(self.port)")
                    print("   Whisper API available at: http://localhost:\(self.port)/v1/audio/transcriptions")
                    
                case .failed(let error):
                    print("❌ HTTP server terminated with error: \(error.localizedDescription)")
                    self.stop()
                    
                case .cancelled:
                    self.isRunning = false
                    
                default:
                    break
                }
            }
            
            // Configure connection handler
            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.handleConnection(connection)
            }
            
            // Start listening for connections
            listener?.start(queue: serverQueue)
            
        } catch {
            print("❌ Failed to create HTTP server: \(error.localizedDescription)")
        }
    }
    
    /// Stops the HTTP server
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        listener?.cancel()
        listener = nil
        print("🛑 HTTP server stopped")
    }
    
    // MARK: - Connection Handling
    
    /// Handles an incoming network connection
    /// - Parameter connection: New network connection
    private func handleConnection(_ connection: NWConnection) {
        print("📥 Received new connection")
        
        // Start the connection
        connection.start(queue: serverQueue)
        
        // Configure data reception handler
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            // Error handling
            if let error = error {
                print("❌ Error receiving data: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            // Check for data presence
            guard let data = data, !data.isEmpty else {
                print("⚠️ Received empty data")
                self.sendDefaultResponse(to: connection)
                return
            }
            
            print("📥 Received \(data.count) bytes of data")
            
            // Check request size
            if data.count > self.maxRequestSize {
                print("⚠️ Exceeded maximum request size (\(self.maxRequestSize / 1024 / 1024) MB)")
                self.sendErrorResponse(to: connection, message: "Request too large")
                return
            }
            
            // Process HTTP request
            if let request = self.parseHTTPRequest(data: data) {
                self.routeRequest(connection: connection, request: request)
            } else {
                print("⚠️ Failed to parse HTTP request")
                self.sendDefaultResponse(to: connection)
            }
        }
    }
    
    // MARK: - Process HTTP Requests
    
    /// Parses HTTP request data
    /// - Parameter data: Unprocessed request data
    /// - Returns: Dictionary with request components or nil if parsing failed
    private func parseHTTPRequest(data: Data) -> [String: Any]? {
        print("🔍 Parsing HTTP request of size \(data.count) bytes")
        
        // Find delimiter between headers and body
        let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n as data
        
        guard let headerEndIndex = data.range(of: doubleCRLF)?.lowerBound else {
            print("❌ Failed to find boundary between headers and body")
            return nil
        }
        
        // Extract headers
        let headersData = data.prefix(headerEndIndex)
        guard let headersString = String(data: headersData, encoding: .utf8) else {
            print("❌ Failed to decode request headers as UTF-8")
            return nil
        }
        
        // Split headers into lines
        let lines = headersString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        
        // Parse request line (first line)
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 3 else {
            print("❌ Invalid request line format: \(lines[0])")
            return nil
        }
        
        let method = requestLine[0]
        let path = requestLine[1]
        
        print("📋 Method: \(method), Path: \(path)")
        
        // Parse headers
        var headers: [String: String] = [:]
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }
            
            let headerComponents = line.components(separatedBy: ": ")
            if headerComponents.count >= 2 {
                let key = headerComponents[0]
                let value = headerComponents.dropFirst().joined(separator: ": ")
                headers[key] = value
            }
        }
        
        // Extract request body (after double CRLF)
        let bodyStartIndex = headerEndIndex + doubleCRLF.count
        let body = data.count > bodyStartIndex ? data.subdata(in: bodyStartIndex..<data.count) : Data()
        
        return [
            "method": method,
            "path": path,
            "headers": headers,
            "body": body
        ]
    }
    
    /// Routes request to corresponding handler based on path
    /// - Parameters:
    ///   - connection: Network connection
    ///   - request: Parsed HTTP request
    private func routeRequest(connection: NWConnection, request: [String: Any]) {
        guard 
            let method = request["method"] as? String,
            let path = request["path"] as? String
        else {
            self.sendDefaultResponse(to: connection)
            return
        }
        
        print("📥 Received \(method) request: \(path)")
        
        // Check if this is a transcription request
        let normalizedPath = path.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPath.hasSuffix("/v1/audio/transcriptions") || normalizedPath == "/v1/audio/transcriptions" {
            print("✅ Processing transcription request")
            self.handleTranscriptionRequest(connection: connection, request: request)
        } else {
            print("❌ Unknown path: \(path)")
            self.sendDefaultResponse(to: connection)
        }
    }
    
    // MARK: - Processing API Requests
    
    /// Processes transcription audio request
    /// - Parameters:
    ///   - connection: Network connection
    ///   - request: Parsed HTTP request
    private func handleTranscriptionRequest(connection: NWConnection, request: [String: Any]) {
        guard 
            let headers = request["headers"] as? [String: String],
            let body = request["body"] as? Data, 
            !body.isEmpty
        else {
            print("❌ Invalid request: missing headers or body")
            self.sendErrorResponse(to: connection, message: "Invalid request")
            return
        }
        
        // Create request based on content type
        let contentType = headers["Content-Type"] ?? ""
        var whisperRequest = WhisperAPIRequest()
        
        if contentType.starts(with: "multipart/form-data") {
            whisperRequest = parseMultipartFormData(data: body, contentType: contentType)
        } else {
            whisperRequest.audioData = body
        }
        
        if !whisperRequest.isValid {
            print("❌ Error: Request does not contain valid audio data")
            self.sendErrorResponse(to: connection, message: "Invalid request: Missing audio file")
            return
        }
        
        // Perform transcription in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print("🔄 Starting transcription of audio of size \(whisperRequest.audioData!.count) bytes")
            
            let transcription = WhisperTranscriptionService.transcribeAudioData(
                whisperRequest.audioData!,
                language: whisperRequest.language,
                prompt: whisperRequest.prompt
            )
            
            // Check if connection is still active
            if case .cancelled = connection.state { return }
            if case .failed = connection.state { return }
            
            DispatchQueue.main.async {
                if let transcription = transcription {
                    print("✅ Transcription completed successfully: \"\(transcription.prefix(50))...\"")
                    self.sendTranscriptionResponse(
                        to: connection,
                        format: whisperRequest.responseFormat,
                        text: transcription,
                        temperature: whisperRequest.temperature
                    )
                } else {
                    print("❌ Failed to perform transcription")
                    self.sendErrorResponse(
                        to: connection,
                        message: "Transcription error: Ensure audio format is supported."
                    )
                }
            }
        }
    }
    
    // MARK: - Processing multipart/form-data
    
    /// Parses multipart/form-data content
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        // Extract boundary from Content-Type
        guard let boundaryRange = contentType.range(of: "boundary=") else {
            print("❌ Boundary not found in Content-Type")
            return request
        }
        
        var boundary = String(contentType[boundaryRange.upperBound...])
        if let semicolonIndex = boundary.firstIndex(of: ";") {
            boundary = String(boundary[..<semicolonIndex])
        }
        boundary = boundary.trimmingCharacters(in: .whitespaces)
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        
        // Create boundary data
        let fullBoundary = "--\(boundary)"
        guard let boundaryData = fullBoundary.data(using: .utf8),
              let doubleCRLF = "\r\n\r\n".data(using: .utf8) else {
            return request
        }
        
        // Split data by boundary
        var currentPos = 0
        while currentPos < data.count {
            // Find next boundary
            guard let boundaryPos = findNextPosition(of: boundaryData, in: data, startingAt: currentPos),
                  boundaryPos + boundaryData.count + 2 < data.count else {
                break
            }
            
            // Move past boundary and CRLF
            let partStart = boundaryPos + boundaryData.count + 2
            
            // Find headers end
            guard let headersEnd = findNextPosition(of: doubleCRLF, in: data, startingAt: partStart) else {
                currentPos = partStart
                continue
            }
            
            // Parse headers
            let headersData = data.subdata(in: partStart..<headersEnd)
            guard let headersString = String(data: headersData, encoding: .utf8) else {
                currentPos = headersEnd + doubleCRLF.count
                continue
            }
            
            // Extract field name
            let headers = parsePartHeaders(headersString)
            guard let contentDisposition = headers["Content-Disposition"],
                  let fieldName = extractFieldName(from: contentDisposition) else {
                currentPos = headersEnd + doubleCRLF.count
                continue
            }
            
            // Look for next boundary to find content end
            let contentStart = headersEnd + doubleCRLF.count
            let nextBoundaryPos = findNextPosition(of: boundaryData, in: data, startingAt: contentStart) ?? data.count
            
            // Extract content (removing trailing CRLF if present)
            let contentEnd = nextBoundaryPos >= 2 && data[nextBoundaryPos-2] == 0x0D && data[nextBoundaryPos-1] == 0x0A
                ? nextBoundaryPos - 2 : nextBoundaryPos
            
            if contentStart < contentEnd {
                let content = data.subdata(in: contentStart..<contentEnd)
                processFieldContent(fieldName: fieldName, data: content, request: &request)
            }
            
            currentPos = nextBoundaryPos
        }
        
        return request
    }
    
    /// Finds the next position of pattern in data
    private func findNextPosition(of pattern: Data, in data: Data, startingAt: Int) -> Int? {
        guard startingAt < data.count, !pattern.isEmpty, pattern.count <= data.count - startingAt else { 
            return nil 
        }
        
        let endIndex = data.count - pattern.count + 1
        for i in startingAt..<endIndex {
            var matches = true
            for j in 0..<pattern.count {
                if data[i + j] != pattern[j] {
                    matches = false
                    break
                }
            }
            if matches {
                return i
            }
        }
        return nil
    }
    
    /// Parses part headers into dictionary
    private func parsePartHeaders(_ headersString: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = headersString.components(separatedBy: "\r\n")
        
        for line in lines {
            guard !line.isEmpty else { continue }
            
            let components = line.components(separatedBy: ": ")
            if components.count >= 2 {
                let name = components[0]
                let value = components.dropFirst().joined(separator: ": ")
                headers[name] = value
            }
        }
        
        return headers
    }
    
    /// Extracts field name from Content-Disposition header
    private func extractFieldName(from contentDisposition: String) -> String? {
        guard let nameRange = contentDisposition.range(of: "name=\"", options: .caseInsensitive) else {
            return nil
        }
        
        let nameStart = nameRange.upperBound
        guard let nameEnd = contentDisposition[nameStart...].firstIndex(of: "\"") else {
            return nil
        }
        
        return String(contentDisposition[nameStart..<nameEnd])
    }
    
    /// Processes field content from multipart form
    private func processFieldContent(fieldName: String, data: Data, request: inout WhisperAPIRequest) {
        switch fieldName {
        case "file":
            request.audioData = data
            print("✅ Set audio data of size \(data.count) bytes")
            
        case "prompt":
            if let textValue = String(data: data, encoding: .utf8) {
                request.prompt = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
        case "response_format":
            if let textValue = String(data: data, encoding: .utf8) {
                request.responseFormat = ResponseFormat.from(string: textValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            
        case "temperature":
            if let textValue = String(data: data, encoding: .utf8),
               let temp = Double(textValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                request.temperature = temp
            }
            
        case "language":
            if let textValue = String(data: data, encoding: .utf8) {
                request.language = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
        default:
            break
        }
    }
    
    // MARK: - Sending Responses
    
    /// Sends transcription response to connection
    /// - Parameters:
    ///   - connection: Network connection
    ///   - format: Response format (json, text, etc.)
    ///   - text: Transcription text
    ///   - temperature: Temperature used in generation
    private func sendTranscriptionResponse(
        to connection: NWConnection, 
        format: ResponseFormat, 
        text: String,
        temperature: Double
    ) {
        let (contentType, responseBody) = createResponseBody(format: format, text: text, temperature: temperature)
        
        print("📤 Sending response in format \(format.rawValue)")
        
        sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: contentType,
            body: responseBody
        )
    }
    
    /// Creates response body in the required format
    /// - Parameters:
    ///   - format: Required response format
    ///   - text: Transcription text
    ///   - temperature: Temperature used in generation
    /// - Returns: Tuple with content type and response body
    private func createResponseBody(format: ResponseFormat, text: String, temperature: Double = 0.0) -> (contentType: String, body: String) {
        switch format {
        case .json:
            let jsonResponse = ["text": text]
            guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return ("application/json", "{\"text\": \"\(text)\"}")
            }
            return ("application/json", jsonString)
            
        case .verbose_json:
            // Split text into segments
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            // Approximate audio duration
            let estimatedDuration = Double(text.count) / 20.0
            
            let verboseResponse: [String: Any] = [
                "task": "transcribe",
                "language": "auto",
                "duration": estimatedDuration,
                "text": text,
                "segments": [
                    [
                        "id": 0,
                        "seek": 0,
                        "start": 0.0,
                        "end": estimatedDuration / 2.0,
                        "text": firstSegment,
                        "temperature": temperature,
                        "no_speech_prob": 0.1
                    ],
                    [
                        "id": 1,
                        "seek": 500,
                        "start": estimatedDuration / 2.0,
                        "end": estimatedDuration,
                        "text": secondSegment,
                        "temperature": temperature,
                        "no_speech_prob": 0.1
                    ]
                ]
            ]
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: verboseResponse),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return ("application/json", "{\"text\": \"\(text)\"}")
            }
            return ("application/json", jsonString)
            
        case .text:
            return ("text/plain", text)
            
        case .srt:
            // Create SRT subtitle format
            let estimatedDuration = Double(text.count) / 20.0
            let midpoint = estimatedDuration / 2.0
            
            // Split text for subtitles
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let srtText = """
            1
            00:00:00,000 --> 00:00:\(String(format: "%.3f", midpoint).replacingOccurrences(of: ".", with: ","))000
            \(firstSegment)
            
            2
            00:00:\(String(format: "%.3f", midpoint).replacingOccurrences(of: ".", with: ","))000 --> 00:00:\(String(format: "%.3f", estimatedDuration).replacingOccurrences(of: ".", with: ","))000
            \(secondSegment)
            """
            return ("text/plain", srtText)
            
        case .vtt:
            // Create VTT subtitle format
            let estimatedDuration = Double(text.count) / 20.0
            let midpoint = estimatedDuration / 2.0
            
            // Split text for subtitles
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let vttText = """
            WEBVTT
            
            00:00:00.000 --> 00:00:\(String(format: "%.3f", midpoint))
            \(firstSegment)
            
            00:00:\(String(format: "%.3f", midpoint)) --> 00:00:\(String(format: "%.3f", estimatedDuration))
            \(secondSegment)
            """
            return ("text/plain", vttText)
        }
    }
    
    /// Sends error response
    /// - Parameters:
    ///   - connection: Network connection
    ///   - message: Error message
    private func sendErrorResponse(to connection: NWConnection, message: String) {
        let errorResponse = [
            "error": [
                "message": message,
                "type": "invalid_request_error"
            ]
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: errorResponse),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            let fallbackResponse = "{\"error\": {\"message\": \"\(message)\"}}"
            sendHTTPResponse(to: connection, statusCode: 400, statusMessage: "Bad Request", 
                            contentType: "application/json", body: fallbackResponse)
            return
        }
        
        sendHTTPResponse(
            to: connection,
            statusCode: 400,
            statusMessage: "Bad Request",
            contentType: "application/json",
            body: jsonString
        )
    }
    
    /// Sends standard "OK" response
    /// - Parameter connection: Connection for sending response
    private func sendDefaultResponse(to connection: NWConnection) {
        sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: "text/plain",
            body: "OK"
        )
    }
    
    /// Sends HTTP response to connection
    /// - Parameters:
    ///   - connection: Network connection
    ///   - statusCode: HTTP status code
    ///   - statusMessage: HTTP status message
    ///   - contentType: Content type
    ///   - body: Response body
    private func sendHTTPResponse(
        to connection: NWConnection,
        statusCode: Int,
        statusMessage: String,
        contentType: String,
        body: String
    ) {
        // Check connection state first
        if case .cancelled = connection.state { return }
        if case .failed = connection.state { return }
        
        let contentLength = body.utf8.count
        let response = """
        HTTP/1.1 \(statusCode) \(statusMessage)
        Content-Type: \(contentType)
        Content-Length: \(contentLength)
        Connection: close
        
        \(body)
        """
        
        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            if let error = error {
                print("❌ Response sending error: \(error.localizedDescription)")
            } else {
                print("✅ Response sent successfully")
            }
            
            // Close connection after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if case .cancelled = connection.state { return }
                connection.cancel()
            }
        })
    }
} 