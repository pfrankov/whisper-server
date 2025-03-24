//
//  WhisperServerApp.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import SwiftUI

@main
struct WhisperServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Application delegate that manages the HTTP server and menu bar integration
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // MARK: - Properties
    
    /// Menu bar item
    private var statusItem: NSStatusItem!
    
    /// HTTP server instance
    private var httpServer: SimpleHTTPServer?
    
    /// Current server status displayed in the menu
    @objc private var serverStatus: String = "Starting..." {
        didSet {
            updateMenu()
        }
    }
    
    // MARK: - Constants
    
    /// The port the server listens on
    private let serverPort: UInt16 = 8888
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        configureApplication()
        setupStatusItem()
        setupMenu()
        startServerWithDelay()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }
    
    // MARK: - Private Methods
    
    /// Configures the application's appearance and behavior
    private func configureApplication() {
        // Make app appear only in menu bar (no dock icon)
        NSApp.setActivationPolicy(.accessory)
    }
    
    /// Sets up the status item in the menu bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Server")
            button.toolTip = "WhisperServer: Whisper API Server on port \(serverPort)"
        }
    }
    
    /// Creates and configures the menu
    private func setupMenu() {
        let menu = NSMenu()
        
        // Server status item
        let statusItem = NSMenuItem(title: "Server: \(serverStatus)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // API endpoints info
        let apiInfoItem = NSMenuItem(title: "API Endpoint", action: nil, keyEquivalent: "")
        apiInfoItem.isEnabled = false
        menu.addItem(apiInfoItem)
        
        // Transcription endpoint
        let transcriptionEndpoint = NSMenuItem(title: "   /v1/audio/transcriptions", action: #selector(copyTranscriptionURL), keyEquivalent: "")
        menu.addItem(transcriptionEndpoint)
        
        menu.addItem(NSMenuItem.separator())
        
        // Sample command
        let sampleCommandItem = NSMenuItem(title: "Copy sample curl command", action: #selector(copySampleCommand), keyEquivalent: "")
        menu.addItem(sampleCommandItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Documentation
        let docsItem = NSMenuItem(title: "Documentation", action: #selector(openDocs), keyEquivalent: "")
        menu.addItem(docsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit menu item
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q"))
        
        self.statusItem.menu = menu
    }
    
    /// Updates the menu with the current server status
    private func updateMenu() {
        if let menu = statusItem.menu, let item = menu.item(at: 0) {
            item.title = "Server: \(serverStatus)"
        }
    }
    
    /// Starts the server with a short delay to ensure app initialization is complete
    private func startServerWithDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startServer()
        }
    }
    
    /// Starts the HTTP server
    private func startServer() {
        serverStatus = "Starting..."
        
        // Create and start the HTTP server
        httpServer = SimpleHTTPServer(port: serverPort)
        httpServer?.start()
        
        // Update status after a delay to allow server to initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.serverStatus = "Running on port \(self.serverPort) (Whisper API)"
        }
    }
    
    /// Stops the HTTP server
    private func stopServer() {
        httpServer?.stop()
        httpServer = nil
    }
    
    // MARK: - Action Methods
    
    /// Copies the transcription endpoint URL to clipboard
    @objc private func copyTranscriptionURL() {
        let url = "http://localhost:\(serverPort)/v1/audio/transcriptions"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    
    /// Copies a sample curl command to clipboard
    @objc private func copySampleCommand() {
        let command = """
        curl -X POST http://localhost:\(serverPort)/v1/audio/transcriptions \\
          -F file=@/path/to/audio.mp3 \\
          -F model=whisper-1 \\
          -F response_format=json
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
    
    /// Opens documentation URL
    @objc private func openDocs() {
        if let url = URL(string: "https://platform.openai.com/docs/api-reference/audio") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Quits the application
    @objc private func quitClicked() {
        NSApp.terminate(self)
    }
}

