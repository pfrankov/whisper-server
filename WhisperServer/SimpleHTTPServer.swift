//
//  SimpleHTTPServer.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import Foundation
import Network

/// A simple HTTP server that responds with "OK" to any request
final class SimpleHTTPServer {
    // MARK: - Properties
    
    /// The port on which the server listens
    private let port: UInt16
    
    /// Flag indicating whether the server is currently running
    private(set) var isRunning = false
    
    /// The network listener that accepts incoming connections
    private var listener: NWListener?
    
    /// Queue for handling server operations
    private let serverQueue: DispatchQueue
    
    // MARK: - Initialization
    
    /// Creates a new HTTP server instance
    /// - Parameter port: The port on which to listen for connections
    init(port: UInt16) {
        self.port = port
        self.serverQueue = DispatchQueue(label: "com.whisperserver.server", qos: .userInitiated)
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
            
            // Create port from UInt16
            let port = NWEndpoint.Port(rawValue: self.port)!
            
            // Initialize listener with parameters and port
            listener = try NWListener(using: parameters, on: port)
            
            // Set up state handler
            configureStateHandler()
            
            // Set up connection handler
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
        print("🛑 HTTP Server stopped")
    }
    
    // MARK: - Private Methods
    
    /// Configures the state update handler for the listener
    private func configureStateHandler() {
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.isRunning = true
                print("✅ HTTP Server started on http://localhost:\(self.port)")
                print("   Test with: curl http://localhost:\(self.port)")
                
            case .failed(let error):
                print("❌ HTTP Server failed: \(error.localizedDescription)")
                self.stop()
                
            case .cancelled:
                self.isRunning = false
                
            default:
                break
            }
        }
    }
    
    /// Configures the handler for new connections
    private func configureConnectionHandler() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.handleConnection(connection)
        }
    }
    
    /// Handles a new connection
    /// - Parameter connection: The connection to handle
    private func handleConnection(_ connection: NWConnection) {
        // Connect a state handler to the connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.receiveData(from: connection)
                
            case .failed(let error):
                print("❌ Connection failed: \(error.localizedDescription)")
                connection.cancel()
                
            default:
                break
            }
        }
        
        // Start the connection
        connection.start(queue: serverQueue)
    }
    
    /// Receives data from the connection
    /// - Parameter connection: The connection from which to receive data
    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            // If there was an error, log it and cancel the connection
            if let error = error {
                print("❌ Error receiving data: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            // If we received data, send a response
            if data != nil {
                // Log the request if needed (in debug builds)
                #if DEBUG
                if let data = data, let requestString = String(data: data, encoding: .utf8) {
                    print("📥 Received request: \(requestString.prefix(200))...")
                }
                #endif
                
                // Send the "OK" response
                self.sendResponse(to: connection)
            }
            
            // If the connection is complete, cancel it
            if isComplete {
                connection.cancel()
            }
        }
    }
    
    /// Sends an HTTP response to the connection
    /// - Parameter connection: The connection to which to send the response
    private func sendResponse(to connection: NWConnection) {
        // Create a simple HTTP response with "OK" as the body
        let response = """
        HTTP/1.1 200 OK
        Content-Type: text/plain
        Content-Length: 2
        Connection: close
        
        OK
        """
        
        // Convert the response to Data and send it
        let responseData = Data(response.utf8)
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Error sending response: \(error.localizedDescription)")
            } else {
                #if DEBUG
                print("✅ Response sent successfully")
                #endif
            }
            
            // Close the connection after sending the response
            connection.cancel()
        })
    }
} 