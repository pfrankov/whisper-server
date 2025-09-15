//
//  ServerCoordinator.swift
//  WhisperServer
//
//  Coordinates server lifecycle and model state
//

import Foundation

/// Coordinates server operations and model state management
final class ServerCoordinator: ObservableObject {
    // MARK: - Properties
    
    private var vaporServer: VaporServer?
    private let modelManager: ModelManager
    private let port: Int
    private weak var menuBarService: MenuBarService?
    
    var isRunning: Bool {
        vaporServer?.isRunning ?? false
    }
    
    // MARK: - Initialization
    
    init(modelManager: ModelManager, port: Int = 12017) {
        self.modelManager = modelManager
        self.port = port
    }
    
    // MARK: - Public Interface
    
    func setMenuBarService(_ service: MenuBarService) {
        menuBarService = service
    }
    
    func startServer() {
        if vaporServer == nil {
            vaporServer = VaporServer(port: port, modelManager: modelManager)
        }
        
        guard let server = vaporServer, !server.isRunning else {
            print("✅ Server is already running or starting")
            updateServerStatus()
            return
        }
        
        server.start()
        updateServerStatus()
        
        // Recheck status after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.updateServerStatus()
        }
    }
    
    func stopServer() {
        vaporServer?.stop()
        vaporServer = nil
        updateServerStatus()
    }
    
    func restartServer() {
        stopServer()
        
        // Release Whisper context for model changes
        WhisperTranscriptionService.reinitializeContext()
        
        // Small delay to ensure cleanup completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.startServer()
        }
    }
    
    func handleApplicationTermination() {
        stopServer()
        WhisperTranscriptionService.cleanup()
    }
    
    // MARK: - Private Methods
    
    private func updateServerStatus() {
        menuBarService?.updateServerStatus(isRunning, port: port)
    }
}
