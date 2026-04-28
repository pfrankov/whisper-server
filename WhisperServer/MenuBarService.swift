//
//  MenuBarService.swift
//  WhisperServer
//
//  Manages menu bar UI and user interactions
//

import AppKit
import Combine
import SwiftUI

/// Service responsible for managing the menu bar interface
final class MenuBarService: ObservableObject {
    // MARK: - Types
    
    private enum MenuItemTags: Int {
        case status = 1000
        case server = 1001
        case download = 1002
        case launchAtLogin = 1003
        case exposeOnLAN = 1004
        case lanURL = 1005
        case lanCopy = 1006
        case requireAPIKey = 1007
        case apiKeyCopy = 1008
        case apiKeyRegenerate = 1009
        case preferences = 1010
    }

    /// Tags that describe the dynamic LAN sub-section under the Expose toggle (inside Preferences).
    private static let lanSectionTags: [MenuItemTags] = [
        .lanURL, .lanCopy, .requireAPIKey, .apiKeyCopy, .apiKeyRegenerate
    ]

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let modelManager: ModelManager
    private let settingsStore: SettingsStore
    private weak var serverCoordinator: ServerCoordinator?
    private let idleIconName = "waveform"
    private let processingIconName = "waveform.circle.fill"
    private var currentIconName: String?
    private var progressResetWorkItem: DispatchWorkItem?
    private var baseTooltip = "WhisperServer - Ready"
    private var isCurrentlyProcessing = false
    private let progressResetDelay: TimeInterval = 1.0
    private var currentServerPort: Int = 12017
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization
    
    init(modelManager: ModelManager, settingsStore: SettingsStore = .shared) {
        self.modelManager = modelManager
        self.settingsStore = settingsStore
    }
    
    // MARK: - Public Interface
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
#if DEBUG
        print("🔧 DEBUG build detected: Reset menu item enabled.")
#endif

