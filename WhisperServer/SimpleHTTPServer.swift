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
        
        // Keep track of accumulated data
        var receivedData = Data()
        var expectedContentLength: Int?
        var headersParsed = false
        
        // Function to read more data from the connection
        func receiveMoreData() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                
                // Error handling
                if let error = error {
                    print("❌ Error receiving data: \(error.localizedDescription)")
                    connection.cancel()
                    return
                }
                
                // Handle received data
                if let data = data, !data.isEmpty {
                    print("📥 Received \(data.count) bytes of data (total: \(receivedData.count + data.count))")
                    receivedData.append(data)
                    
                    // Parse headers if we haven't yet
                    if !headersParsed, let headerEndIndex = receivedData.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A]))?.lowerBound {
                        headersParsed = true
                        expectedContentLength = self.extractContentLength(from: receivedData[0..<headerEndIndex])
                    }
                }
                
                // Determine if request is complete
                let isRequestComplete = isComplete || 
                                     (expectedContentLength != nil && receivedData.count >= expectedContentLength!)
                
                if isRequestComplete && !receivedData.isEmpty {
                    // Process the complete request
                    print("✅ Received complete request of \(receivedData.count) bytes")
                    self.processReceivedData(receivedData, connection: connection)
                } else if isComplete && receivedData.isEmpty {
                    print("⚠️ Received empty request")
                    self.sendDefaultResponse(to: connection)
                } else {
                    // Need to receive more data
                    receiveMoreData()
                }
            }
        }
        
        // Start receiving data
        receiveMoreData()
    }
    
    // Helper method to extract Content-Length from headers data
    private func extractContentLength(from headersData: Data) -> Int? {
        guard let headersString = String(data: headersData, encoding: .utf8) else { return nil }
        
        print("📋 Parsed HTTP headers: \(headersString.count) bytes")
        
        let headerLines = headersString.components(separatedBy: "\r\n")
        for line in headerLines {
            if line.lowercased().starts(with: "content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                let length = Int(value)
                print("📋 Content-Length detected: \(length ?? 0) bytes")
                return length
            }
        }
        
        return nil
    }
    
    // Helper method to process received data
    private func processReceivedData(_ data: Data, connection: NWConnection) {
        // Process HTTP request
        if let request = self.parseHTTPRequest(data: data) {
            self.routeRequest(connection: connection, request: request)
        } else {
            print("⚠️ Failed to parse HTTP request")
            self.sendDefaultResponse(to: connection)
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
            self.logRequestDebugInfo(request)
            self.sendErrorResponse(to: connection, message: "Invalid request")
            return
        }
        
        // Create request based on content type
        let contentType = self.getContentTypeHeader(from: headers)
        var whisperRequest = WhisperAPIRequest()
        
        // Check for multipart/form-data in a case-insensitive way
        if contentType.lowercased().contains("multipart/form-data") {
            print("📋 Processing multipart/form-data request of size \(body.count) bytes")
            whisperRequest = parseMultipartFormData(data: body, contentType: contentType)
        } else {
            print("📋 Processing raw body as audio data")
            whisperRequest.audioData = body
        }
        
        if !whisperRequest.isValid {
            print("❌ Error: Request does not contain valid audio data")
            print("💾 Body size: \(body.count) bytes")
            self.sendErrorResponse(to: connection, message: "Invalid request: Missing audio file")
            return
        }
        
        print("✅ Successfully extracted audio data of size \(whisperRequest.audioData?.count ?? 0) bytes")
        
        // Perform transcription in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            print("🔄 Starting transcription of audio")
            
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
    
    // Helper method to log request debug info
    private func logRequestDebugInfo(_ request: [String: Any]) {
        if let headers = request["headers"] {
            print("📋 Headers type: \(type(of: headers))")
        } else {
            print("📋 No 'headers' key found in request")
        }
        
        if let body = request["body"] {
            print("📋 Body type: \(type(of: body)), length: \(String(describing: (body as? Data)?.count ?? 0))")
        } else {
            print("📋 No 'body' key found in request")
        }
    }
    
    // Helper method to get content type header (case-insensitive)
    private func getContentTypeHeader(from headers: [String: String]) -> String {
        let contentTypeHeader = headers.keys.first(where: { $0.lowercased() == "content-type" })
        let contentType = contentTypeHeader.flatMap { headers[$0] } ?? ""
        print("📋 Content-Type: \(contentType)")
        return contentType
    }
    
    // MARK: - Processing multipart/form-data
    
    /// Parses multipart/form-data content
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        // Extract boundary from Content-Type
        guard let boundary = extractBoundary(from: contentType) else {
            print("❌ Failed to extract boundary from Content-Type: \(contentType)")
            return request
        }
        
        print("📋 Extracted boundary: \"\(boundary)\"")
        
        // Find boundary data in different formats
        guard let (boundaryData, boundaryString) = findWorkingBoundary(boundary, in: data) else {
            print("❌ Failed to find working boundary in request data")
            return request
        }
        
        print("📋 Using boundary: \"\(boundaryString)\"")
        guard let doubleCRLF = "\r\n\r\n".data(using: .utf8) else { return request }
        
        // Find the first boundary
        guard let firstBoundaryPos = findNextPosition(of: boundaryData, in: data, startingAt: 0) else {
            print("❌ Could not find boundary in the data")
            return request
        }
        
        var currentPos = firstBoundaryPos
        var partCount = 0
        
        // Process each part
        while currentPos < data.count {
            guard let nextPart = processNextPart(
                in: data, 
                from: &currentPos, 
                boundaryData: boundaryData, 
                doubleCRLF: doubleCRLF
            ) else {
                break // No more parts or error
            }
            
            if let fieldName = nextPart.fieldName, let content = nextPart.content {
                print("📋 Found field: \(fieldName) with \(content.count) bytes")
                processFieldContent(fieldName: fieldName, data: content, request: &request)
                partCount += 1
            }
        }
        
        print("📋 Processed \(partCount) parts in multipart form data")
        
        return request
    }
    
    // Helper to extract boundary from content type
    private func extractBoundary(from contentType: String) -> String? {
        let boundaryPrefixes = ["boundary=", "boundary=\"", "boundary=\'"]
        
        for prefix in boundaryPrefixes {
            if let range = contentType.range(of: prefix) {
                let boundaryStart = range.upperBound
                
                // Handle quoted or unquoted boundaries
                if prefix.hasSuffix("\"") || prefix.hasSuffix("\'") {
                    let quoteChar = prefix.last!
                    if let endRange = contentType[boundaryStart...].firstIndex(of: quoteChar) {
                        return String(contentType[boundaryStart..<endRange])
                    }
                } else if let endRange = contentType[boundaryStart...].firstIndex(of: ";") {
                    return String(contentType[boundaryStart..<endRange])
                } else {
                    return String(contentType[boundaryStart...])
                }
            }
        }
        
        return nil
    }
    
    // Helper to find a working boundary format in the data
    private func findWorkingBoundary(_ boundary: String, in data: Data) -> (Data, String)? {
        let possibleBoundaries = ["--\(boundary)", boundary]
        
        for boundaryString in possibleBoundaries {
            if let boundaryBytes = boundaryString.data(using: .utf8),
               findNextPosition(of: boundaryBytes, in: data, startingAt: 0) != nil {
                return (boundaryBytes, boundaryString)
            }
        }
        
        return nil
    }
    
    // Helper to process the next multipart part
    private func processNextPart(
        in data: Data,
        from currentPos: inout Int,
        boundaryData: Data,
        doubleCRLF: Data
    ) -> (fieldName: String?, content: Data?)? {
        
        // Find next boundary
        guard let boundaryPos = findNextPosition(of: boundaryData, in: data, startingAt: currentPos) else {
            return nil
        }
        
        // Check if this is the final boundary
        let isFinalBoundary = boundaryPos + boundaryData.count + 2 <= data.count &&
                             data[boundaryPos + boundaryData.count] == 0x2D &&
                             data[boundaryPos + boundaryData.count + 1] == 0x2D
        
        if isFinalBoundary {
            return nil
        }
        
        // Ensure we have enough data for CRLF
        guard boundaryPos + boundaryData.count + 2 < data.count,
              data[boundaryPos + boundaryData.count] == 0x0D,
              data[boundaryPos + boundaryData.count + 1] == 0x0A else {
            currentPos = boundaryPos + boundaryData.count
            return nil
        }
        
        let partStart = boundaryPos + boundaryData.count + 2
        
        // Find headers end
        guard let headersEnd = findNextPosition(of: doubleCRLF, in: data, startingAt: partStart) else {
            currentPos = partStart
            return nil
        }
        
        // Parse headers
        guard let headersString = String(data: data.subdata(in: partStart..<headersEnd), encoding: .utf8) else {
            currentPos = headersEnd + doubleCRLF.count
            return nil
        }
        
        // Extract field name
        let headers = parsePartHeaders(headersString)
        guard let contentDisposition = headers["Content-Disposition"],
              let fieldName = extractFieldName(from: contentDisposition) else {
            currentPos = headersEnd + doubleCRLF.count
            return nil
        }
        
        // Extract content
        let contentStart = headersEnd + doubleCRLF.count
        let nextBoundaryPos = findNextPosition(of: boundaryData, in: data, startingAt: contentStart) ?? data.count
        
        // Handle CRLF before boundary
        let contentEnd = nextBoundaryPos >= 2 && data[nextBoundaryPos-2] == 0x0D && data[nextBoundaryPos-1] == 0x0A
            ? nextBoundaryPos - 2 : nextBoundaryPos
        
        // Return the extracted content if valid
        let content = contentStart < contentEnd ? data.subdata(in: contentStart..<contentEnd) : nil
        currentPos = nextBoundaryPos
        
        return (fieldName, content)
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
} 