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
import Vapor

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
    /// Enum for tagging menu items for easy reference
    enum MenuItemTags: Int {
        case status = 1000
        case server = 1001
        // Add more tags as needed
    }
    
    // MARK: - Properties
    
    /// Menu bar item
    private var statusItem: NSStatusItem!
    
    /// Vapor server instance
    private var vaporServer: VaporServer?
    
    /// The port the server listens on
    private let serverPort: Int = 12017
    
    /// Model manager instance
    let modelManager = ModelManager()
    
    /// Flag to track if shaders are being preloaded
    private var isPreloadingShaders: Bool = false
    
    /// Status text for preloading
    private var preloadStatusText: String = ""
    
    /// Whether to automatically start server after initialization
    private var autoStartServer: Bool = true
    
    /// A flag indicating whether the server is currently starting up
    private var isStartingServer: Bool = false
    
    // MARK: - Application Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Make app appear only in menu bar (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Setup status bar
        setupStatusItem()
        
        // Setup notification observers
        setupNotificationObservers()
        
        // Start the server
        startServer()
        
        // Begin model preparation in the background
        updateUIForModelPreparation()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        stopServer()
        WhisperTranscriptionService.cleanup()
    }
    
    // MARK: - Private Methods
    
    /// Preloads Metal shaders and starts the server upon completion
    func preloadMetalShaders() {
        // Prevent parallel execution
        if isPreloadingShaders {
            print("⚠️ Metal shader preloading already in progress, skipping duplicate request")
            return
        }
        
        let startTime = Date()
        isPreloadingShaders = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            print("🔄 Starting Metal shader preloading...")
            
            // Запуск прекомпиляции шейдеров
            var success = false
            
            // modelManager is a non-optional property, so we don't need to check if it's nil
            if let modelPaths = self.modelManager.getPathsForSelectedModel() {
                let binPath = modelPaths.binPath
                let encoderDir = modelPaths.encoderDir
                
                // Pass the model paths directly to the preload method
                success = WhisperTranscriptionService.preloadModelForShaderCaching(
                    modelBinPath: binPath,
                    modelEncoderDir: encoderDir
                )
            } else {
                print("❌ Could not get model paths from ModelManager")
            }
            
            // UI обновления всегда на главном потоке
            DispatchQueue.main.async {
                self.isPreloadingShaders = false
                
                // Замеряем время выполнения
                let elapsedTime = Date().timeIntervalSince(startTime)
                let formattedTime = String(format: "%.2f", elapsedTime)
                
                if success {
                    self.preloadStatusText = "Shader compilation finished successfully in \(formattedTime) sec."
                    print("✅ Metal shader preloading completed in \(formattedTime) seconds")
                    
                    // Обновляем статус Metal в интерфейсе на "Ready"
                    self.updateStatusMenuItem(metalCaching: false, failed: false)
                } else {
                    self.preloadStatusText = "Shader compilation error"
                    print("❌ Metal shader preloading failed after \(formattedTime) seconds")
                    
                    // Обновляем статус Metal в интерфейсе как "Failed"
                    self.updateStatusMenuItem(metalCaching: false, failed: true)
                }
            }
        }
    }
    
    /// Setup notification observers for model manager events
    private func setupNotificationObservers() {
        // Model is ready notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelReady),
            name: NSNotification.Name("ModelIsReady"),
            object: nil
        )
        
        // Model preparation failed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelPreparationFailed),
            name: NSNotification.Name("ModelPreparationFailed"),
            object: nil
        )
        
        // Model manager status changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelStatusChanged),
            name: NSNotification.Name("ModelManagerStatusChanged"),
            object: nil
        )
        
        // Model manager progress changed notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelProgressChanged),
            name: NSNotification.Name("ModelManagerProgressChanged"),
            object: nil
        )
        
        // Metal is activated on the first request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetalActivated),
            name: WhisperTranscriptionService.metalActivatedNotificationName,
            object: nil
        )
        
        // Tiny model was auto-selected
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleTinyModelAutoSelected),
            name: NSNotification.Name("TinyModelAutoSelected"), 
            object: nil
        )
    }
    
    /// Update UI to reflect model preparation
    private func updateUIForModelPreparation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Сбрасываем статус Metal на "неактивно" при смене модели
            let selectedModel = self.modelManager.selectedModelName ?? "Unknown"
            print("🔄 Resetting Metal status while preparing model: \(selectedModel)")
            
            if let item = self.statusItem, let button = item.button {
                button.image = NSImage(systemSymbolName: "sleep", accessibilityDescription: "Sleep")
                
                // Обновляем текст в меню
                if let statusMenuItem = self.statusItem.menu?.item(withTag: MenuItemTags.status.rawValue) {
                    statusMenuItem.title = "Inactive (will initialize on first request)"
                    statusMenuItem.image = NSImage(systemSymbolName: "sleep", accessibilityDescription: "Sleep")
                }
            }
        }
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleModelReady() {
        DispatchQueue.main.async { [weak self] in
            print("✅ Model is ready, but Whisper will only initialize on first request")
            
            // Double-check model is actually ready
            guard let self = self, self.modelManager.isModelReady else {
                print("⚠️ Model was reported ready but isModelReady is false")
                return
            }
            
            // Verify that we can get model paths
            if let paths = self.modelManager.getPathsForSelectedModel() {
                let modelName = self.modelManager.selectedModelName ?? "Unknown"
                print("✅ Verified model paths are available for model: \(modelName)")
                print("   - Bin file: \(paths.binPath.path)")
                print("   - Encoder dir: \(paths.encoderDir.path)")
                
                // Store the model paths in UserDefaults so they can be recovered if AppDelegate becomes inaccessible
                self.storeCurrentModelPaths(binPath: paths.binPath.path, encoderDir: paths.encoderDir.path)
                
                // Update the status menu to show that we're ready for first request
                if let menu = self.statusItem.menu, let metalItem = menu.item(withTag: MenuItemTags.status.rawValue) {
                    metalItem.title = "Metal: Inactive (will initialize on first request)"
                    metalItem.image = NSImage(systemSymbolName: "sleep", accessibilityDescription: nil)
                }
            } else {
                print("❌ Model reported ready but paths unavailable")
                self.handleModelPreparationFailed()
            }
        }
    }
    
    /// Store current model paths in UserDefaults for recovery if AppDelegate becomes inaccessible
    private func storeCurrentModelPaths(binPath: String, encoderDir: String) {
        UserDefaults.standard.set(binPath, forKey: "CurrentModelBinPath")
        UserDefaults.standard.set(encoderDir, forKey: "CurrentModelEncoderDir")
        print("✅ Stored current model paths in UserDefaults for recovery")
    }
    
    @objc private func handleModelPreparationFailed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("❌ Model preparation failed notification received")
            
            self.updateServerStatusMenuItem()
            
            // Update status menu to reflect failure
            if let menu = self.statusItem.menu, let metalItem = menu.item(withTag: MenuItemTags.status.rawValue) {
                metalItem.title = "Metal: Model unavailable"
                metalItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            }
            
            self.updateUIForModelPreparation()
            self.updateServerStatusMenuItem()
        }
    }
    
    @objc private func handleModelStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let menu = self.statusItem.menu else { return }
            
            // Update model status in menu only if it's a special status (downloading, etc.)
            let status = self.modelManager.currentStatus
            print("📝 Model status changed: \(status)")
            
            // Decide whether to show the status item based on the status content
            let shouldShowStatus = status.lowercased().contains("download") || 
                                 status.lowercased().contains("error") || 
                                 status.lowercased().contains("preparing")
            
            // Find existing status item
            let statusIndex = menu.items.firstIndex(where: { $0.title.hasPrefix("Model:") }) ?? -1
            
            if shouldShowStatus {
                if statusIndex >= 0 {
                    // Update existing item
                    menu.items[statusIndex].title = "Model: \(status)"
                } else {
                    // Status item doesn't exist, find where to insert it
                    let insertIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }) ?? 0
                    
                    // Create and insert new status item
                    let statusItem = NSMenuItem(title: "Model: \(status)", action: nil, keyEquivalent: "")
                    menu.insertItem(statusItem, at: insertIndex)
                }
            } else {
                // Remove status item if it exists and we don't need to show it
                if statusIndex >= 0 {
                    menu.removeItem(at: statusIndex)
                }
            }
        }
    }
    
    @objc private func handleModelProgressChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, 
                  let menu = self.statusItem.menu,
                  let progress = self.modelManager.downloadProgress else { return }
            
            // Find or create the progress item
            let progressIndex = menu.items.firstIndex(where: { $0.title.hasPrefix("Download:") }) ?? -1
            let progressPercent = Int(progress * 100)
            
            if progressIndex >= 0 {
                // Update existing progress item
                menu.items[progressIndex].title = "Download: \(progressPercent)%"
            } else if progress > 0 {
                // Progress item doesn't exist and we have progress to show
                let insertIndex = menu.items.firstIndex(where: { $0.isSeparatorItem }) ?? 0
                
                // Create and insert new progress item
                let progressItem = NSMenuItem(title: "Download: \(progressPercent)%", action: nil, keyEquivalent: "")
                menu.insertItem(progressItem, at: insertIndex)
            }
            
            // When download completes, remove the progress item
            if progress >= 1.0 {
                if progressIndex >= 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if menu.items.indices.contains(progressIndex) {
                            menu.removeItem(at: progressIndex)
                        }
                    }
                }
            }
            
            // Update server status
            self.updateServerStatusMenuItem()
        }
    }
    
    /// Handles the notification that the tiny model was auto-selected
    @objc private func handleTinyModelAutoSelected(notification: Notification) {
        DispatchQueue.main.async {
            self.updateServerStatusMenuItem()
        }
    }
    
    /// Handles the notification that Metal has been activated
    @objc private func handleMetalActivated(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Get model name from notification
            let modelName = notification.userInfo?["modelName"] as? String ?? "Unknown"
            print("🔥 Metal activated with model: \(modelName)")
            
            // Update the Metal status in the menu to "active" and update model info
            self.updateMetalStatusWithModel(modelName: modelName)
        }
    }
    
    /// Updates the Metal status with the name of the active model
    private func updateMetalStatusWithModel(modelName: String) {
        if let menu = statusItem.menu, let metalItem = menu.item(withTag: MenuItemTags.status.rawValue) {
            metalItem.title = "Metal: Active with \(modelName) model (GPU acceleration)"
            metalItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            
            // Update the icon in the status bar
            if let button = statusItem.button {
                button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "WhisperServer")
                button.toolTip = "WhisperServer - Active with \(modelName) model"
            }
        }
        
        // Update server status
        self.updateServerStatusMenuItem()
    }
    
    /// Updates the status display in the menu
    private func updateStatusMenuItem(metalCaching: Bool, failed: Bool = false) {
        // Update the icon in the status bar
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: metalCaching ? "rays" : "waveform", 
                                  accessibilityDescription: "WhisperServer")
        }
        
        // Update the status in the menu
        if let menu = statusItem.menu, let metalItem = menu.item(withTag: MenuItemTags.status.rawValue) {
            if metalCaching {
                metalItem.title = "Metal: Caching shaders..."
                metalItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", 
                                        accessibilityDescription: nil)
            } else if failed {
                metalItem.title = "Metal: Using CPU fallback"
                metalItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", 
                                        accessibilityDescription: nil)
            } else {
                // For the normal "Active" status, use updateMetalStatusWithModel
                // This case is left for backward compatibility
                _ = modelManager.selectedModelName ?? "Unknown"
                metalItem.title = "Metal: Active (GPU acceleration)"
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
        
        // Metal status
        let metalItem = NSMenuItem(title: "Metal: Initializing...", action: nil, keyEquivalent: "")
        metalItem.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        metalItem.toolTip = "GPU acceleration status - Loading shaders for faster transcription"
        metalItem.tag = MenuItemTags.status.rawValue
        menu.addItem(metalItem)
        
        // Server status
        let serverItem = NSMenuItem(title: "Server: Waiting for initialization...", action: nil, keyEquivalent: "")
        serverItem.toolTip = "HTTP server will start after initialization is complete"
        serverItem.tag = MenuItemTags.server.rawValue
        menu.addItem(serverItem)
        
        // Add model selection submenu
        menu.addItem(NSMenuItem.separator())
        
        let modelSelectionMenuItem = NSMenuItem(title: "Select Model", action: nil, keyEquivalent: "")
        let modelSelectionSubmenu = NSMenu()
        
        // Populate model selection submenu with available models
        if modelManager.availableModels.isEmpty {
            let noModelsItem = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
            noModelsItem.isEnabled = false
            modelSelectionSubmenu.addItem(noModelsItem)
        } else {
            for model in modelManager.availableModels {
                let modelItem = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
                modelItem.representedObject = model.id
                
                // Check if this model is currently selected
                if model.id == modelManager.selectedModelID {
                    modelItem.state = .on
                }
                
                modelSelectionSubmenu.addItem(modelItem)
            }
        }
        
        modelSelectionMenuItem.submenu = modelSelectionSubmenu
        menu.addItem(modelSelectionMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        
        statusItem.menu = menu
        
        // Subscribe to model manager updates to refresh the menu when needed
        NotificationCenter.default.addObserver(self, selector: #selector(refreshModelSelectionMenu), name: NSNotification.Name("ModelManagerDidUpdate"), object: nil)
        
        // Update UI
        self.updateUIForModelPreparation()
        self.updateServerStatusMenuItem()
    }
    
    /// Starts the HTTP server
    @objc private func toggleServer() {
        if let server = vaporServer, server.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }
    
    /// Starts the HTTP server
    private func startServer() {
        if vaporServer == nil {
            vaporServer = VaporServer(port: serverPort, modelManager: self.modelManager)
        }
        
        // If server isn't running, start it
        if let server = vaporServer, !server.isRunning {
            server.start()
            // The Vapor server starts asynchronously. We need to wait a bit before updating the UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.updateServerStatusMenuItem()
            }
        } else {
            print("✅ Server is already running or starting")
            updateServerStatusMenuItem()
        }
    }
    
    /// Stops the HTTP server
    private func stopServer() {
        vaporServer?.stop()
        vaporServer = nil // Release the instance
        updateServerStatusMenuItem()
    }
    
    /// Updates server status menu item text and state
    private func updateServerStatusMenuItem() {
        DispatchQueue.main.async {
            if let menu = self.statusItem.menu, let serverItem = menu.item(withTag: MenuItemTags.server.rawValue) {
                if let server = self.vaporServer, server.isRunning {
                    serverItem.title = "Server: Running on port \(self.serverPort)"
                    serverItem.state = .on
                } else {
                    serverItem.title = "Server: Stopped"
                    serverItem.state = .off
                }
            }
        }
    }
    
    // MARK: - Actions
    
    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        
        // Проверяем, изменился ли выбор модели
        if modelId != modelManager.selectedModelID {
            // Получаем имя модели для логирования
            let modelName = modelManager.availableModels.first(where: { $0.id == modelId })?.name ?? "Unknown"
            print("🔄 Changing model to: \(modelName) (id: \(modelId))")
            
            // Останавливаем сервер перед сменой модели
            stopServer()
            
            // Меняем модель
            modelManager.selectModel(id: modelId)
            
            // Перерисовываем меню
            refreshModelSelectionMenu()
            
            // Освобождаем контекст Whisper, чтобы он был переинициализирован
            WhisperTranscriptionService.reinitializeContext()
            
            // Обновляем UI, чтобы показать, что мы ожидаем подготовки новой модели
            updateUIForModelPreparation()
            
            // Сразу запускаем сервер после смены модели
            startServer()
        }
    }
    
    @objc private func refreshModelSelectionMenu() {
        guard let menu = statusItem.menu else { return }
        
        // Find the Select Model menu item and update its submenu
        for i in 0..<menu.items.count {
            let item = menu.items[i]
            if item.title == "Select Model", let submenu = item.submenu {
                submenu.removeAllItems()
                
                if modelManager.availableModels.isEmpty {
                    let noModelsItem = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
                    noModelsItem.isEnabled = false
                    submenu.addItem(noModelsItem)
                } else {
                    for model in modelManager.availableModels {
                        let modelItem = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
                        modelItem.representedObject = model.id
                        
                        // Check if this model is currently selected
                        if model.id == modelManager.selectedModelID {
                            modelItem.state = .on
                        }
                        
                        submenu.addItem(modelItem)
                    }
                }
                
                break
            }
        }
    }
    
    @objc private func quitApp() {
        NSApp.terminate(self)
    }
}