        configureStatusButton()
        createMenu()
        setupNotificationObservers()
        observeSettings()
    }

    /// Keeps menu item state in sync with SettingsStore — covers async rollbacks
    /// (e.g. SMAppService.register failing after the toggle was optimistically flipped).
    private func observeSettings() {
        settingsStore.$launchAtLogin
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.syncLaunchAtLoginMenuItem(to: value)
            }
            .store(in: &cancellables)
    }

    private func syncLaunchAtLoginMenuItem(to value: Bool) {
        guard let topMenu = statusItem?.menu,
              let prefItem = topMenu.item(withTag: MenuItemTags.preferences.rawValue),
              let prefMenu = prefItem.submenu,
              let item = prefMenu.item(withTag: MenuItemTags.launchAtLogin.rawValue) else { return }
        item.state = value ? .on : .off
    }
    
    func setServerCoordinator(_ coordinator: ServerCoordinator) {
        serverCoordinator = coordinator
    }
    
    func updateServerStatus(_ isRunning: Bool, port: Int) {
        guard let menu = statusItem?.menu,
              let serverItem = menu.item(withTag: MenuItemTags.server.rawValue) else { return }

        DispatchQueue.main.async {
            self.currentServerPort = port
            if isRunning {
                serverItem.title = "Server: Running on port \(port)"
                serverItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            } else {
                serverItem.title = "Server: Stopped"
                serverItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            }
            self.refreshLANMenuVisibility()
        }
    }
    
    func updateMetalStatus(isActive: Bool, modelName: String? = nil, isCaching: Bool = false, failed: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let tooltip: String
            if isCaching {
                tooltip = "WhisperServer - Caching shaders..."
            } else if failed {
                tooltip = "WhisperServer - GPU unavailable (CPU fallback)"
            } else if isActive, let modelName = modelName {
                tooltip = "WhisperServer - Active with \(modelName) model"
            } else {
                tooltip = "WhisperServer - Ready"
            }

            self.baseTooltip = tooltip
            if !self.isCurrentlyProcessing {
                self.updateTooltip(tooltip)
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
            let clampedProgress = max(0.0, min(1.0, progress))
            let progressPercent = Int((clampedProgress * 100).rounded())
            let progressItem = self.ensureDownloadMenuItem(in: menu)
            progressItem.title = "Download: \(progressPercent)%"
            progressItem.isEnabled = false

            if clampedProgress >= 1.0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.hideDownloadProgress()
                }
            }
        }
    }

    func hideDownloadProgress() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let menu = self.statusItem?.menu else { return }
            let index = menu.indexOfItem(withTag: MenuItemTags.download.rawValue)
            if index >= 0 {
                menu.removeItem(at: index)
            }
        }
    }

    func updateTranscriptionProgress(progress: Double, isProcessing: Bool, modelName: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let menu = self.statusItem?.menu else { return }

            self.progressResetWorkItem?.cancel()
            self.progressResetWorkItem = nil

            let clampedProgress = max(0.0, min(1.0, progress))
            let percentValue = Int((clampedProgress * 100).rounded())
            let shouldDisplayProgressItem = isProcessing || clampedProgress > 0.0
            let resolvedModelName = self.resolveModelName(from: modelName)

            if shouldDisplayProgressItem {
                let progressMenuItem = self.ensureProgressMenuItem(in: menu)
                progressMenuItem.title = "\(resolvedModelName): \(percentValue)%"
            } else {
                self.removeProgressMenuItemIfNeeded(in: menu)
            }

            let processingNow = isProcessing || (clampedProgress > 0.0 && clampedProgress < 1.0)
            self.isCurrentlyProcessing = processingNow
            self.applyStatusIcon(isProcessing: processingNow)

            if processingNow {
                self.updateTooltip("WhisperServer - Processing \(resolvedModelName): \(percentValue)%")
            } else {
                self.updateTooltip(self.baseTooltip)
                if shouldDisplayProgressItem {
                    self.scheduleProgressResetIfNeeded(currentPercent: percentValue)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func configureStatusButton() {
        guard let button = statusItem?.button else { return }

        currentIconName = idleIconName
        button.image = NSImage(systemSymbolName: idleIconName, accessibilityDescription: "Whisper Server")
        baseTooltip = "WhisperServer - Initializing..."
        button.toolTip = baseTooltip
    }
    
    private func createMenu() {
        let menu = NSMenu()

        // Server status
        let serverItem = NSMenuItem(title: "Server: Waiting for initialization...", action: nil, keyEquivalent: "")
        serverItem.toolTip = "HTTP server will start after initialization is complete"
        serverItem.tag = MenuItemTags.server.rawValue
        menu.addItem(serverItem)

        // Model selection submenu
        menu.addItem(NSMenuItem.separator())
        createModelSelectionMenu(menu)

        // Preferences submenu
        menu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        preferencesItem.tag = MenuItemTags.preferences.rawValue
        preferencesItem.submenu = buildPreferencesSubmenu()
        menu.addItem(preferencesItem)

        // Quit option
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }
    
    private func buildPreferencesSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Preferences")

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.tag = MenuItemTags.launchAtLogin.rawValue
        launchItem.state = settingsStore.launchAtLogin ? .on : .off
        launchItem.toolTip = "Start WhisperServer automatically when you log in"
        submenu.addItem(launchItem)

        let exposeItem = NSMenuItem(
            title: "Expose on Local Network",
            action: #selector(toggleExposeOnLAN(_:)),
            keyEquivalent: ""
        )
        exposeItem.target = self
        exposeItem.tag = MenuItemTags.exposeOnLAN.rawValue
        exposeItem.state = settingsStore.exposeOnLAN ? .on : .off
        exposeItem.toolTip = "Bind the HTTP server to 0.0.0.0 so other devices on your network can reach it"
        submenu.addItem(exposeItem)

        if settingsStore.exposeOnLAN {
            appendLANMenuItems(to: submenu)
        }

#if DEBUG
        submenu.addItem(NSMenuItem.separator())
        let resetItem = NSMenuItem(
            title: "Reset Application Data…",
            action: #selector(resetApplicationData(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        resetItem.toolTip = "Remove all saved preferences and cached models"
        submenu.addItem(resetItem)
#endif

        return submenu
    }

    private func appendLANMenuItems(to menu: NSMenu) {
        for item in buildLANSectionItems() { menu.addItem(item) }
    }

    private func lanURLTitle() -> String {
        if let ip = NetworkUtility.primaryLocalIPv4() {
            return "    http://\(ip):\(currentServerPort)"
        }
        return "    LAN address unavailable"
    }

    /// Constructs the LAN sub-section items (order matters).
    private func buildLANSectionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        let urlItem = NSMenuItem(title: lanURLTitle(), action: nil, keyEquivalent: "")
        urlItem.tag = MenuItemTags.lanURL.rawValue
        urlItem.isEnabled = false
        urlItem.toolTip = "Address other devices on your network can use to reach this server"
        items.append(urlItem)

        let copyURLItem = NSMenuItem(
            title: "Copy Server URL",
            action: #selector(copyServerURL(_:)),
            keyEquivalent: ""
        )
        copyURLItem.target = self
        copyURLItem.tag = MenuItemTags.lanCopy.rawValue
        items.append(copyURLItem)

        let requireItem = NSMenuItem(
            title: "Require API Key",
            action: #selector(toggleRequireAPIKey(_:)),
            keyEquivalent: ""
        )
        requireItem.target = self
        requireItem.tag = MenuItemTags.requireAPIKey.rawValue
        requireItem.state = settingsStore.requireAPIKey ? .on : .off
        requireItem.toolTip = "Reject LAN requests without a valid Authorization: Bearer token"
        items.append(requireItem)

        if settingsStore.requireAPIKey {
            let copyKeyItem = NSMenuItem(
                title: "Copy API Key",
                action: #selector(copyAPIKey(_:)),
                keyEquivalent: ""
            )
            copyKeyItem.target = self
            copyKeyItem.tag = MenuItemTags.apiKeyCopy.rawValue
            items.append(copyKeyItem)

            let regenerateItem = NSMenuItem(
                title: "Regenerate API Key…",
                action: #selector(regenerateAPIKey(_:)),
                keyEquivalent: ""
            )
            regenerateItem.target = self
            regenerateItem.tag = MenuItemTags.apiKeyRegenerate.rawValue
            items.append(regenerateItem)
        }

        return items
    }

    /// Removes and re-creates the LAN sub-section inside the Preferences submenu.
    private func refreshLANMenuVisibility() {
        guard let topMenu = statusItem?.menu,
              let prefItem = topMenu.item(withTag: MenuItemTags.preferences.rawValue),
              let prefMenu = prefItem.submenu,
              let exposeIndex = prefMenu.items.firstIndex(where: { $0.tag == MenuItemTags.exposeOnLAN.rawValue }) else { return }

        // Wipe any existing LAN-section items (idempotent, order-insensitive).
        for tag in Self.lanSectionTags {
            let index = prefMenu.indexOfItem(withTag: tag.rawValue)
            if index >= 0 { prefMenu.removeItem(at: index) }
        }

        guard settingsStore.exposeOnLAN else { return }

        var insertAt = exposeIndex + 1
        for item in buildLANSectionItems() {
            prefMenu.insertItem(item, at: insertAt)
            insertAt += 1
        }
    }

    private func createModelSelectionMenu(_ parentMenu: NSMenu) {
        let modelSelectionMenuItem = NSMenuItem(title: "Select Model", action: nil, keyEquivalent: "")
        let modelSelectionSubmenu = NSMenu()
        populateModelSelectionSubmenu(modelSelectionSubmenu)

        modelSelectionMenuItem.submenu = modelSelectionSubmenu
        parentMenu.addItem(modelSelectionMenuItem)
    }
    
    private func applyStatusIcon(isProcessing: Bool) {
        let desiredIcon = isProcessing ? processingIconName : idleIconName
        guard currentIconName != desiredIcon else { return }

        statusItem?.button?.image = NSImage(systemSymbolName: desiredIcon, accessibilityDescription: "WhisperServer")
        currentIconName = desiredIcon
    }

    private func ensureProgressMenuItem(in menu: NSMenu) -> NSMenuItem {
        if let existingItem = menu.item(withTag: MenuItemTags.status.rawValue) {
            return existingItem
        }

        let progressItem = NSMenuItem(title: "Transcription", action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        progressItem.toolTip = "Current transcription progress"
        progressItem.tag = MenuItemTags.status.rawValue
        menu.insertItem(progressItem, at: 0)
        return progressItem
    }

    private func ensureDownloadMenuItem(in menu: NSMenu) -> NSMenuItem {
        if let existingItem = menu.item(withTag: MenuItemTags.download.rawValue) {
            return existingItem
        }

        let insertIndex = menu.items.firstIndex { $0.isSeparatorItem } ?? menu.items.count
        let progressItem = NSMenuItem(title: "Download: 0%", action: nil, keyEquivalent: "")
        progressItem.isEnabled = false
        progressItem.toolTip = "Current model download progress"
        progressItem.tag = MenuItemTags.download.rawValue
        menu.insertItem(progressItem, at: insertIndex)
        return progressItem
    }

    private func resolveModelName(from reportedName: String?) -> String {
        if let trimmed = reportedName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }

        if modelManager.selectedProvider == .fluid {
            return FluidTranscriptionService.defaultModel.displayName
        }

        return modelManager.selectedModelName ?? "Selected model"
    }

    private func removeProgressMenuItemIfNeeded(in menu: NSMenu? = nil) {
        guard let menu = menu ?? statusItem?.menu else { return }
        let index = menu.indexOfItem(withTag: MenuItemTags.status.rawValue)
        if index >= 0 {
            menu.removeItem(at: index)
        }
    }

    private func scheduleProgressResetIfNeeded(currentPercent: Int) {
        guard currentPercent != 0 else {
            removeProgressMenuItemIfNeeded()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }

            self.removeProgressMenuItemIfNeeded()
            self.isCurrentlyProcessing = false
            self.applyStatusIcon(isProcessing: false)
            self.updateTooltip(self.baseTooltip)
            self.progressResetWorkItem = nil
        }

        progressResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + progressResetDelay, execute: workItem)
    }

    private func updateTooltip(_ tooltip: String) {
        statusItem?.button?.toolTip = tooltip
    }
    
    private func populateModelSelectionSubmenu(_ submenu: NSMenu) {
        submenu.removeAllItems()

        #if DEBUG
        print("🔧 populateModelSelectionSubmenu provider:", modelManager.selectedProvider)
        #endif
        let fluidItem = NSMenuItem(title: "FluidAudio (Core ML)", action: #selector(selectFluidProvider), keyEquivalent: "")
        fluidItem.target = self
        fluidItem.state = (modelManager.selectedProvider == .fluid) ? .on : .off
        submenu.addItem(fluidItem)
        submenu.addItem(NSMenuItem.separator())

        if modelManager.availableModels.isEmpty {
            let noModelsItem = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
            noModelsItem.isEnabled = false
            submenu.addItem(noModelsItem)
        } else {
            for model in modelManager.availableModels {
                addModelMenuItems(for: model, to: submenu)
            }
        }

        submenu.addItem(NSMenuItem.separator())
        let importItem = NSMenuItem(title: "Import Whisper Model…", action: #selector(importWhisperModel), keyEquivalent: "")
        importItem.target = self
        submenu.addItem(importItem)

        let deleteParent = NSMenuItem(title: "Delete Downloaded Models", action: nil, keyEquivalent: "")
        deleteParent.submenu = buildDeleteDownloadedModelsSubmenu()
        submenu.addItem(deleteParent)
    }

    private func buildDeleteDownloadedModelsSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Delete Downloaded Models")

        let revealItem = NSMenuItem(
            title: "Show in Finder",
            action: #selector(showModelsInFinder(_:)),
            keyEquivalent: ""
        )
        revealItem.target = self
        revealItem.toolTip = "Open the folder where model files are stored"
        if #available(macOS 11.0, *) {
            revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show in Finder")
        }
        submenu.addItem(revealItem)
        submenu.addItem(NSMenuItem.separator())

        let downloadedWhisperIDs = modelManager.downloadedBundledWhisperModelIDs()
        let fluidDownloaded = modelManager.isFluidModelDownloaded()

        if downloadedWhisperIDs.isEmpty && !fluidDownloaded {
            let emptyItem = NSMenuItem(title: "No downloaded models", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
            return submenu
        }

        if fluidDownloaded {
            let fluidModel = FluidTranscriptionService.defaultModel
            let title = "\(fluidModel.displayName) (FluidAudio)"
            let item = NSMenuItem(
                title: title,
                action: #selector(confirmDeleteDownloadedFluid(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.toolTip = "Remove cached FluidAudio model files"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete Fluid model")
            }
            submenu.addItem(item)
        }

        if !downloadedWhisperIDs.isEmpty && fluidDownloaded {
            submenu.addItem(NSMenuItem.separator())
        }

        let whisperEntries = modelManager.availableModels
            .filter { downloadedWhisperIDs.contains($0.id) }
        for model in whisperEntries {
            let item = NSMenuItem(
                title: model.name,
                action: #selector(confirmDeleteDownloadedWhisper(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.id
            item.toolTip = "Remove cached files for this Whisper model"
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete Whisper model")
            }
            submenu.addItem(item)
        }

        return submenu
    }

    private func addModelMenuItems(for model: Model, to submenu: NSMenu) {
        let modelItem = NSMenuItem(title: model.name, action: #selector(selectModel(_:)), keyEquivalent: "")
        modelItem.target = self
        modelItem.representedObject = model.id
        if modelManager.selectedProvider == .whisper && model.id == modelManager.selectedModelID {
            modelItem.state = .on
        }

        if model.id.hasPrefix("user-") {
            modelItem.toolTip = "Hold Option (⌥) to delete"
        }

        submenu.addItem(modelItem)

        guard model.id.hasPrefix("user-") else { return }

        let deleteTitle = "Delete \(model.name)…"
        let deleteItem = NSMenuItem(title: deleteTitle, action: #selector(confirmDeleteModel(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = model.id
        deleteItem.isAlternate = true
        deleteItem.keyEquivalentModifierMask = [.option]
        deleteItem.toolTip = "Remove this model and its cached files"
        if #available(macOS 11.0, *) {
            deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete model")
        }
        submenu.addItem(deleteItem)
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(refreshModelSelectionMenu), 
            name: .modelManagerDidUpdate, 
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshModelSelectionMenu),
            name: .modelIsReady,
            object: nil
        )
    }
    
    // MARK: - Menu Actions
    
