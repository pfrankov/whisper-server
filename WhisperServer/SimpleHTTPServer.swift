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
        
        // Setting up retry attempts
        let maxRetries = 3
        var retryCount = 0
        var lastError: Error?
        
        func tryStartServer() {
            do {
                // Create TCP parameters
                let parameters = NWParameters.tcp
                
                // Set timeout for connections
                parameters.allowLocalEndpointReuse = true  // This allows the port to be reused faster if it was recently closed
                parameters.requiredInterfaceType = .loopback  // Listen only for local connections
                
                // Create port from UInt16
                let port = NWEndpoint.Port(rawValue: self.port)!
                
                // Initialize listener with parameters and port
                listener = try NWListener(using: parameters, on: port)
                
                // Configure handlers
                configureStateHandler()
                configureConnectionHandler()
                
                // Start listening for connections
                listener?.start(queue: serverQueue)
                
            } catch {
                lastError = error
                print("❌ Failed to create HTTP server: \(error.localizedDescription)")
                
                // Try to restart with a delay if maximum number of attempts is not exceeded
                if retryCount < maxRetries {
                    retryCount += 1
                    print("🔄 Retry attempt to start server (\(retryCount)/\(maxRetries)) in 2 seconds...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        tryStartServer()
                    }
                } else {
                    print("❌ Failed to start server after \(maxRetries) attempts: \(error.localizedDescription)")
                }
            }
        }
        
        // Launch first attempt
        tryStartServer()
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
            
            // Remove premature connection closing
            // defer {
            //     connection.cancel()
            // }
            
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
        print("🔍 Received HTTP request of size \(data.count) bytes")
        
        // Find delimiter between headers and body (double CRLF: \r\n\r\n)
        let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n as data
        
        // Find boundary between headers and body
        guard let headerEndIndex = self.find(pattern: doubleCRLF, in: data) else {
            print("❌ Failed to find boundary between headers and body of request")
            return nil
        }
        
        // Extract only headers for text parsing
        let headersData = data.prefix(headerEndIndex)
        
        // Try to decode headers as UTF-8 (this should always be possible)
        guard let headersString = String(data: headersData, encoding: .utf8) else {
            print("❌ Failed to decode request headers as UTF-8")
            return nil
        }
        
        print("📋 Request headers:\n\(headersString)")
        
        // Split headers into lines
        let lines = headersString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            print("❌ Request does not contain lines")
            return nil
        }
        
        // Parse request line (first line)
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 3 else {
            print("❌ Invalid request line format: \(lines[0])")
            return nil
        }
        
        let method = requestLine[0]
        let path = requestLine[1]
        
        print("�� Method: \(method), Path: \(path)")
        
        // Parse headers
        var headers: [String: String] = [:]
        
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue } // Skip empty lines
            
            let headerComponents = line.components(separatedBy: ": ")
            if headerComponents.count >= 2 {
                let key = headerComponents[0]
                let value = headerComponents.dropFirst().joined(separator: ": ")
                headers[key] = value
                print("📋 Header: \(key): \(value)")
            } else {
                print("⚠️ Invalid header format: \(line)")
            }
        }
        
        // Now extract request body (after double CRLF)
        let bodyStartIndex = headerEndIndex + doubleCRLF.count
        let body = data.count > bodyStartIndex ? data.subdata(in: bodyStartIndex..<data.count) : Data()
        
        print("✅ Request body successfully extracted, size: \(body.count) bytes")
        
        // For multipart/form-data requests, check for boundary presence
        if let contentType = headers["Content-Type"], 
           contentType.starts(with: "multipart/form-data") {
            
            print("📋 Detected multipart/form-data request")
            
            // If boundary is missing, try to determine it automatically
            if !contentType.contains("boundary=") {
                print("⚠️ Boundary missing in Content-Type, trying to determine automatically")
                
                // Search for possible boundary at the start of the body (usually starts with --)
                if body.count > 2, body[0] == 0x2D, body[1] == 0x2D { // "--" in ASCII
                    // Search for line ending with boundary
                    if let boundaryEndIndex = self.find(pattern: Data([0x0D, 0x0A]), in: body) {
                        let potentialBoundary = body.prefix(boundaryEndIndex)
                        if let boundaryString = String(data: potentialBoundary, encoding: .utf8) {
                            // Remove -- at the beginning
                            let boundary = boundaryString.dropFirst(2)
                            let newContentType = "\(contentType); boundary=\(boundary)"
                            print("✅ Automatically determined boundary: \(boundary)")
                            headers["Content-Type"] = newContentType
                        }
                    }
                }
            }
        }
        
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
        // Basic security checks
        guard !pattern.isEmpty, !data.isEmpty, pattern.count <= data.count else { 
            return nil 
        }
        
        // Simple implementation of substring search algorithm
        // For large data, consider more efficient algorithms (KMP, Boyer-Moore)
        let patternLength = pattern.count
        let dataLength = data.count
        
        // Last possible index from which pattern can start
        let lastPossibleIndex = dataLength - patternLength
        
        for i in 0...lastPossibleIndex {
            var matched = true
            
            for j in 0..<patternLength {
                // Safe index check
                guard i + j < dataLength else {
                    matched = false
                    break
                }
                
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
            print("❌ Failed to get request method or path")
            self.sendDefaultResponse(to: connection)
            return
        }
        
        print("📥 Received \(method) request: \(path)")
        
        // Normalize path and check against transcription endpoint
        let normalizedPath = path.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        print("🔍 Normalized path: \(normalizedPath)")
        
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
            let body = request["body"] as? Data
        else {
            print("❌ Error: Unable to get request headers or body")
            self.sendErrorResponse(to: connection, message: "Invalid request")
            return
        }
        
        // Debug information about size
        let bodyMB = Double(body.count) / 1024.0 / 1024.0
        print("📊 Request body size: \(body.count) bytes (\(String(format: "%.2f", bodyMB)) MB)")
        
        // Check for reasonable size
        if body.count < 100 {
            print("⚠️ Warning: Request body suspiciously small (\(body.count) bytes)")
            self.sendErrorResponse(to: connection, message: "Request body too small, possibly audio file not transmitted")
            return
        }
        
        if body.count > 100 * 1024 * 1024 { // > 100 MB
            print("⚠️ Warning: Request body suspiciously large (\(String(format: "%.2f", bodyMB)) MB)")
            self.sendErrorResponse(to: connection, message: "Request body too large, maximum audio file size - 100 MB")
            return
        }
        
        // Debug information about headers
        print("📋 Received headers:")
        for (key, value) in headers {
            print("   \(key): \(value)")
        }
        
        // Check Content-Type
        let contentTypeHeader = headers["Content-Type"] ?? ""
        print("📋 Content-Type: \(contentTypeHeader)")
        
        // Start processing time
        let startTime = Date()
        
        // Create request depending on content type
        var whisperRequest: WhisperAPIRequest
        
        if contentTypeHeader.starts(with: "multipart/form-data") {
            // Standard path for processing multipart/form-data
            print("🔄 Starting multipart/form-data parsing...")
            whisperRequest = self.parseMultipartFormData(data: body, contentType: contentTypeHeader)
            
            // If standard parser failed, try alternative approach
            if !whisperRequest.isValid && body.count > 0 {
                print("⚠️ Standard parser failed to extract audio data, trying alternative approach")
                whisperRequest = self.parseAudioDataDirectly(from: body, contentType: contentTypeHeader)
            }
        } else {
            // For other content types, simply use all body as audio data
            print("⚠️ Unusual content type, trying to process body as audio data directly")
            var request = WhisperAPIRequest()
            request.audioData = body
            whisperRequest = request
        }
        
        // Log parsing time
        let parsingTime = Date().timeIntervalSince(startTime)
        print("⏱️ Request parsing time: \(String(format: "%.2f", parsingTime)) seconds")
        
        if whisperRequest.isValid {
            // Set timeout for connection for long requests (10 minutes)
            let timeoutDispatchItem = DispatchWorkItem {
                // Check connection state
                if case .cancelled = connection.state {
                    return // Connection already closed
                }
                
                if case .failed(_) = connection.state {
                    return // Connection already in error
                }
                
                print("⚠️ Transcription waiting time exceeded (10 minutes), cancelling request")
                self.sendErrorResponse(to: connection, message: "Transcription processing time exceeded")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeoutDispatchItem)
            
            // Perform transcription using Whisper
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { 
                    timeoutDispatchItem.cancel()
                    return 
                }
                
                let transcriptionStartTime = Date()
                
                // Check audio data size
                if let audioData = whisperRequest.audioData {
                    let sizeMB = Double(audioData.count) / 1024.0 / 1024.0
                    print("🔄 Starting transcription of audio of size \(audioData.count) bytes (\(String(format: "%.2f", sizeMB)) MB)")
                    
                    // Additional data integrity check
                    if audioData.count < 1000 {
                        print("⚠️ Warning: audio file suspiciously small, possibly data truncated")
                    } else {
                        print("✅ Audio data size looks normal")
                    }
                } else {
                    print("⚠️ Strange, but audio data became nil, although isValid check passed")
                }
                
                // Use our transcription service for audio processing
                print("🔄 Starting transcription process...")
                let transcription = WhisperTranscriptionService.transcribeAudioData(
                    whisperRequest.audioData!,
                    language: whisperRequest.language,
                    prompt: whisperRequest.prompt
                )
                
                // Cancel timeout since transcription completed
                timeoutDispatchItem.cancel()
                
                // Calculate transcription time
                let transcriptionTime = Date().timeIntervalSince(transcriptionStartTime)
                print("⏱️ Transcription time: \(String(format: "%.2f", transcriptionTime)) seconds")
                
                // Check if connection is still active before sending response
                if case .cancelled = connection.state {
                    print("⚠️ Connection closed during transcription, response not sent")
                    return
                }
                
                if case .failed(_) = connection.state {
                    print("⚠️ Connection in error state, response not sent")
                    return
                }
                
                DispatchQueue.main.async {
                    if let transcription = transcription {
                        let previewLength = min(100, transcription.count)
                        let previewText = transcription.prefix(previewLength)
                        print("✅ Transcription completed successfully: \"\(previewText)...\" (\(transcription.count) characters)")
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
                    
                    // Total processing time for request
                    let totalTime = Date().timeIntervalSince(startTime)
                    print("⏱️ Total request processing time: \(String(format: "%.2f", totalTime)) seconds")
                }
            }
        } else {
            print("❌ Error: Request does not contain audio file or other required data")
            self.sendErrorResponse(to: connection, message: "Invalid request: Missing audio file")
        }
    }
    
    /// Alternative method for direct extraction of audio data from request
    /// - Parameters:
    ///   - body: Request body
    ///   - contentType: Content-Type header
    /// - Returns: WhisperAPIRequest with extracted data
    private func parseAudioDataDirectly(from body: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        print("🔍 Trying to determine audio data directly from body of size \(body.count) bytes")
        
        // Search for WAV header (RIFF)
        func findWavHeader(in data: Data) -> Int? {
            // WAV starts with "RIFF"
            let riffSignature = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF" in ASCII
            return self.find(pattern: riffSignature, in: data)
        }
        
        // Search for MP3 header (ID3 or MPEG frame sync)
        func findMp3Header(in data: Data) -> Int? {
            // ID3 tag starts with "ID3"
            let id3Signature = Data([0x49, 0x44, 0x33]) // "ID3" in ASCII
            
            // MPEG frame sync usually starts with 0xFF 0xFB or similar bytes
            let mpegFrameSync = Data([0xFF, 0xFB])
            
            if let id3Position = self.find(pattern: id3Signature, in: data) {
                return id3Position
            }
            
            return self.find(pattern: mpegFrameSync, in: data)
        }
        
        // Search for audio data
        var audioStart: Int? = nil
        
        // Check for WAV header presence
        if let wavPos = findWavHeader(in: body) {
            print("✅ Found WAV header at position \(wavPos)")
            audioStart = wavPos
        } 
        // Check for MP3 header presence
        else if let mp3Pos = findMp3Header(in: body) {
            print("✅ Found MP3 header at position \(mp3Pos)")
            audioStart = mp3Pos
        }
        // If no headers found but there's enough data, assume all body is audio
        else if body.count > 1000 {
            print("⚠️ Audio headers not found, but data exists - assuming all body may be audio")
            audioStart = 0
        }
        
        // If audio data start found, extract it
        if let start = audioStart {
            request.audioData = body.subdata(in: start..<body.count)
            print("✅ Extracted audio data of size \(request.audioData?.count ?? 0) bytes")
            
            // Add default parameters
            request.responseFormat = .json
        }
        
        return request
    }
    
    // MARK: - Processing multipart/form-data
    
    /// Parses multipart/form-data content
    /// - Parameters:
    ///   - data: Unprocessed multipart form data
    ///   - contentType: Content-Type header value
    /// - Returns: WhisperAPIRequest with parsed fields
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        print("🔍 Starting multipart/form-data parsing of size \(data.count) bytes")
        
        // Debug: output first 50 bytes of data in hex format
        if data.count > 50 {
            let previewBytes = data.prefix(50)
            let hexString = previewBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("�� First 50 bytes: \(hexString)")
        }
        
        // Extract boundary from Content-Type
        let boundaryComponents = contentType.components(separatedBy: "boundary=")
        guard boundaryComponents.count > 1 else {
            print("❌ Boundary not found in Content-Type: \(contentType)")
            return request
        }
        
        // Extract boundary, removing quotes if they exist
        var boundary = boundaryComponents[1]
        if boundary.contains(";") {
            boundary = boundary.components(separatedBy: ";")[0]
        }
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        print("✅ Found boundary: \(boundary)")
        
        // Create full boundary and end boundary as data
        // IMPORTANT: format boundary in body: "--boundary" (without \r\n!)
        let fullBoundaryString = "--\(boundary)"
        let endBoundaryString = "--\(boundary)--"
        
        guard let fullBoundary = fullBoundaryString.data(using: .utf8),
              let endBoundary = endBoundaryString.data(using: .utf8) else {
            print("❌ Failed to create boundaries as data")
            return request
        }
        
        print("🔍 Full boundary: \(fullBoundaryString)")
        print("🔍 End boundary: \(endBoundaryString)")
        
        // Debug: search boundary in first 100 bytes
        if data.count > 100 {
            let searchRange = data.prefix(100)
            if let firstBoundaryPos = self.find(pattern: fullBoundary, in: searchRange) {
                print("✅ Found first boundary at position \(firstBoundaryPos)")
                
                // Output 10 bytes before and after boundary for verification
                let startIdx = max(0, firstBoundaryPos - 10)
                let endIdx = min(searchRange.count, firstBoundaryPos + fullBoundary.count + 10)
                let contextData = searchRange.subdata(in: startIdx..<endIdx)
                let hexContext = contextData.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("🔍 Boundary context: \(hexContext)")
            } else {
                print("❌ Boundary not found in first 100 bytes")
            }
        }
        
        // Search for all boundary occurrences in data
        var boundaryPositions: [Int] = []
        
        // First search for first boundary
        if let firstPosition = self.find(pattern: fullBoundary, in: data) {
            boundaryPositions.append(firstPosition)
            
            // Now search for subsequent boundaries
            var currentPosition = firstPosition + fullBoundary.count
            
            while currentPosition < data.count - fullBoundary.count {
                if let nextPosition = self.find(pattern: fullBoundary, in: data.subdata(in: currentPosition..<data.count)) {
                    let absolutePosition = currentPosition + nextPosition
                    boundaryPositions.append(absolutePosition)
                    currentPosition = absolutePosition + fullBoundary.count
                } else {
                    break
                }
            }
        }
        
        // Also check for end boundary presence
        if let endBoundaryPosition = self.find(pattern: endBoundary, in: data) {
            boundaryPositions.append(endBoundaryPosition)
        }
        
        print("🔍 Found \(boundaryPositions.count) boundaries in data: \(boundaryPositions)")
        
        // If no boundaries, can't continue
        if boundaryPositions.isEmpty {
            print("❌ Boundaries not found in data")
            return request
        }
        
        // Process each part between boundaries
        for i in 0..<(boundaryPositions.count - 1) {
            // Start position of part (skip boundary and CRLF after it)
            let partStart = boundaryPositions[i] + fullBoundary.count + 2 // +2 for \r\n after boundary
            let partEnd = boundaryPositions[i + 1]
            
            if partStart >= partEnd || partStart >= data.count {
                print("⚠️ Empty or invalid part between boundaries \(i) and \(i+1): \(partStart) - \(partEnd)")
                continue
            }
            
            let partData = data.subdata(in: partStart..<partEnd)
            print("🔍 Processing part #\(i+1) of size \(partData.count) bytes")
            
            // Search for delimiter between headers and part content (double CRLF)
            let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            
            guard let headerEndIndex = self.find(pattern: doubleCRLF, in: partData) else {
                print("❌ Failed to find headers in part #\(i+1)")
                continue
            }
            
            // Extract headers
            let headersData = partData.prefix(headerEndIndex)
            guard let headersString = String(data: headersData, encoding: .utf8) else {
                print("❌ Failed to decode part #\(i+1) headers")
                continue
            }
            
            // Convert headers to dictionary
            var headers: [String: String] = [:]
            
            let headerLines = headersString.components(separatedBy: "\r\n")
            for line in headerLines where !line.isEmpty {
                let headerComponents = line.components(separatedBy: ": ")
                if headerComponents.count >= 2 {
                    let key = headerComponents[0]
                    let value = headerComponents.dropFirst().joined(separator: ": ")
                    headers[key] = value
                }
            }
            
            print("📋 Part #\(i+1) headers:")
            for (key, value) in headers {
                print("   \(key): \(value)")
            }
            
            // Extract field information from Content-Disposition
            guard let contentDisposition = headers["Content-Disposition"],
                  let fieldName = self.extractFieldName(from: contentDisposition) else {
                print("❌ Failed to extract field name from Content-Disposition header")
                continue
            }
            
            print("📋 Field name: \(fieldName)")
            
            // Extract filename if it exists
            let filename = self.extractFilename(from: contentDisposition)
            if let filename = filename {
                print("📋 Filename: \(filename)")
            }
            
            // Extract part content (after headers)
            let contentStartIndex = headerEndIndex + doubleCRLF.count
            
            if contentStartIndex < partData.count {
                let contentData = partData.subdata(in: contentStartIndex..<partData.count)
                print("📋 Field \(fieldName) content size: \(contentData.count) bytes")
                
                // Process different field types
                self.processFieldContent(fieldName: fieldName, data: contentData, request: &request)
            } else {
                print("⚠️ Empty content for field \(fieldName)")
            }
        }
        
        // Check if valid audio data exists
        if let audioData = request.audioData, !audioData.isEmpty {
            print("✅ Successfully parsed audio file of size \(audioData.count) bytes")
        } else {
            print("❌ Audio data not found in request")
        }
        
        return request
    }
    
    /// Extracts field name from Content-Disposition header
    /// - Parameter contentDisposition: Content-Disposition header value
    /// - Returns: Field name or nil if extraction failed
    private func extractFieldName(from contentDisposition: String) -> String? {
        guard let nameMatch = contentDisposition.range(of: "name=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let nameStart = contentDisposition.index(nameMatch.lowerBound, offsetBy: 6)
        let nameEnd = contentDisposition.index(nameMatch.upperBound, offsetBy: -1)
        return String(contentDisposition[nameStart..<nameEnd])
    }
    
    /// Extracts filename from Content-Disposition header
    /// - Parameter contentDisposition: Content-Disposition header value
    /// - Returns: Filename or nil if no file
    private func extractFilename(from contentDisposition: String) -> String? {
        guard let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let filenameStart = contentDisposition.index(filenameMatch.lowerBound, offsetBy: 10)
        let filenameEnd = contentDisposition.index(filenameMatch.upperBound, offsetBy: -1)
        return String(contentDisposition[filenameStart..<filenameEnd])
    }
    
    /// Processes field content
    /// - Parameters:
    ///   - fieldName: Field name
    ///   - data: Field content data
    ///   - request: Request for update
    private func processFieldContent(fieldName: String, data: Data, request: inout WhisperAPIRequest) {
        // Show start of data (if possible as text)
        let previewSize = min(20, data.count)
        if let textPreview = String(data: data.prefix(previewSize), encoding: .utf8) {
            print("🔍 Start of content \(fieldName) (text): \(textPreview)")
        } else {
            print("🔍 Binary data for field \(fieldName)")
        }
        
        // Process different field types
        switch fieldName {
        case "file":
            request.audioData = data
            let sizeMB = Double(data.count) / 1024.0 / 1024.0
            print("✅ Set audio data of size \(data.count) bytes (\(String(format: "%.2f", sizeMB)) MB)")
            
            // Check for presence of correct audio data
            if data.count < 1000 {
                print("⚠️ Warning: audio file suspiciously small (\(data.count) bytes), possibly data truncated")
            } else if data.count > 5 * 1024 * 1024 {
                print("ℹ️ Information: processing large audio file (\(String(format: "%.2f", sizeMB)) MB)")
            }
            
        case "prompt":
            if let textValue = String(data: data, encoding: .utf8) {
                let prompt = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.prompt = prompt
                print("✅ Set prompt: \(prompt)")
            } else {
                print("❌ Failed to decode prompt content as text")
            }
            
        case "response_format":
            if let textValue = String(data: data, encoding: .utf8) {
                let format = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.responseFormat = ResponseFormat.from(string: format)
                print("✅ Set response format: \(format)")
            } else {
                print("❌ Failed to decode response format as text")
            }
            
        case "temperature":
            if let textValue = String(data: data, encoding: .utf8),
               let temp = Double(textValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                request.temperature = temp
                print("✅ Set temperature: \(temp)")
            } else {
                print("❌ Failed to decode temperature as number")
            }
            
        case "language":
            if let textValue = String(data: data, encoding: .utf8) {
                let language = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.language = language
                print("✅ Set language: \(language)")
            } else {
                print("❌ Failed to decode language as text")
            }
            
        case "model":
            if let textValue = String(data: data, encoding: .utf8) {
                let model = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                print("✅ Received model: \(model) (ignored)")
                // Simply log, don't use, since we're using built-in model
            } else {
                print("❌ Failed to decode model as text")
            }
            
        default:
            if let textValue = String(data: data, encoding: .utf8) {
                print("📝 Unprocessed field: \(fieldName) = \(textValue.prefix(50))")
            } else {
                print("📝 Unprocessed binary field: \(fieldName) of size \(data.count) bytes")
            }
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
        // Get response body and content type
        let (contentType, responseBody) = self.createResponseBody(format: format, text: text, temperature: temperature)
        
        // Log response format information
        print("📤 Sending response in format \(format.rawValue) (\(contentType))")
        
        // Output response size
        let responseSizeKB = Double(responseBody.utf8.count) / 1024.0
        print("📤 Response size: \(responseBody.utf8.count) bytes (\(String(format: "%.2f", responseSizeKB)) KB)")
        
        // Output transcription text preview
        let previewLength = min(50, text.count)
        let textPreview = text.prefix(previewLength)
        print("📝 Transcription text preview: \"\(textPreview)\(text.count > previewLength ? "..." : "")\"")
        
        // Send HTTP response
        self.sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: contentType,
            body: responseBody,
            onSuccess: { print("✅ Whisper API transcription response sent successfully") }
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
                return ("application/json", "{\"text\": \"Server creation JSON response error\"}")
            }
            
        case .verbose_json:
            // Split text into two segments for example
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            // Estimate audio duration (approximately)
            let estimatedDuration = Double(text.count) / 20.0 // approximate estimate
            
            let verboseResponse: [String: Any] = [
                "task": "transcribe",
                "language": "auto", // determined automatically
                "duration": estimatedDuration,
                "text": text,
                "segments": [
                    [
                        "id": 0,
                        "seek": 0,
                        "start": 0.0,
                        "end": estimatedDuration / 2.0,
                        "text": firstSegment,
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": temperature,
                        "avg_logprob": -0.45,
                        "compression_ratio": 1.275,
                        "no_speech_prob": 0.1
                    ],
                    [
                        "id": 1,
                        "seek": 500,
                        "start": estimatedDuration / 2.0,
                        "end": estimatedDuration,
                        "text": secondSegment,
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": temperature,
                        "avg_logprob": -0.45,
                        "compression_ratio": 1.275,
                        "no_speech_prob": 0.1
                    ]
                ]
            ]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: verboseResponse),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ("application/json", jsonString)
            } else {
                return ("application/json", "{\"text\": \"Server creation detailed JSON response error\"}")
            }
            
        case .text:
            return ("text/plain", text)
            
        case .srt:
            // Split text into segments for creating subtitles
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let estimatedDuration = Double(text.count) / 20.0 // approximate estimate
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
            
            let estimatedDuration = Double(text.count) / 20.0 // approximate estimate
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
        
        var responseBody = "{\"error\": {\"message\": \"Server internal error\"}}"
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
        let contentLength = body.utf8.count
        let response = """
        HTTP/1.1 \(statusCode) \(statusMessage)
        Content-Type: \(contentType)
        Content-Length: \(contentLength)
        Connection: close
        
        \(body)
        """
        
        let responseData = Data(response.utf8)
        
        // Add connection state check before sending data
        if case .cancelled = connection.state {
            print("⚠️ Attempt to send data through closed connection")
            return
        }
        
        if case .failed(_) = connection.state {
            print("⚠️ Attempt to send data through failed connection")
            return
        }
        
        // Define timeout based on response size. Give more time for larger responses.
        let timeoutSeconds: TimeInterval = min(5.0, Double(contentLength) / 10000 + 1.0)
        print("🕒 Set timeout for response sending: \(String(format: "%.1f", timeoutSeconds)) seconds")
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Response sending error: \(error.localizedDescription)")
            } else {
                onSuccess()
                print("✅ Response successfully processed, size: \(contentLength) bytes")
            }
            
            // Delay before closing connection for data sending
            // Use longer delay for larger responses
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                // Check connection state
                if case .cancelled = connection.state {
                    // Connection already closed
                    return
                }
                
                print("🔄 Closing connection after sending data")
                connection.cancel()
            }
        })
    }
} 