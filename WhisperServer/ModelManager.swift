import Foundation
import Combine
import FluidAudio

// MARK: - Data Structures

struct ModelFile: Codable, Hashable {
    let filename: String
    let url: String
    let type: String // "bin", "zip", or "mlmodelc"
}

struct Model: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let files: [ModelFile]
}

// MARK: - ModelManager Class

final class ModelManager: @unchecked Sendable {

    // MARK: - Properties

    enum Provider: String { case whisper, fluid }

    enum ModelPreparationError: LocalizedError {
        case modelsDirectoryUnavailable
        case noModelSelected
        case modelNotFound(String)
        case modelVerificationFailed

        var errorDescription: String? {
            switch self {
            case .modelsDirectoryUnavailable:
                return "Models directory is unavailable"
            case .noModelSelected:
                return "No model selected"
            case .modelNotFound(let identifier):
                return "Model with identifier '\(identifier)' is not available"
            case .modelVerificationFailed:
                return "Model verification failed after download"
            }
        }
    }

    enum ModelDeletionError: LocalizedError {
        case userModelsDirectoryUnavailable
        case modelNotFound(String)
        case notAUserModel
        case fileRemovalFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .userModelsDirectoryUnavailable:
                return "User models directory is unavailable"
            case .modelNotFound(let identifier):
                return "Model with identifier '\(identifier)' was not found"
            case .notAUserModel:
                return "Only user-imported models can be deleted"
            case .fileRemovalFailed(let path, let underlying):
                return "Failed to remove item at \(path): \(underlying.localizedDescription)"
            }
        }
    }

#if DEBUG
    enum ResetError: LocalizedError {
        case directoryRemovalFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .directoryRemovalFailed(let path, let underlying):
                return "Failed to remove \(path): \(underlying.localizedDescription)"
            }
        }
    }
#endif

    @Published private(set) var availableModels: [Model] = []
    @Published private(set) var selectedModelID: String? {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID")
            // Trigger notification when selection changes
            NotificationCenter.default.post(name: .modelManagerDidUpdate, object: self)
            if !suppressAutoPrepare { checkAndPrepareSelectedModel() }
        }
    }

    @Published private(set) var selectedProvider: Provider = .whisper {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "selectedProvider")
            NotificationCenter.default.post(name: .modelManagerDidUpdate, object: self)
            if !suppressAutoPrepare { checkAndPrepareSelectedModel() }
        }
    }
    
    /// Name of the selected model for UI display and logging
    var selectedModelName: String? {
        guard let modelID = selectedModelID else { return nil }
        return availableModels.first(where: { $0.id == modelID })?.name
    }
    
    @Published private(set) var currentStatus: String = "Initializing..." {
        didSet { NotificationCenter.default.post(name: .modelManagerStatusChanged, object: self) }
    }
    @Published private(set) var downloadProgress: Double? = nil { didSet { NotificationCenter.default.post(name: .modelManagerProgressChanged, object: self) } }
    
    /// Flag to indicate if model is ready for use
    @Published private(set) var isModelReady: Bool = false
    
    /// Flags to prevent duplicate preparation per provider
    private var isPreparingWhisperModel: Bool = false
    private var isPreparingFluidModel: Bool = false

    private let fileManager = FileManager.default
    private var modelsDirectory: URL?
    private var userModelsDirectory: URL?
    private var currentDownloadTasks: [URLSessionDownloadTask] = []
    private var urlSession: URLSession!
    private var progressObservation: NSKeyValueObservation?
    private var suppressAutoPrepare: Bool = false
    private var whisperPreparationTask: Task<Void, Never>?
    private var fluidPreparationTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        let configuration = URLSessionConfiguration.default
        self.urlSession = URLSession(configuration: configuration, delegate: nil, delegateQueue: OperationQueue())

        setupModelsDirectory()
        loadModelDefinitions()
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModelID") ?? availableModels.first?.id
        if let providerRaw = UserDefaults.standard.string(forKey: "selectedProvider"),
           let provider = Provider(rawValue: providerRaw) {
            selectedProvider = provider
        } else {
            selectedProvider = .whisper
        }
        NotificationCenter.default.post(name: .modelManagerDidUpdate, object: self)
        checkAndPrepareSelectedModel()
    }

    // MARK: - Public Methods

    func selectModel(id: String) {
        guard availableModels.contains(where: { $0.id == id }) else {
            return
        }
        // Batch-update to avoid intermediate preparations on stale state
        suppressAutoPrepare = true
        selectedProvider = .whisper
        selectedModelID = id
        suppressAutoPrepare = false
        checkAndPrepareSelectedModel()
    }

    func selectProvider(_ provider: Provider) {
        selectedProvider = provider
    }

