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
            
            // Configure handlers
            configureStateHandler()
            configureConnectionHandler()
            
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
    
    // MARK: - Listener Configuration
    
    /// Configures state handler for the listener
    private func configureStateHandler() {
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
    }
    
    /// Configures handler for new connections
    private func configureConnectionHandler() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.handleConnection(connection)
        }
    }
    
    // MARK: - Connection Handling
    
    /// Handles an incoming network connection
    /// - Parameter connection: New network connection
    private func handleConnection(_ connection: NWConnection) {
        print("📥 Received new connection")
        
        // Maximum request size (50 MB for large audio files)
        let maxRequestSize = 50 * 1024 * 1024
        
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
            if data.count > maxRequestSize {
                print("⚠️ Exceeded maximum request size (\(maxRequestSize / 1024 / 1024) MB)")
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
        
        // Find delimiter between headers and body (double CRLF: \r\n\r\n)
        let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n as data
        
        // Find boundary between headers and body
        guard let headerEndIndex = find(pattern: doubleCRLF, in: data) else {
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
    
    /// Helper method to find pattern in data
    /// - Parameters:
    ///   - pattern: Pattern to search for
    ///   - data: Data to search in
    /// - Returns: Start index of found pattern or nil if pattern not found
    private func find(pattern: Data, in data: Data) -> Int? {
        guard !pattern.isEmpty, !data.isEmpty, pattern.count <= data.count else { 
            return nil 
        }
        
        let patternLength = pattern.count
        let dataLength = data.count
        let lastPossibleIndex = dataLength - patternLength
        
        for i in 0...lastPossibleIndex {
            var matched = true
            
            for j in 0..<patternLength {
                if data[i + j] != pattern[j] {
                    matched = false
                    break
                }
            }
            
            if matched {
                return i
            }
        }
        
        return nil
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
        var whisperRequest: WhisperAPIRequest
        
        if contentType.starts(with: "multipart/form-data") {
            whisperRequest = parseMultipartFormData(data: body, contentType: contentType)
            
            // Fallback to direct parsing if needed
            if !whisperRequest.isValid && body.count > 1000 {
                whisperRequest = parseAudioDataDirectly(from: body, contentType: contentType)
            }
        } else {
            var request = WhisperAPIRequest()
            request.audioData = body
            whisperRequest = request
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
            if case .failed(_) = connection.state { return }
            
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
    
    /// Alternative method for direct extraction of audio data from request
    private func parseAudioDataDirectly(from body: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        // Check for WAV header
        if body.count > 12, body[0] == 0x52, body[1] == 0x49, body[2] == 0x46, body[3] == 0x46 {
            request.audioData = body
            print("✅ Found WAV data directly in body")
        } 
        // Check for MP3 header
        else if body.count > 3, (body[0] == 0x49 && body[1] == 0x44 && body[2] == 0x33) || 
                (body[0] == 0xFF && body[1] == 0xFB) {
            request.audioData = body
            print("✅ Found MP3 data directly in body")
        }
        // Assume raw audio data
        else if body.count > 1000 {
            request.audioData = body
            print("⚠️ Assuming raw audio data in body")
        }
        
        return request
    }
    
    // MARK: - Processing multipart/form-data
    
    /// Parses multipart/form-data content
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        // Extract boundary from Content-Type
        let boundaryComponents = contentType.components(separatedBy: "boundary=")
        guard boundaryComponents.count > 1 else {
            print("❌ Boundary not found in Content-Type")
            return request
        }
        
        // Extract boundary
        var boundary = boundaryComponents[1]
        if boundary.contains(";") {
            boundary = boundary.components(separatedBy: ";")[0]
        }
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        
        // Create boundary data
        let fullBoundaryString = "--\(boundary)"
        let endBoundaryString = "--\(boundary)--"
        
        guard let fullBoundary = fullBoundaryString.data(using: .utf8),
              let endBoundary = endBoundaryString.data(using: .utf8) else {
            print("❌ Failed to create boundaries as data")
            return request
        }
        
        // Find all boundary positions
        var boundaryPositions: [Int] = []
        var currentPosition = 0
        
        while currentPosition < data.count - fullBoundary.count {
            if let nextPosition = find(pattern: fullBoundary, in: data.subdata(in: currentPosition..<data.count)) {
                let absolutePosition = currentPosition + nextPosition
                boundaryPositions.append(absolutePosition)
                currentPosition = absolutePosition + fullBoundary.count
            } else {
                break
            }
        }
        
        // Check for end boundary
        if let endBoundaryPosition = find(pattern: endBoundary, in: data) {
            boundaryPositions.append(endBoundaryPosition)
        }
        
        guard boundaryPositions.count > 1 else {
            print("❌ Insufficient boundaries found in data")
            return request
        }
        
        // Process each part between boundaries
        for i in 0..<(boundaryPositions.count - 1) {
            let partStart = boundaryPositions[i] + fullBoundary.count + 2 // +2 for \r\n after boundary
            let partEnd = boundaryPositions[i + 1]
            
            if partStart >= partEnd || partStart >= data.count { continue }
            
            let partData = data.subdata(in: partStart..<partEnd)
            
            // Find headers/content delimiter
            let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])
            guard let headerEndIndex = find(pattern: doubleCRLF, in: partData) else { continue }
            
            // Parse headers
            let headersData = partData.prefix(headerEndIndex)
            guard let headersString = String(data: headersData, encoding: .utf8) else { continue }
            
            var headers: [String: String] = [:]
            let headerLines = headersString.components(separatedBy: "\r\n")
            for line in headerLines where !line.isEmpty {
                let headerComponents = line.components(separatedBy: ": ")
                if headerComponents.count >= 2 {
                    headers[headerComponents[0]] = headerComponents.dropFirst().joined(separator: ": ")
                }
            }
            
            // Extract field information
            guard let contentDisposition = headers["Content-Disposition"],
                  let fieldName = extractFieldName(from: contentDisposition) else { continue }
            
            // Extract content
            let contentStartIndex = headerEndIndex + doubleCRLF.count
            guard contentStartIndex < partData.count else { continue }
            
            let contentData = partData.subdata(in: contentStartIndex..<partData.count)
            processFieldContent(fieldName: fieldName, data: contentData, request: &request)
        }
        
        return request
    }
    
    /// Extracts field name from Content-Disposition header
    private func extractFieldName(from contentDisposition: String) -> String? {
        guard let nameMatch = contentDisposition.range(of: "name=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let nameStart = contentDisposition.index(nameMatch.lowerBound, offsetBy: 6)
        let nameEnd = contentDisposition.index(nameMatch.upperBound, offsetBy: -1)
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
            body: responseBody,
            onSuccess: { print("✅ Transcription response sent successfully") }
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
            let jsonResponse: [String: Any] = ["text": text]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ("application/json", jsonString)
            } else {
                return ("application/json", "{\"text\": \"Error creating JSON response\"}")
            }
            
        case .verbose_json:
            // Split text into segments for example
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
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: verboseResponse),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ("application/json", jsonString)
            } else {
                return ("application/json", "{\"text\": \"Error creating verbose JSON response\"}")
            }
            
        case .text:
            return ("text/plain", text)
            
        case .srt:
            // Split text into segments for creating subtitles
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let estimatedDuration = Double(text.count) / 20.0
            let midpoint = estimatedDuration / 2.0
            
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
            // Split text into segments for creating subtitles
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let estimatedDuration = Double(text.count) / 20.0
            let midpoint = estimatedDuration / 2.0
            
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
        let errorResponse: [String: Any] = [
            "error": [
                "message": message,
                "type": "invalid_request_error"
            ]
        ]
        
        var responseBody = "{\"error\": {\"message\": \"Server error\"}}"
        if let jsonData = try? JSONSerialization.data(withJSONObject: errorResponse),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            responseBody = jsonString
        }
        
        self.sendHTTPResponse(
            to: connection,
            statusCode: 400,
            statusMessage: "Bad Request",
            contentType: "application/json",
            body: responseBody,
            onSuccess: { print("✅ Error response sent") }
        )
    }
    
    /// Sends standard "OK" response
    /// - Parameter connection: Connection for sending response
    private func sendDefaultResponse(to connection: NWConnection) {
        self.sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: "text/plain",
            body: "OK",
            onSuccess: { print("✅ Standard response sent") }
        )
    }
    
    /// Sends HTTP response to connection
    /// - Parameters:
    ///   - connection: Network connection
    ///   - statusCode: HTTP status code
    ///   - statusMessage: HTTP status message
    ///   - contentType: Content type
    ///   - body: Response body
    ///   - onSuccess: Closure called on successful sending
    private func sendHTTPResponse(
        to connection: NWConnection,
        statusCode: Int,
        statusMessage: String,
        contentType: String,
        body: String,
        onSuccess: @escaping () -> Void
    ) {
        // Check connection state first
        if case .cancelled = connection.state { return }
        if case .failed(_) = connection.state { return }
        
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
                onSuccess()
            }
            
            // Close connection after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if case .cancelled = connection.state { return }
                connection.cancel()
            }
        })
    }
} 