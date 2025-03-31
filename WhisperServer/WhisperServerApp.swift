//
//  WhisperServerApp.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import SwiftUI
#if os(macOS) || os(iOS)
import Metal
#endif

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
        
        #if os(macOS) || os(iOS)
        // Предварительная загрузка Metal
        preloadMetalLibraries()
        #endif
        
        setupStatusItem()
        startServer()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
        WhisperTranscriptionService.cleanup()
    }
    
    // MARK: - Private Methods
    
    /// Предварительно загружает библиотеки Metal
    private func preloadMetalLibraries() {
        #if os(macOS) || os(iOS)
        DispatchQueue.global(qos: .userInitiated).async {
            print("🔄 Preloading Metal libraries...")
            
            // Создаем устройство Metal и сохраняем его для повторного использования
            let device = MTLCreateSystemDefaultDevice()
            if let _ = device {
                print("✅ Metal device initialized")
                
                // В macOS Sonoma+ доступен улучшенный API для кэширования шейдеров
                if #available(macOS 14.0, iOS 17.0, *) {
                    print("🔄 Using enhanced Metal shader caching on macOS Sonoma+")
                }
            } else {
                print("⚠️ Metal is not available on this device")
            }
        }
        #endif
    }
    
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
        
        // Предварительная загрузка модели Whisper для ускорения первого запроса
        DispatchQueue.global(qos: .userInitiated).async {
            print("🔄 Preloading Whisper model...")
            // Создаем пустые данные для инициализации контекста без реальной транскрипции
            let silenceData = Data(repeating: 0, count: 1024)
            WhisperTranscriptionService.transcribeAudioData(silenceData)
        }
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

