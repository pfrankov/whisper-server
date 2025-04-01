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
        
        // Создаем статус бар
        setupStatusItem()
        
        #if os(macOS) || os(iOS)
        // Предварительная загрузка Metal перед запуском сервера
        preloadMetalShaders()
        #else
        startServer()
        #endif
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
        WhisperTranscriptionService.cleanup()
    }
    
    // MARK: - Private Methods
    
    /// Предварительно загружает шейдеры Metal и запускает сервер после завершения
    private func preloadMetalShaders() {
        #if os(macOS) || os(iOS)
        // Обновляем статус в меню
        updateStatusMenuItem(metalCaching: true)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            print("🔄 Preloading Metal shaders...")
            
            // Проверка доступности Metal
            let device = MTLCreateSystemDefaultDevice()
            if device == nil {
                print("⚠️ Metal is not available on this device, using CPU fallback")
                DispatchQueue.main.async {
                    self?.updateStatusMenuItem(metalCaching: false, failed: true)
                    self?.startServer()
                }
                return
            }
            
            print("✅ Metal device initialized")
            
            // Кэшируем шейдеры через инициализацию модели
            print("🔄 Preloading Whisper model to cache Metal shaders...")
            let success = WhisperTranscriptionService.preloadModelForShaderCaching()
            
            DispatchQueue.main.async {
                if success {
                    print("✅ Metal shaders cached successfully")
                    self?.updateStatusMenuItem(metalCaching: false, failed: false)
                } else {
                    print("⚠️ Metal shader caching failed, using CPU fallback")
                    self?.updateStatusMenuItem(metalCaching: false, failed: true)
                }
                // В любом случае запускаем сервер
                self?.startServer()
            }
        }
        #endif
    }
    
    /// Обновляет отображение статуса в меню
    private func updateStatusMenuItem(metalCaching: Bool, failed: Bool = false) {
        // Обновляем иконку в статус-баре
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: metalCaching ? "rays" : "waveform", 
                                  accessibilityDescription: "WhisperServer")
        }
        
        // Обновляем статус в меню
        if let menu = statusItem.menu, menu.items.count > 0 {
            let metalItem = menu.items[0]
            
            if metalCaching {
                metalItem.title = "Metal: Caching shaders..."
                metalItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", 
                                        accessibilityDescription: nil)
            } else if failed {
                metalItem.title = "Metal: Using CPU fallback"
                metalItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", 
                                        accessibilityDescription: nil)
            } else {
                metalItem.title = "Metal: Ready (GPU acceleration)"
                metalItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", 
                                        accessibilityDescription: nil)
            }
        }
    }
    
    /// Sets up the status item in the menu bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Server")
            button.toolTip = "WhisperServer - Initializing..."
        }
        
        let menu = NSMenu()
        
        // Статус Metal
        let metalItem = NSMenuItem(title: "Metal: Initializing...", action: nil, keyEquivalent: "")
        metalItem.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        metalItem.toolTip = "GPU acceleration status - Loading shaders for faster transcription"
        menu.addItem(metalItem)
        
        // Статус сервера
        let serverItem = NSMenuItem(title: "Server: Waiting for initialization...", action: nil, keyEquivalent: "")
        serverItem.toolTip = "HTTP server will start after initialization is complete"
        menu.addItem(serverItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        
        statusItem.menu = menu
    }
    
    /// Starts the HTTP server
    private func startServer() {
        print("✅ Starting HTTP server on port \(serverPort)")
        httpServer = SimpleHTTPServer(port: serverPort)
        
        // Обновляем статус на "запускается" сразу
        if let menu = statusItem.menu, menu.items.count > 1 {
            let serverItem = menu.items[1]
            serverItem.title = "Server: Starting on port \(serverPort)..."
            serverItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        }
        
        // Запускаем сервер
        httpServer?.start()
        
        // Проверим статус после небольшой задержки
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, let httpServer = self.httpServer else { return }
            
            if let menu = self.statusItem.menu, menu.items.count > 1 {
                let serverItem = menu.items[1]
                
                if httpServer.isRunning {
                    serverItem.title = "Server: Running on port \(self.serverPort)"
                    serverItem.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
                    
                    // Обновляем tooltip в статус-баре
                    if let button = self.statusItem.button {
                        button.toolTip = "WhisperServer running on port \(self.serverPort)"
                    }
                } else {
                    serverItem.title = "Server: Failed to start"
                    serverItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                }
            }
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