#if DEBUG
    @objc private func resetApplicationData(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Reset Application Data?"
        alert.informativeText = "All downloaded models, cached assets, and saved preferences will be removed. The app will close after the reset."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        serverCoordinator?.stopServer()
        WhisperTranscriptionService.cleanup()

        do {
            try modelManager.resetAllData()
            
            // Successfully reset, quit the app
            NSApp.terminate(nil)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Unable to reset data"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
            
            // Restart server on error
            serverCoordinator?.startServer()
        }
    }
#endif

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
        
        for item in menu.items {
            guard item.title == "Select Model", let submenu = item.submenu else { continue }
            populateModelSelectionSubmenu(submenu)
            break
        }
    }

    @objc private func importWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["bin", "zip", "mlmodelc"]
        panel.treatsFilePackagesAsDirectories = false
        panel.title = "Import Whisper Model"
        panel.message = "Select a Whisper .bin model file and optionally its .mlmodelc bundle."

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        guard urls.contains(where: { $0.pathExtension.lowercased() == "bin" }) else {
            let alert = NSAlert()
            alert.messageText = "Whisper model import failed"
            alert.informativeText = "Please select at least one .bin model file."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        serverCoordinator?.stopServer()
        defer { serverCoordinator?.restartServer() }

        do {
            let model = try modelManager.importUserModel(from: urls)
            print("📥 Imported user model: \(model.name) [\(model.id)]")
            refreshModelSelectionMenu()
        } catch {
            print("❌ Failed to import model: \(error.localizedDescription)")
        }
    }
    
    @objc private func showModelsInFinder(_: NSMenuItem) {
        guard let dir = modelManager.modelsDirectoryURL else {
            NSSound.beep()
            return
        }
        // Create the directory if it doesn't exist so Finder has something to open.
        // Surface any filesystem failure to the user instead of silently no-oping.
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Unable to open models folder"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(dir)
    }

    @objc private func confirmDeleteDownloadedWhisper(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String,
              let model = modelManager.availableModels.first(where: { $0.id == modelId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(model.name)\"?"
        alert.informativeText = "The downloaded files will be removed. The model will be re-downloaded automatically the next time you use it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        serverCoordinator?.stopServer()
        defer { serverCoordinator?.restartServer() }

        do {
            // ModelManager posts .modelManagerDidUpdate; the notification observer
            // on refreshModelSelectionMenu rebuilds the submenu for us.
            try modelManager.deleteDownloadedBundledWhisperModel(id: modelId)
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Unable to delete model"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    @objc private func confirmDeleteDownloadedFluid(_: NSMenuItem) {
        let modelName = FluidTranscriptionService.defaultModel.displayName

        let alert = NSAlert()
        alert.messageText = "Delete \"\(modelName)\"?"
        alert.informativeText = "The FluidAudio model cache will be removed. It will be re-downloaded automatically the next time you use it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        serverCoordinator?.stopServer()
        defer { serverCoordinator?.restartServer() }

        do {
            // ModelManager posts .modelManagerDidUpdate; the notification observer
            // on refreshModelSelectionMenu rebuilds the submenu for us.
            try modelManager.deleteDownloadedFluidModel()
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Unable to delete model"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    @objc private func confirmDeleteModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String,
              let model = modelManager.availableModels.first(where: { $0.id == modelId }) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete \"\(model.name)\"?"
        alert.informativeText = "This removes the model and its associated Core ML bundles."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        serverCoordinator?.stopServer()
        defer { serverCoordinator?.restartServer() }

        do {
            try modelManager.deleteUserModel(id: modelId)
            refreshModelSelectionMenu()
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Unable to delete model"
            errorAlert.informativeText = error.localizedDescription
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        // The checkmark is driven by the Combine observer on SettingsStore.$launchAtLogin,
        // so transient failure rollbacks in applyLaunchAtLogin end up reflected in the UI.
        settingsStore.launchAtLogin.toggle()
    }

    @objc private func toggleExposeOnLAN(_ sender: NSMenuItem) {
        let goingOn = !settingsStore.exposeOnLAN

        if goingOn && !settingsStore.lanWarningShown {
            let alert = NSAlert()
            alert.messageText = "Expose server on your local network?"
            alert.informativeText = """
            Other devices on your network will be able to send requests to the \
            server while this option is enabled. By default no authentication is \
            required — enable "Require API Key" below to restrict access.

            macOS may ask you to allow incoming connections the first time.
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            settingsStore.lanWarningShown = true
        }

        settingsStore.exposeOnLAN = goingOn
        sender.state = goingOn ? .on : .off
        refreshLANMenuVisibility()

        serverCoordinator?.restartServer()
    }

    @objc private func copyServerURL(_ sender: NSMenuItem) {
        guard let ip = NetworkUtility.primaryLocalIPv4() else {
            NSSound.beep()
            return
        }
        let url = "http://\(ip):\(currentServerPort)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    @objc private func toggleRequireAPIKey(_ sender: NSMenuItem) {
        let goingOn = !settingsStore.requireAPIKey

        if goingOn {
            let token: String
            do {
                token = try APIKeyStore.shared.ensureExists()
            } catch {
                presentAPIKeyFailureAlert(error: error)
                return
            }

            if !settingsStore.apiKeyWarningShown {
                let alert = NSAlert()
                alert.messageText = "API key required for LAN requests"
                alert.informativeText = """
                An API key has been generated and stored in your Keychain. \
                Copy it from the menu (Copy API Key) and include it with every \
                request as:

                    Authorization: Bearer \(token)

                Requests from this Mac (localhost) are always allowed without \
                the key.
                """
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")

                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                settingsStore.apiKeyWarningShown = true
            }
        }

        settingsStore.requireAPIKey = goingOn
        sender.state = goingOn ? .on : .off
        refreshLANMenuVisibility()
    }

    @objc private func copyAPIKey(_ sender: NSMenuItem) {
        let token: String
        do {
            token = try APIKeyStore.shared.ensureExists()
        } catch {
            presentAPIKeyFailureAlert(error: error)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
    }

    @objc private func regenerateAPIKey(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Regenerate API key?"
        alert.informativeText = """
        A new key will replace the current one. Any client using the current \
        key will stop working until you update it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let fresh: String
        do {
            fresh = try APIKeyStore.shared.regenerate()
        } catch {
            presentAPIKeyFailureAlert(error: error)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fresh, forType: .string)

        let confirmation = NSAlert()
        confirmation.messageText = "API key regenerated"
        confirmation.informativeText = "The new key has been copied to your clipboard."
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: "OK")
        confirmation.runModal()
    }

    private func presentAPIKeyFailureAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Unable to store API key"
        alert.informativeText = "\(error.localizedDescription)\n\nThe previous key (if any) was not replaced."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(self)
    }

}
