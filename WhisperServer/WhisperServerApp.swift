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
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties
    
    /// Menu bar item
    private var statusItem: NSStatusItem!
    
    /// HTTP server instance
    private var httpServer: SimpleHTTPServer?
    
    /// The port the server listens on
    private let serverPort: UInt16 = 8888
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app appear only in menu bar (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        setupStatusItem()
        startServer()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
    }
    
    // MARK: - Private Methods
    
    /// Sets up the status item in the menu bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Server")
            button.toolTip = "WhisperServer running on port \(serverPort)"
        }
        
        let menu = NSMenu()
        menu.addItem(withTitle: "Server running on port \(serverPort)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        
        statusItem.menu = menu
    }
    
    /// Starts the HTTP server
    private func startServer() {
        httpServer = SimpleHTTPServer(port: serverPort)
        httpServer?.start()
    }
    
    /// Stops the HTTP server
    private func stopServer() {
        httpServer?.stop()
        httpServer = nil
    }
    
    // MARK: - Actions
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
}