#if DEBUG
    /// Removes all cached data and resets model selections to their defaults (debug builds only).
    func resetAllData() throws {
        // Cancel any active downloads
        currentDownloadTasks.forEach { $0.cancel() }
        currentDownloadTasks.removeAll()
        progressObservation?.invalidate()
        progressObservation = nil
        whisperPreparationTask?.cancel()
        whisperPreparationTask = nil
        fluidPreparationTask?.cancel()
        fluidPreparationTask = nil

        isPreparingWhisperModel = false
        isPreparingFluidModel = false

        // Reset user defaults
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedModelID")
            UserDefaults.standard.removeObject(forKey: "selectedProvider")
        }
        UserDefaults.standard.synchronize()

        downloadProgress = nil
        isModelReady = false
        currentStatus = "Resetting application data..."

        suppressAutoPrepare = true
        selectedModelID = nil
        selectedProvider = .whisper
        suppressAutoPrepare = false

        // Remove cached data directories
        var directoriesToRemove: [URL] = []
        if let baseModelsDir = modelsDirectory?.deletingLastPathComponent() {
            directoriesToRemove.append(baseModelsDir)
        } else if let modelsDir = modelsDirectory {
            directoriesToRemove.append(modelsDir)
        }
        let fluidDir = FluidTranscriptionService.cacheDirectory()
        directoriesToRemove.append(fluidDir)

        for directory in Set(directoriesToRemove) {
            if fileManager.fileExists(atPath: directory.path) {
                do {
                    try fileManager.removeItem(at: directory)
                } catch {
                    throw ResetError.directoryRemovalFailed(path: directory.path, underlying: error)
                }
            }
        }

        // Recreate directories and reload bundled models
        setupModelsDirectory()
        loadModelDefinitions()

        suppressAutoPrepare = true
        selectedProvider = .whisper
        selectedModelID = availableModels.first?.id
        suppressAutoPrepare = false

        NotificationCenter.default.post(name: .modelManagerDidUpdate, object: self)
        checkAndPrepareSelectedModel()
    }
