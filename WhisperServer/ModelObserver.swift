//
//  ModelObserver.swift
//  WhisperServer
//
//  Observes model state changes and coordinates UI updates
//

import Foundation

/// Observes model manager state and coordinates responses
final class ModelObserver: ObservableObject {
    // MARK: - Properties
    
    private let modelManager: ModelManager
    private weak var menuBarService: MenuBarService?
    private weak var serverCoordinator: ServerCoordinator?
    private var isPreloadingShaders = false
    private var lastUIUpdatedModelID: String?
    
    // MARK: - Initialization
    
    init(modelManager: ModelManager) {
        self.modelManager = modelManager
        setupNotificationObservers()
    }
    
    // MARK: - Public Interface
    
    func setMenuBarService(_ service: MenuBarService) {
        menuBarService = service
    }
    
    func setServerCoordinator(_ coordinator: ServerCoordinator) {
        serverCoordinator = coordinator
    }
    
    func updateUIForModelPreparation() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Prevent duplicate UI updates for the same model
            let currentModelID = self.modelManager.selectedModelID
            if currentModelID == self.lastUIUpdatedModelID {
                return
            }
            
            self.lastUIUpdatedModelID = currentModelID
            self.menuBarService?.updateMetalStatus(isActive: false)
        }
    }
    
    func preloadMetalShaders() {
        guard !isPreloadingShaders else {
            print("⚠️ Metal shader preloading already in progress, skipping duplicate request")
            return
        }
        
        let startTime = Date()
        isPreloadingShaders = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            var success = false
            
            if let modelPaths = self.modelManager.getPathsForSelectedModel() {
                success = WhisperTranscriptionService.preloadModelForShaderCaching(
                    modelBinPath: modelPaths.binPath,
                    modelEncoderDir: modelPaths.encoderDir
                )
            } else {
                print("❌ Could not get model paths from ModelManager")
            }
            
            DispatchQueue.main.async {
                self.isPreloadingShaders = false
                
                let elapsedTime = Date().timeIntervalSince(startTime)
                let formattedTime = String(format: "%.2f", elapsedTime)
                
                if success {
                    print("✅ Metal shader preloading completed in \(formattedTime) seconds")
                    self.menuBarService?.updateMetalStatus(isActive: false, failed: false)
                } else {
                    print("❌ Metal shader preloading failed after \(formattedTime) seconds")
                    self.menuBarService?.updateMetalStatus(isActive: false, failed: true)
                }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleModelReady), 
            name: .modelIsReady, 
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleModelPreparationFailed), 
            name: .modelPreparationFailed, 
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelStatusChanged),
            name: .modelManagerStatusChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleModelProgressChanged),
            name: .modelManagerProgressChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptionProgressUpdated(_:)),
            name: .transcriptionProgressUpdated,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetalActivated),
            name: WhisperTranscriptionService.metalActivatedNotificationName,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self, 
            selector: #selector(handleTinyModelAutoSelected), 
            name: .tinyModelAutoSelected, 
            object: nil
        )
    }
    
    // MARK: - Notification Handlers
    
    @objc private func handleModelReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.modelManager.isModelReady else {
                print("⚠️ Model was reported ready but isModelReady is false")
                return
            }

            if self.modelManager.selectedProvider == .fluid {
                self.menuBarService?.updateMetalStatus(isActive: false)
                self.menuBarService?.hideDownloadProgress()
                if self.serverCoordinator?.isRunning == false {
                    self.serverCoordinator?.startServer()
                }
                return
            }
            
            if self.modelManager.getPathsForSelectedModel() != nil {
                self.menuBarService?.updateMetalStatus(isActive: false)
                self.menuBarService?.hideDownloadProgress()
                if self.serverCoordinator?.isRunning == false {
                    self.serverCoordinator?.startServer()
                }
            } else {
                print("❌ Model reported ready but paths unavailable")
                self.handleModelPreparationFailed()
            }
        }
    }
    
    @objc private func handleModelPreparationFailed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("❌ Model preparation failed notification received")
            
            self.serverCoordinator?.stopServer()
            self.menuBarService?.updateMetalStatus(isActive: false, failed: true)
            self.updateUIForModelPreparation()
        }
    }
    
    @objc private func handleModelStatusChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let status = self.modelManager.currentStatus
            self.menuBarService?.showModelStatus(status)
        }
    }

    @objc private func handleModelProgressChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if let progress = self.modelManager.downloadProgress {
                self.menuBarService?.showDownloadProgress(progress)
                if progress < 1.0, self.serverCoordinator?.isRunning == true {
                    self.serverCoordinator?.stopServer()
                }
            } else {
                self.menuBarService?.hideDownloadProgress()
            }
        }
    }

    @objc private func handleTranscriptionProgressUpdated(_ notification: Notification) {
        let progressValue = notification.userInfo?[TranscriptionProgressUserInfoKey.progress] as? Double ?? 0.0
        let isProcessing = notification.userInfo?[TranscriptionProgressUserInfoKey.isProcessing] as? Bool ?? false
        let modelName = notification.userInfo?[TranscriptionProgressUserInfoKey.modelName] as? String

        DispatchQueue.main.async { [weak self] in
            self?.menuBarService?.updateTranscriptionProgress(
                progress: progressValue,
                isProcessing: isProcessing,
                modelName: modelName
            )
        }
    }
    
    @objc private func handleMetalActivated(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let modelName = notification.userInfo?["modelName"] as? String ?? "Unknown"
            print("🔥 Metal activated with model: \(modelName)")
            
            self.menuBarService?.updateMetalStatus(isActive: true, modelName: modelName)
        }
    }
    
    @objc private func handleTinyModelAutoSelected() {
        DispatchQueue.main.async { [weak self] in
            // Update server status when tiny model is auto-selected
            self?.serverCoordinator?.startServer()
        }
    }
}
