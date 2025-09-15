//
//  MenuBarService.swift
//  WhisperServer
//
//  Manages menu bar UI and user interactions
//

import AppKit
import SwiftUI

/// Service responsible for managing the menu bar interface
final class MenuBarService: ObservableObject {
    // MARK: - Types
    
    private enum MenuItemTags: Int {
        case status = 1000
        case server = 1001
    }
    
    // MARK: - Properties
    
    private var statusItem: NSStatusItem?
    private let modelManager: ModelManager
    private weak var serverCoordinator: ServerCoordinator?
    
    // MARK: - Initialization
    
    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }
    
    // MARK: - Public Interface
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        configureStatusButton()
        createMenu()
        setupNotificationObservers()
    }
    
    func setServerCoordinator(_ coordinator: ServerCoordinator) {
        serverCoordinator = coordinator
    }
    
    func updateServerStatus(_ isRunning: Bool, port: Int) {
        guard let menu = statusItem?.menu,
              let serverItem = menu.item(withTag: MenuItemTags.server.rawValue) else { return }
        
        DispatchQueue.main.async {
            if isRunning {
                serverItem.title = "Server: Running on port \(port)"
                serverItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            } else {
                serverItem.title = "Server: Stopped"
                serverItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            }
        }
    }
    
    func updateMetalStatus(isActive: Bool, modelName: String? = nil, isCaching: Bool = false, failed: Bool = false) {
        guard let menu = statusItem?.menu,
              let statusMenuItem = menu.item(withTag: MenuItemTags.status.rawValue) else { return }
        
        DispatchQueue.main.async { [weak self] in
            if isCaching {
                statusMenuItem.title = "Metal: Caching shaders..."
                statusMenuItem.image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: nil)
                self?.updateStatusIcon("rays")
            } else if failed {
                statusMenuItem.title = "Metal: Using CPU fallback"
                statusMenuItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                self?.updateStatusIcon("waveform")
            } else if isActive, let modelName = modelName {
                statusMenuItem.title = "Metal: Active with \(modelName) model (GPU acceleration)"
                statusMenuItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                self?.updateStatusIcon("waveform")
                self?.updateTooltip("WhisperServer - Active with \(modelName) model")
            } else {
                statusMenuItem.title = "Inactive (will initialize on first request)"
                statusMenuItem.image = NSImage(systemSymbolName: "sleep", accessibilityDescription: "Sleep")
                self?.updateStatusIcon("sleep")
            }
        }
    }
    
    func showModelStatus(_ status: String) {
        guard let menu = statusItem?.menu else { return }
        
        DispatchQueue.main.async {
            let shouldShow = status.lowercased().contains("download") || 
                            status.lowercased().contains("error") || 
                            status.lowercased().contains("preparing")
            
            let statusIndex = menu.items.firstIndex { $0.title.hasPrefix("Model:") } ?? -1
            
            if shouldShow {
                if statusIndex >= 0 {
                    menu.items[statusIndex].title = "Model: \(status)"
                } else {
                    let insertIndex = menu.items.firstIndex { $0.isSeparatorItem } ?? 0
                    let statusItem = NSMenuItem(title: "Model: \(status)", action: nil, keyEquivalent: "")
                    menu.insertItem(statusItem, at: insertIndex)
                }
            } else if statusIndex >= 0 {
                menu.removeItem(at: statusIndex)
            }
        }
    }
    
    func showDownloadProgress(_ progress: Double) {
        guard let menu = statusItem?.menu else { return }
        
        DispatchQueue.main.async {
            let progressIndex = menu.items.firstIndex { $0.title.hasPrefix("Download:") } ?? -1
            let progressPercent = Int(progress * 100)
            
            if progressIndex >= 0 {
                menu.items[progressIndex].title = "Download: \(progressPercent)%"
            } else if progress > 0 {
                let insertIndex = menu.items.firstIndex { $0.isSeparatorItem } ?? 0
                let progressItem = NSMenuItem(title: "Download: \(progressPercent)%", action: nil, keyEquivalent: "")
                menu.insertItem(progressItem, at: insertIndex)
            }
            
            if progress >= 1.0, progressIndex >= 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if menu.items.indices.contains(progressIndex) {
                        menu.removeItem(at: progressIndex)
                    }
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }
        
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Whisper Server")
        button.toolTip = "WhisperServer - Initializing..."
    }
    
    private func createMenu() {
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
        
        // Model selection submenu
        menu.addItem(NSMenuItem.separator())
        createModelSelectionMenu(menu)
        
        // Quit option
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    private func createModelSelectionMenu(_ parentMenu: NSMenu) {
        let modelSelectionMenuItem = NSMenuItem(title: "Select Model", action: nil, keyEquivalent: "")
        let modelSelectionSubmenu = NSMenu()
        
        // FluidAudio provider entry
        let fluidItem = NSMenuItem(title: "FluidAudio (Core ML)", action: #selector(selectFluidProvider), keyEquivalent: "")
        fluidItem.target = self
        fluidItem.state = (modelManager.selectedProvider == .fluid) ? .on : .off
        modelSelectionSubmenu.addItem(fluidItem)
        modelSelectionSubmenu.addItem(NSMenuItem.separator())
        
        // Whisper models
        if modelManager.availableModels.isEmpty {
            let noModelsItem = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
            noModelsItem.isEnabled = false
            modelSelectionSubmenu.addItem(noModelsItem)
        } else {
            for model in modelManager.availableModels {
                let modelItem = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
                modelItem.target = self
                modelItem.representedObject = model.id
                
                if modelManager.selectedProvider == .whisper && model.id == modelManager.selectedModelID {
                    modelItem.state = .on
                }
                
                modelSelectionSubmenu.addItem(modelItem)
            }
        }
        
        modelSelectionMenuItem.submenu = modelSelectionSubmenu
        parentMenu.addItem(modelSelectionMenuItem)
    }
    
    private func updateStatusIcon(_ iconName: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "WhisperServer")
    }
    
    private func updateTooltip(_ tooltip: String) {
        statusItem?.button?.toolTip = tooltip
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(refreshModelSelectionMenu), 
            name: .modelManagerDidUpdate, 
            object: nil
        )
    }
    
    // MARK: - Menu Actions
    
    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        
        if modelId != modelManager.selectedModelID || modelManager.selectedProvider != .whisper {
            let modelName = modelManager.availableModels.first(where: { $0.id == modelId })?.name ?? "Unknown"
            print("🔄 Changing model to: \(modelName) (id: \(modelId))")
            
            serverCoordinator?.stopServer()
            modelManager.selectModel(id: modelId)
            refreshModelSelectionMenu()
            serverCoordinator?.restartServer()
        }
    }
    
    @objc private func selectFluidProvider() {
        guard modelManager.selectedProvider != .fluid else { return }
        
        print("🔄 Switching engine to FluidAudio")
        serverCoordinator?.stopServer()
        modelManager.selectProvider(.fluid)
        refreshModelSelectionMenu()
        serverCoordinator?.restartServer()
    }
    
    @objc private func refreshModelSelectionMenu() {
        guard let menu = statusItem?.menu else { return }
        
        for i in 0..<menu.items.count {
            let item = menu.items[i]
            if item.title == "Select Model", let submenu = item.submenu {
                submenu.removeAllItems()
                
                // FluidAudio entry
                let fluidItem = NSMenuItem(title: "FluidAudio (Core ML)", action: #selector(selectFluidProvider), keyEquivalent: "")
                fluidItem.target = self
                fluidItem.state = (modelManager.selectedProvider == .fluid) ? .on : .off
                submenu.addItem(fluidItem)
                submenu.addItem(NSMenuItem.separator())
                
                // Whisper models
                if modelManager.availableModels.isEmpty {
                    let noModelsItem = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
                    noModelsItem.isEnabled = false
                    submenu.addItem(noModelsItem)
                } else {
                    for model in modelManager.availableModels {
                        let modelItem = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
                        modelItem.target = self
                        modelItem.representedObject = model.id
                        
                        if modelManager.selectedProvider == .whisper && model.id == modelManager.selectedModelID {
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