#endif

    // MARK: - Private Setup & Loading

    private func setupModelsDirectory() {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            currentStatus = "Error: Cannot access Application Support"
            return
        }
        // Use Bundle Identifier to create a unique subdirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "WhisperServer"
        modelsDirectory = appSupportURL.appendingPathComponent(bundleID).appendingPathComponent("Models")

        guard let modelsDirectory = modelsDirectory else { return }

        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            currentStatus = "Error: Cannot create models directory"
            self.modelsDirectory = nil // Prevent further operations if directory failed
        }

        // Ensure user models subdirectory exists
        let userDir = modelsDirectory.appendingPathComponent("User")
        do {
            try fileManager.createDirectory(at: userDir, withIntermediateDirectories: true, attributes: nil)
            userModelsDirectory = userDir
        } catch {
            // If we fail to create user directory, we can still operate without it
            userModelsDirectory = nil
        }

    }

    private func loadModelDefinitions() {
        guard let url = Bundle.main.url(forResource: "Models", withExtension: "json") else {
            currentStatus = "Error: Models.json missing"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            availableModels = try JSONDecoder().decode([Model].self, from: data)
            currentStatus = "Ready" // Initial status after loading JSON
        } catch {
            currentStatus = "Error: Invalid Models.json"
            availableModels = []
        }

        // Merge user models from disk (if any)
        loadUserModelsFromDisk()
    }

    private func encoderArtifactBaseName(for name: String) -> String? {
        var trimmed = name
        // Remove common extensions in sequence
        if trimmed.hasSuffix(".zip") {
            trimmed = (trimmed as NSString).deletingPathExtension
        }
        if trimmed.hasSuffix(".mlmodelc") {
            trimmed = (trimmed as NSString).deletingPathExtension
        }
        let suffix = "-encoder"
        guard trimmed.hasSuffix(suffix) else { return nil }
        return String(trimmed.dropLast(suffix.count))
    }

    // MARK: - User Models

    /// Scans the user models directory for locally added Whisper models and merges them into the catalog.
    private func loadUserModelsFromDisk() {
        guard let userDir = userModelsDirectory else { return }

        // Find top-level artifacts in user directory
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey]
        let directoryContents = (try? fileManager.contentsOfDirectory(
            at: userDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var binFiles: [String: URL] = [:]
        var mlmodelcDirs: [String: URL] = [:]

        for item in directoryContents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if item.pathExtension.lowercased() == "mlmodelc",
                   let base = encoderArtifactBaseName(for: item.lastPathComponent) {
                    mlmodelcDirs[base] = item
                }
                continue
            }

            if item.pathExtension.lowercased() == "bin" {
                let base = (item.lastPathComponent as NSString).deletingPathExtension
                binFiles[base] = item
            }
        }

        var discovered: [Model] = []
        for (base, binURL) in binFiles {
            var files: [ModelFile] = [ModelFile(filename: binURL.lastPathComponent, url: "local", type: "bin")]
            if let mlDir = mlmodelcDirs[base] {
                files.append(ModelFile(filename: mlDir.lastPathComponent, url: "local", type: "mlmodelc"))
            }
            let modelID = "user-\(base)"
            let model = Model(id: modelID, name: base, files: files)
            discovered.append(model)
        }

        if !discovered.isEmpty {
            let existingIDs = Set(availableModels.map { $0.id })
            let newOnes = discovered.filter { !existingIDs.contains($0.id) }
            if !newOnes.isEmpty {
                availableModels.append(contentsOf: newOnes)
            }
        }
    }

    /// Imports a user-provided Whisper model file(s) into the user models directory and returns the created catalog entry.
    /// Accepts a .bin file and optionally additional files (e.g., .zip). Only the .bin is required.
    @discardableResult
    func importUserModel(from urls: [URL]) throws -> Model {
        guard let userDir = userModelsDirectory else {
            throw NSError(domain: "ModelManager", code: 100, userInfo: [NSLocalizedDescriptionKey: "User models directory unavailable"])
        }

        // Identify the primary .bin file
        guard let binURL = urls.first(where: { $0.pathExtension.lowercased() == "bin" }) else {
            throw NSError(domain: "ModelManager", code: 101, userInfo: [NSLocalizedDescriptionKey: "No .bin file selected"])
        }

        let baseName = (binURL.lastPathComponent as NSString).deletingPathExtension
        let newBinName = binURL.lastPathComponent
        let destBinURL = userDir.appendingPathComponent(newBinName)

        // Copy .bin file
        if fileManager.fileExists(atPath: destBinURL.path) {
            // Overwrite existing file with same name
            try fileManager.removeItem(at: destBinURL)
        }
        try fileManager.copyItem(at: binURL, to: destBinURL)

        // Prepare model files list
        var files: [ModelFile] = [ModelFile(filename: newBinName, url: "local", type: "bin")]

        // Optionally copy a Core ML bundle (.mlmodelc directory)
        if let mlmodelcURL = urls.first(where: { url in
            let ext = url.pathExtension.lowercased()
            if ext == "mlmodelc" { return true }
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue && url.lastPathComponent.lowercased().hasSuffix(".mlmodelc")
        }),
           let artifactBase = encoderArtifactBaseName(for: mlmodelcURL.lastPathComponent),
           artifactBase == baseName {
            let destMLURL = userDir.appendingPathComponent(mlmodelcURL.lastPathComponent)
            if fileManager.fileExists(atPath: destMLURL.path) {
                try? fileManager.removeItem(at: destMLURL)
            }
            try fileManager.copyItem(at: mlmodelcURL, to: destMLURL)
            files.append(ModelFile(filename: mlmodelcURL.lastPathComponent, url: "local", type: "mlmodelc"))
        }

        // Optionally copy a .zip (e.g., encoder assets) if provided
        if let zipURL = urls.first(where: { $0.pathExtension.lowercased() == "zip" }),
           let artifactBase = encoderArtifactBaseName(for: zipURL.lastPathComponent),
           artifactBase == baseName {
            let destZipURL = userDir.appendingPathComponent(zipURL.lastPathComponent)
            if fileManager.fileExists(atPath: destZipURL.path) {
                try? fileManager.removeItem(at: destZipURL)
            }
            try? fileManager.copyItem(at: zipURL, to: destZipURL)
            files.append(ModelFile(filename: zipURL.lastPathComponent, url: "local", type: "zip"))
        }

        // Create model entry and add to catalog
        let modelID = "user-\(baseName)"
        let modelName = baseName
        let model = Model(id: modelID, name: modelName, files: files)

        // Merge into available models (avoid duplicates by id)
        if !availableModels.contains(where: { $0.id == model.id }) {
            availableModels.append(model)
        }

        // Select newly imported model for immediate use
        suppressAutoPrepare = true
        selectedProvider = .whisper
        selectedModelID = model.id
        suppressAutoPrepare = false
        checkAndPrepareSelectedModel()

        // Persist selection; catalog persistence is implicit by scanning user dir on launch
        return model
    }

    func deleteUserModel(id: String) throws {
        guard id.hasPrefix("user-") else {
            throw ModelDeletionError.notAUserModel
        }

        guard let index = availableModels.firstIndex(where: { $0.id == id }) else {
            throw ModelDeletionError.modelNotFound(id)
        }

        guard let userDir = userModelsDirectory else {
            throw ModelDeletionError.userModelsDirectoryUnavailable
        }

        let model = availableModels[index]
        let otherModels = availableModels.enumerated().filter { $0.offset != index }.map { $0.element }

        let removedModelWasSelected = (selectedModelID == model.id)

        let isShared: (ModelFile) -> Bool = { file in
            otherModels.contains { other in
                other.files.contains { candidate in
                    candidate.filename == file.filename && candidate.type == file.type
                }
            }
        }

        let removeIfExists: (URL) throws -> Void = { url in
            if self.fileManager.fileExists(atPath: url.path) {
                do {
                    try self.fileManager.removeItem(at: url)
                } catch {
                    throw ModelDeletionError.fileRemovalFailed(path: url.path, underlying: error)
                }
            }
        }

        for fileInfo in model.files {
            try removeIfExists(userDir.appendingPathComponent(fileInfo.filename))

            if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                try removeIfExists(userDir.appendingPathComponent(unzippedName))
            }

            guard let modelsDir = modelsDirectory, !isShared(fileInfo) else { continue }

            try removeIfExists(modelsDir.appendingPathComponent(fileInfo.filename))

            if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                try removeIfExists(modelsDir.appendingPathComponent(unzippedName))
            }
        }

        availableModels.remove(at: index)

        if removedModelWasSelected {
            suppressAutoPrepare = true

            if let fallback = availableModels.first(where: { !$0.id.hasPrefix("user-") }) ?? availableModels.first {
                selectedModelID = fallback.id
            } else {
                selectedModelID = nil
                isModelReady = false
                currentStatus = "No model selected"
            }

            suppressAutoPrepare = false
        }

        NotificationCenter.default.post(name: .modelManagerDidUpdate, object: self)

        if removedModelWasSelected, selectedModelID != nil {
            checkAndPrepareSelectedModel()
        }
    }

    // MARK: - Model Preparation (Checking & Downloading) - To be implemented

    func checkAndPrepareSelectedModel() {
        if selectedProvider == .fluid {
            whisperPreparationTask?.cancel()
            whisperPreparationTask = nil
            fluidPreparationTask?.cancel()

            if isPreparingFluidModel { return }
            isPreparingFluidModel = true
            isModelReady = false
            currentStatus = "Preparing FluidAudio model..."
            downloadProgress = nil

            fluidPreparationTask = Task { [weak self] in
                guard let self = self else { return }
                do {
                    let cacheDir = FluidTranscriptionService.cacheDirectory()
                    do {
                        try self.fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
                    } catch {
                        print("⚠️ Unable to ensure FluidAudio cache directory: \(error.localizedDescription)")
                    }
                    try Task.checkCancellation()
                    _ = try await AsrModels.downloadAndLoad(to: cacheDir)
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.currentStatus = "FluidAudio model ready"
                        self.isModelReady = true
                        self.downloadProgress = nil
                        self.isPreparingFluidModel = false
                        NotificationCenter.default.post(name: .modelIsReady, object: self)
                        self.fluidPreparationTask = nil
                    }
                } catch is CancellationError {
                    await MainActor.run {
                        self.isPreparingFluidModel = false
                        self.downloadProgress = nil
                        self.currentStatus = "Ready"
                        self.fluidPreparationTask = nil
                    }
                } catch {
                    await MainActor.run {
                        self.currentStatus = "Error preparing FluidAudio model: \(error.localizedDescription)"
                        self.isModelReady = false
                        self.downloadProgress = nil
                        self.isPreparingFluidModel = false
                        NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
                        self.fluidPreparationTask = nil
                    }
                }
            }
            return
        }

        guard let targetID = selectedModelID else {
            currentStatus = "No model selected"
            isModelReady = false
            NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            return
        }

        whisperPreparationTask?.cancel()
        whisperPreparationTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                try Task.checkCancellation()
                _ = try await self.prepareModelForUse(modelID: targetID)
                try Task.checkCancellation()
            } catch {
                if (error is CancellationError) || Task.isCancelled {
                    await MainActor.run {
                        self.downloadProgress = nil
                        self.isModelReady = false
                        self.currentStatus = "Ready"
                    }
                } else {
                    await MainActor.run {
                        self.currentStatus = "Error preparing model: \(error.localizedDescription)"
                        self.isModelReady = false
                        self.downloadProgress = nil
                    }
                }
            }
            await MainActor.run {
                self.whisperPreparationTask = nil
            }
        }
    }

    func prepareModelForUse(modelID requestedModelID: String?) async throws -> (binPath: URL, encoderDir: URL) {
        guard let modelsDir = modelsDirectory else {
            await MainActor.run {
                self.currentStatus = "Error: Cannot prepare model"
                self.isModelReady = false
                self.downloadProgress = nil
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw ModelPreparationError.modelsDirectoryUnavailable
        }
        try Task.checkCancellation()

        let trimmedID = requestedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier: String
        if let trimmedID, !trimmedID.isEmpty {
            identifier = trimmedID
        } else if let selectedID = selectedModelID {
            identifier = selectedID
        } else {
            await MainActor.run {
                self.currentStatus = "No model selected"
                self.isModelReady = false
                self.downloadProgress = nil
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw ModelPreparationError.noModelSelected
        }

        guard let model = availableModels.first(where: { $0.id == identifier || $0.name.caseInsensitiveCompare(identifier) == .orderedSame }) else {
            await MainActor.run {
                self.currentStatus = "Model '\(identifier)' is not available"
                self.isModelReady = false
                self.downloadProgress = nil
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw ModelPreparationError.modelNotFound(identifier)
        }
        try Task.checkCancellation()

        await MainActor.run {
            self.suppressAutoPrepare = true
            if self.selectedProvider != .whisper {
                self.selectedProvider = .whisper
            }
            if self.selectedModelID != model.id {
                self.selectedModelID = model.id
            }
            self.suppressAutoPrepare = false
        }

        await MainActor.run {
            self.isPreparingWhisperModel = true
        }
        let resetPreparing: () -> Void = {
            Task { @MainActor in
                self.isPreparingWhisperModel = false
            }
        }
        defer { resetPreparing() }

        try Task.checkCancellation()
        let filesExist: Bool
        do {
            filesExist = try await checkModelFilesExist(model: model, directory: modelsDir)
        } catch {
            await MainActor.run {
                self.currentStatus = "Error checking model files: \(error.localizedDescription)"
                self.downloadProgress = nil
                self.isModelReady = false
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw error
        }
        try Task.checkCancellation()

        if filesExist, let paths = getPaths(for: model, directory: modelsDir) {
            await MainActor.run {
                self.currentStatus = "Model '\(model.name)' is ready."
                self.downloadProgress = nil
                self.isModelReady = true
                NotificationCenter.default.post(name: .modelIsReady, object: self)
            }
            return paths
        }

        await MainActor.run {
            self.currentStatus = "Downloading model: \(model.name)..."
            self.downloadProgress = 0.0
            self.isModelReady = false
        }
        try Task.checkCancellation()

        do {
            try await downloadAndPrepareModel(model: model, directory: modelsDir)
        } catch {
            await MainActor.run {
                self.currentStatus = "Error downloading model: \(error.localizedDescription)"
                self.downloadProgress = nil
                self.isModelReady = false
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw error
        }
        try Task.checkCancellation()

        guard let preparedPaths = getPaths(for: model, directory: modelsDir) else {
            await MainActor.run {
                self.currentStatus = "Error: Model verification failed"
                self.downloadProgress = nil
                self.isModelReady = false
                NotificationCenter.default.post(name: .modelPreparationFailed, object: self)
            }
            throw ModelPreparationError.modelVerificationFailed
        }

        return preparedPaths
    }

    private func checkModelFilesExist(model: Model, directory: URL) async throws -> Bool {
        for fileInfo in model.files {
            var isDirectory: ObjCBool = false

            if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                let mainURL = directory.appendingPathComponent(unzippedName)
                let userURL = userModelsDirectory?.appendingPathComponent(unzippedName)
                let existsInMain = fileManager.fileExists(atPath: mainURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                let existsInUser = (userURL != nil) && fileManager.fileExists(atPath: userURL!.path, isDirectory: &isDirectory) && isDirectory.boolValue
                if !(existsInMain || existsInUser) {
                    print("Missing unzipped directory in main/user: \(mainURL.path) / \(userURL?.path ?? "nil")")
                    return false
                }
            } else if fileInfo.type == "mlmodelc" {
                let mainURL = directory.appendingPathComponent(fileInfo.filename)
                let userURL = userModelsDirectory?.appendingPathComponent(fileInfo.filename)
                let existsInMain = fileManager.fileExists(atPath: mainURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
                let existsInUser = (userURL != nil) && fileManager.fileExists(atPath: userURL!.path, isDirectory: &isDirectory) && isDirectory.boolValue
                if !(existsInMain || existsInUser) {
                    print("Missing Core ML bundle in main/user: \(mainURL.path) / \(userURL?.path ?? "nil")")
                    return false
                }
            } else { // For .bin and other regular files
                let mainURL = directory.appendingPathComponent(fileInfo.filename)
                var exists = fileManager.fileExists(atPath: mainURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                if !exists, let userDir = userModelsDirectory {
                    let userURL = userDir.appendingPathComponent(fileInfo.filename)
                    exists = fileManager.fileExists(atPath: userURL.path, isDirectory: &isDirectory) && !isDirectory.boolValue
                }
                if !exists {
                    print("Missing file in main/user: \(mainURL.path)")
                    return false
                }
            }
        }
        return true // All required files/directories exist
    }

    // MARK: - Downloading Logic

    private func downloadAndPrepareModel(model: Model, directory: URL) async throws {
        // First, clean up any potentially corrupted files from previous attempts
        try cleanupModelDirectory(model: model, directory: directory)
        
        var downloadedZipURLs: [URL] = []
        var allFilesReady = true

        // Step 1: Download all required files
        for fileInfo in model.files {
            let destinationURL = directory.appendingPathComponent(fileInfo.filename)
            var needsDownload = true

            // For locally imported models, skip network downloads entirely
            if fileInfo.url == "local" || fileInfo.url.lowercased().hasPrefix("file://") {
                needsDownload = false
            }
            
            if needsDownload {
                guard let url = URL(string: fileInfo.url) else {
                    print("❌ Invalid URL string: \(fileInfo.url)")
                    allFilesReady = false
                    throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL string: \(fileInfo.url)"])
                }

                print("🔽 Downloading \(fileInfo.filename) from \(url)...")
                DispatchQueue.main.async { [weak self] in
                    self?.currentStatus = "Downloading \(fileInfo.filename)..."
                    self?.downloadProgress = 0 // Reset progress for new file
                }

                do {
                    let temporaryURL = try await downloadFile(from: url, to: destinationURL)
                    print("✅ Successfully downloaded \(fileInfo.filename)")
                    
                    if fileInfo.type == "zip" {
                        downloadedZipURLs.append(temporaryURL)
                    }
                } catch {
                    print("❌ Failed to download \(fileInfo.filename): \(error)")
                    allFilesReady = false
                    throw error
                }
            } else if fileInfo.type == "zip" {
                downloadedZipURLs.append(destinationURL)
            }
        }

        // Step 2: Extract all zip files
        for zipURL in downloadedZipURLs {
            let unzippedName = (zipURL.lastPathComponent as NSString).deletingPathExtension
            let unzippedDestinationURL = directory.appendingPathComponent(unzippedName)

            // Always remove existing directory to start fresh
            if fileManager.fileExists(atPath: unzippedDestinationURL.path) {
                do {
                    print("🗑️ Removing existing directory: \(unzippedDestinationURL.path)")
                    try fileManager.removeItem(at: unzippedDestinationURL)
                } catch {
                    print("⚠️ Failed to remove existing directory: \(error)")
                }
            }
            
            // Proceed with unzip
            print("📦 Unzipping \(zipURL.path) to \(directory.path)...")
            DispatchQueue.main.async { [weak self] in
                self?.currentStatus = "Unzipping \(zipURL.lastPathComponent)..."
                self?.downloadProgress = nil
            }
            
            do {
                try await unzipFile(at: zipURL, to: directory)
                print("📦 Unzip completed successfully")
                
                // Verify the unzipped directory exists and has contents
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: unzippedDestinationURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: unzippedDestinationURL.path)
                        print("📦 Unzipped directory contains \(contents.count) items")
                        if contents.isEmpty {
                            print("⚠️ Unzipped directory is empty!")
                            allFilesReady = false
                        }
                    } catch {
                        print("⚠️ Failed to check unzipped directory contents: \(error)")
                        allFilesReady = false
                    }
                } else {
                    print("❌ Unzipped directory was not created: \(unzippedDestinationURL.path)")
                    allFilesReady = false
                }
            } catch {
                print("❌ Failed to unzip \(zipURL.lastPathComponent): \(error)")
                allFilesReady = false
            }

            // Delete the zip file after successful unzip or if it wasn't needed
            print("🗑️ Deleting archive \(zipURL.path)...")
            deleteFile(at: zipURL)
        }

        if !allFilesReady {
            throw NSError(domain: "ModelManager", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Failed to prepare all model files"
            ])
        }
        
        // Extra validation step - use getPathsForSelectedModel to verify everything is ready
        guard getPathsForSelectedModel() != nil else {
            throw NSError(domain: "ModelManager", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Model verification failed after preparation"
            ])
        }

        DispatchQueue.main.async { [weak self] in
             self?.currentStatus = "Model '\(model.name)' is ready."
             self?.downloadProgress = nil
             print("✅ Model \(model.name) preparation complete.")
             self?.isModelReady = true
             NotificationCenter.default.post(name: .modelIsReady, object: self)
         }
    }

    /// Clean up any corrupted model files before downloading
    private func cleanupModelDirectory(model: Model, directory: URL) throws {
        print("🧹 Cleaning up model directory before download")
        
        for fileInfo in model.files {
            let localURL = directory.appendingPathComponent(fileInfo.filename)
            
            // Remove any existing bin files
            if fileInfo.type == "bin" && fileManager.fileExists(atPath: localURL.path) {
                print("🧹 Removing existing bin file: \(localURL.path)")
                try? fileManager.removeItem(at: localURL)
            }
            
            // Remove any existing zip files and their extracted directories
            if fileInfo.type == "zip" {
                // Remove zip file if it exists
                if fileManager.fileExists(atPath: localURL.path) {
                    print("🧹 Removing existing zip file: \(localURL.path)")
                    try? fileManager.removeItem(at: localURL)
                }
                
                // Remove the extracted directory if it exists
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                let unzippedURL = directory.appendingPathComponent(unzippedName)
                if fileManager.fileExists(atPath: unzippedURL.path) {
                    print("🧹 Removing existing unzipped directory: \(unzippedURL.path)")
                    try? fileManager.removeItem(at: unzippedURL)
                }
            }
        }
        
        // Optional: List what's left in the directory after cleanup
        do {
            let remaining = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            if remaining.isEmpty {
                print("🧹 Directory is now empty")
            } else {
                print("🧹 Remaining files after cleanup:")
                for item in remaining {
                    print("  - \(item.lastPathComponent)")
                }
            }
        } catch {
            print("🧹 Error listing directory contents: \(error)")
        }
    }

    private func downloadFile(from url: URL, to destinationURL: URL) async throws -> URL {
        print("🔽 Downloading from: \(url.absoluteString)")
        print("🔽 To destination: \(destinationURL.path)")
        
        // First check if the destination path's parent directory exists
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        
        if !fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            do {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                print("🔽 Created destination directory: \(destinationDirectory.path)")
            } catch {
                print("🔽 Error creating destination directory: \(error)")
                throw error
            }
        } else {
            print("🔽 Destination directory exists")
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            var downloadTask: URLSessionDownloadTask!
            
            let downloadHandler: @Sendable (URL?, URLResponse?, Error?) -> Void = { [weak self] (temporaryURL: URL?, response: URLResponse?, error: Error?) in
                // Cleanup observation on completion or error
                self?.progressObservation?.invalidate()
                self?.progressObservation = nil
                 
                if let self = self {
                    DispatchQueue.main.async {
                        self.currentDownloadTasks.removeAll { $0 === downloadTask }
                    }
                }

                if let error = error {
                    print("🔽 Download error: \(error.localizedDescription)")
                    // Ensure partial downloads are removed
                    if let tempURL = temporaryURL {
                        self?.deleteFile(at: tempURL)
                    }
                    continuation.resume(throwing: error)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                     let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("🔽 Invalid download response: Status code \(statusCode)")
                    if let tempURL = temporaryURL {
                        self?.deleteFile(at: tempURL)
                    }
                    continuation.resume(throwing: NSError(domain: "ModelManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP status code: \(statusCode)"])) 
                    return
                }

                guard let temporaryURL = temporaryURL else {
                    print("🔽 Download error: Missing temporary file URL.")
                    continuation.resume(throwing: NSError(domain: "ModelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing temporary download URL"])) 
                    return
                }
                
                // Verify the temporary downloaded file
                do {
                    let attrs = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
                    if let fileSize = attrs[.size] as? UInt64 {
                        print("🔽 Downloaded file size: \(fileSize) bytes")
                        if fileSize < 1000 {
                            print("🔽 Warning: Downloaded file is suspiciously small!")
                        }
                    }
                    
                    // For bin files, check if we can read a header to verify it's a valid file
                    if destinationURL.pathExtension.lowercased() == "bin" {
                        let fileHandle = try FileHandle(forReadingFrom: temporaryURL)
                        let header = try fileHandle.read(upToCount: 16)
                        try fileHandle.close()
                        
                        if header == nil || header!.isEmpty {
                            print("🔽 Warning: Could not read header from downloaded file")
                        } else {
                            print("🔽 Successfully verified file header")
                        }
                    }
                } catch {
                    print("🔽 Error verifying downloaded file: \(error)")
                    // Continue anyway since we already have the file
                }

                do {
                    guard let self = self else {
                        try? FileManager.default.removeItem(at: temporaryURL)
                        continuation.resume(throwing: NSError(domain: "ModelManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Self reference lost during download completion"]))
                        return
                    }
                    
                    // Ensure destination directory exists (it should, but double-check)
                    try self.fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    
                    // If a file exists at the destination, remove it first.
                    if self.fileManager.fileExists(atPath: destinationURL.path) {
                        try self.fileManager.removeItem(at: destinationURL)
                        print("🔽 Removed existing file at destination")
                    }
                    
                    // Move the downloaded file to the final destination
                    try self.fileManager.moveItem(at: temporaryURL, to: destinationURL)
                    print("🔽 Successfully moved file to: \(destinationURL.path)")
                    
                    // Verify the final file
                    if self.fileManager.fileExists(atPath: destinationURL.path) {
                        let attrs = try self.fileManager.attributesOfItem(atPath: destinationURL.path)
                        if let fileSize = attrs[.size] as? UInt64 {
                            print("🔽 Final file size: \(fileSize) bytes")
                        }
                        
                        var isDir: ObjCBool = false
                        if self.fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDir) {
                            print("🔽 Is directory: \(isDir.boolValue)")
                        }
                    } else {
                        print("🔽 Warning: File not found at destination after move")
                    }
                    
                    continuation.resume(returning: destinationURL)
                } catch {
                    print("🔽 Error moving downloaded file: \(error)")
                     // Cleanup temp file if move fails
                    self?.deleteFile(at: temporaryURL)
                    continuation.resume(throwing: error)
                }
            }
            
            // Create the download task
            downloadTask = urlSession.downloadTask(with: url, completionHandler: downloadHandler)

            // Observe download progress
            self.progressObservation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                DispatchQueue.main.async {
                    self?.downloadProgress = progress.fractionCompleted
                    if progress.fractionCompleted > 0 && Int(progress.fractionCompleted * 100) % 10 == 0 {
                        print("🔽 Download progress: \(Int(progress.fractionCompleted * 100))%")
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.currentDownloadTasks.append(downloadTask)
            }
            downloadTask.resume()
        }
    }

    // MARK: - Unzipping Logic

    private func unzipFile(at sourceURL: URL, to destinationDirectoryURL: URL) async throws {
        // Validate source file exists and is readable
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            print("📦❌ Source zip file doesn't exist or isn't readable: \(sourceURL.path)")
            throw NSError(domain: "ModelManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Source zip file doesn't exist or isn't readable"
            ])
        }
        
        // Validate destination directory exists and is writable
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destinationDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: destinationDirectoryURL.path) else {
            print("📦❌ Destination directory doesn't exist or isn't writable: \(destinationDirectoryURL.path)")
            throw NSError(domain: "ModelManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Destination directory doesn't exist or isn't writable"
            ])
        }
        
        // Test if file is a valid zip file
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHandle(forReadingFrom: sourceURL)
            let header = try fileHandle.read(upToCount: 4)
            try fileHandle.close()
            
            // ZIP files start with PK header (0x50 0x4B 0x03 0x04)
            guard let data = header, data.count >= 4,
                  data[0] == 0x50 && data[1] == 0x4B else {
                print("📦❌ File is not a valid ZIP file: \(sourceURL.path)")
                throw NSError(domain: "ModelManager", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "File is not a valid ZIP file"
                ])
            }
        } catch {
            print("📦❌ Failed to verify ZIP file format: \(error)")
            throw NSError(domain: "ModelManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to verify ZIP file format: \(error.localizedDescription)"
            ])
        }
        
        print("📦 Unzipping file with size: \((try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? UInt64) ?? 0) bytes")
        
        try await Task.detached(priority: .userInitiated) { // Run Process on a background thread
            print("📦 Starting unzip process...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            // Arguments: -o (overwrite without prompt), zip file path, -d (destination directory), destination path
            process.arguments = ["-o", sourceURL.path, "-d", destinationDirectoryURL.path]

            // Capture output/errors for debugging
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                let outputString = String(data: outputData, encoding: .utf8) ?? "No output"
                print("📦 Unzip output: \(outputString)")

                if process.terminationStatus != 0 {
                    print("📦❌ Unzip failed with status \(process.terminationStatus): \(outputString)")
                    throw NSError(domain: "ModelManager", code: 4, userInfo: [
                        NSLocalizedDescriptionKey: "Unzip failed: \(outputString) (Status: \(process.terminationStatus))"
                    ])
                }
                
                // Extract the unzipped directory name from the output
                let unzippedDirName = (sourceURL.lastPathComponent as NSString).deletingPathExtension
                let unzippedDirPath = destinationDirectoryURL.appendingPathComponent(unzippedDirName).path
                
                // Verify the directory was created
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: unzippedDirPath, isDirectory: &isDir) && isDir.boolValue {
                    print("📦✅ Successfully unzipped to directory: \(unzippedDirPath)")
                } else {
                    print("📦⚠️ Warning: expected unzipped directory not found at \(unzippedDirPath)")
                    // We'll continue anyway since the files might be extracted directly to the destination
                }
            } catch {
                print("📦❌ Error running unzip process: \(error)")
                throw error // Re-throw the error
            }
        }.value
    }

    // MARK: - File Deletion Logic

    private func deleteFile(at url: URL) {
        do {
            try fileManager.removeItem(at: url)
            print("Deleted file: \(url.path)")
        } catch {
            // Log error but don't necessarily fail the whole operation if cleanup fails
            print("Warning: Could not delete file \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Get Model Paths

    private func getPaths(for model: Model, directory: URL) -> (binPath: URL, encoderDir: URL)? {
        var binPath: URL?
        var encoderDir: URL?

        for fileInfo in model.files {
            let localURL = directory.appendingPathComponent(fileInfo.filename)
            let localUserURL = userModelsDirectory?.appendingPathComponent(fileInfo.filename)

            if fileInfo.type == "bin" {
                var fileExists = fileManager.fileExists(atPath: localURL.path)
                if !fileExists, let userURL = localUserURL {
                    fileExists = fileManager.fileExists(atPath: userURL.path)
                    if fileExists { binPath = userURL }
                }

                do {
                    let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                    _ = resourceValues
                } catch {
                    // Ignore detailed resource errors here
                }

                if fileExists {
                    do {
                        let actualURL = (binPath ?? localURL)
                        let fileHandle = try FileHandle(forReadingFrom: actualURL)
                        let header = try fileHandle.read(upToCount: 16)
                        try fileHandle.close()

                        if header != nil && !header!.isEmpty {
                            binPath = actualURL
                        }
                    } catch {
                        return nil
                    }
                } else {
                    let baseName = (localURL.lastPathComponent as NSString).deletingPathExtension
                    do {
                        let directoryContents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        for item in directoryContents where item.lastPathComponent.contains(baseName) {
                            binPath = item
                            break
                        }
                        if binPath == nil, let userDir = userModelsDirectory {
                            let directoryContentsUser = try fileManager.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)
                            for item in directoryContentsUser where item.lastPathComponent.contains(baseName) {
                                binPath = item
                                break
                            }
                        }
                    } catch {
                        // Ignore directory listing errors here
                    }

                    if binPath == nil {
                        return nil
                    }
                }
            } else if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                let unzippedURL = directory.appendingPathComponent(unzippedName)
                let unzippedUserURL = userModelsDirectory?.appendingPathComponent(unzippedName)
                var isDirectory: ObjCBool = false

                if fileManager.fileExists(atPath: unzippedURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: unzippedURL.path)
                        if !contents.isEmpty {
                            encoderDir = unzippedURL
                        }
                    } catch {
                        // Ignore listing errors; we'll fall back below
                    }
                } else if let unzippedUserURL {
                    var isDirUser: ObjCBool = false
                    if fileManager.fileExists(atPath: unzippedUserURL.path, isDirectory: &isDirUser) && isDirUser.boolValue {
                        do {
                            let contents = try fileManager.contentsOfDirectory(atPath: unzippedUserURL.path)
                            if !contents.isEmpty {
                                encoderDir = unzippedUserURL
                            }
                        } catch {
                            // ignore
                        }
                    }
                }

                if encoderDir == nil {
                    do {
                        let directoryContents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                        for item in directoryContents {
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                                if item.lastPathComponent.contains("encoder") || item.lastPathComponent.contains("mlmodelc") {
                                    encoderDir = item
                                    break
                                }
                            }
                        }
                        if encoderDir == nil, let userDir = userModelsDirectory {
                            let directoryContentsUser = try fileManager.contentsOfDirectory(at: userDir, includingPropertiesForKeys: [.isDirectoryKey])
                            for item in directoryContentsUser {
                                var isDir: ObjCBool = false
                                if fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                                    if item.lastPathComponent.contains("encoder") || item.lastPathComponent.contains("mlmodelc") {
                                        encoderDir = item
                                        break
                                    }
                                }
                            }
                        }
                    } catch {
                        // Ignore listing errors here
                    }

                    if encoderDir == nil {
                        return nil
                    }
                }
            } else if fileInfo.type == "mlmodelc" {
                let mlDir = directory.appendingPathComponent(fileInfo.filename)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: mlDir.path, isDirectory: &isDir) && isDir.boolValue {
                    encoderDir = mlDir
                } else if let userDir = userModelsDirectory {
                    let userMLDir = userDir.appendingPathComponent(fileInfo.filename)
                    if fileManager.fileExists(atPath: userMLDir.path, isDirectory: &isDir) && isDir.boolValue {
                        encoderDir = userMLDir
                    }
                }
            }
        }

        // Fallback: encoder assets are optional for Whisper. If not specified, use the model directory.
        if let bin = binPath {
            if encoderDir == nil { encoderDir = directory }
            if let encoder = encoderDir { return (bin, encoder) }
        }
        return nil
    }

    func getPathsForSelectedModel() -> (binPath: URL, encoderDir: URL)? {
        guard let selectedID = selectedModelID,
              let model = availableModels.first(where: { $0.id == selectedID }),
              let modelsDir = modelsDirectory else {
            return nil
        }

        return getPaths(for: model, directory: modelsDir)
    }
}
