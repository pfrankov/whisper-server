import Foundation
import Combine // For status updates later

/// Protocol for providing model paths, allowing different implementations
protocol ModelPathProvider {
    /// Returns the paths to model files or nil if unavailable
    func getModelPaths() -> (binPath: URL, encoderDir: URL)?
}

// MARK: - Data Structures

struct ModelFile: Codable, Hashable {
    let filename: String
    let url: String
    let type: String // "bin" or "zip"
}

struct Model: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let files: [ModelFile]
}

// MARK: - ModelManager Class

final class ModelManager: @unchecked Sendable, ModelPathProvider {

    // MARK: - Properties

    @Published private(set) var availableModels: [Model] = []
    @Published private(set) var selectedModelID: String? {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID")
            // Trigger notification when selection changes
            NotificationCenter.default.post(name: NSNotification.Name("ModelManagerDidUpdate"), object: self)
            print("Selected model changed to: \(selectedModelID ?? "None")")
            checkAndPrepareSelectedModel() // Check/download when selection changes
        }
    }
    
    /// Имя выбранной модели, для отображения в интерфейсе и логирования
    var selectedModelName: String? {
        guard let modelID = selectedModelID else { return nil }
        return availableModels.first(where: { $0.id == modelID })?.name
    }
    
    @Published private(set) var currentStatus: String = "Initializing..." {
        didSet {
            // Post notification when status changes
            NotificationCenter.default.post(name: NSNotification.Name("ModelManagerStatusChanged"), object: self)
        }
    }
    @Published private(set) var downloadProgress: Double? = nil { // Optional progress (0.0 to 1.0)
        didSet {
            // Post notification when download progress changes
            NotificationCenter.default.post(name: NSNotification.Name("ModelManagerProgressChanged"), object: self)
        }
    }
    
    /// Flag to indicate if model is ready for use
    @Published private(set) var isModelReady: Bool = false
    
    /// Flag to prevent duplicate model preparation calls
    private var isPreparingModel: Bool = false

    private let fileManager = FileManager.default
    private var modelsDirectory: URL?
    private var currentDownloadTasks: [URLSessionDownloadTask] = []
    private var urlSession: URLSession!
    private var progressObservation: NSKeyValueObservation?

    // MARK: - ModelPathProvider Protocol Implementation
    
    /// Returns the paths to model files for the selected model
    func getModelPaths() -> (binPath: URL, encoderDir: URL)? {
        return getPathsForSelectedModel()
    }

    // MARK: - Initialization

    init() {
        // Initialize URLSession for downloads
        let configuration = URLSessionConfiguration.default
        // Allow downloads over cellular if needed (optional)
        // configuration.allowsCellularAccess = true
        self.urlSession = URLSession(configuration: configuration, delegate: nil, delegateQueue: OperationQueue()) // Use background queue

        setupModelsDirectory()
        loadModelDefinitions()
        // Load saved selection or default to first model
        selectedModelID = UserDefaults.standard.string(forKey: "selectedModelID") ?? availableModels.first?.id
        print("Initial selected model ID: \(selectedModelID ?? "None")")
        // Post notification after initialization
        NotificationCenter.default.post(name: NSNotification.Name("ModelManagerDidUpdate"), object: self)
        checkAndPrepareSelectedModel() // Check/download on initial load
    }

    // MARK: - Public Methods

    func selectModel(id: String) {
        guard availableModels.contains(where: { $0.id == id }) else {
            print("Error: Attempted to select unknown model ID: \(id)")
            return
        }
        selectedModelID = id
    }

    // MARK: - Private Setup & Loading

    private func setupModelsDirectory() {
        guard let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            print("Error: Could not find Application Support directory.")
            currentStatus = "Error: Cannot access Application Support"
            return
        }
        // Use Bundle Identifier to create a unique subdirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "WhisperServer"
        modelsDirectory = appSupportURL.appendingPathComponent(bundleID).appendingPathComponent("Models")

        guard let modelsDirectory = modelsDirectory else { return }

        do {
            try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true, attributes: nil)
            print("Models directory ensured at: \(modelsDirectory.path)")
        } catch {
            print("Error creating models directory: \(error)")
            currentStatus = "Error: Cannot create models directory"
            self.modelsDirectory = nil // Prevent further operations if directory failed
        }
    }

    private func loadModelDefinitions() {
        guard let url = Bundle.main.url(forResource: "Models", withExtension: "json") else {
            print("Error: Models.json not found in bundle.")
            currentStatus = "Error: Models.json missing"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            availableModels = try JSONDecoder().decode([Model].self, from: data)
            print("Loaded \(availableModels.count) model definitions.")
            currentStatus = "Ready" // Initial status after loading JSON
        } catch {
            print("Error loading or decoding Models.json: \(error)")
            currentStatus = "Error: Invalid Models.json"
            availableModels = []
        }
    }

    // MARK: - Model Preparation (Checking & Downloading) - To be implemented

    func checkAndPrepareSelectedModel() {
        guard let selectedID = selectedModelID,
              let model = availableModels.first(where: { $0.id == selectedID }),
              let modelsDir = modelsDirectory else {
            currentStatus = selectedModelID == nil ? "No model selected" : "Error: Cannot prepare model"
            print("Cannot prepare model - missing selection, definition, or directory.")
            isModelReady = false
            NotificationCenter.default.post(name: NSNotification.Name("ModelPreparationFailed"), object: self)
            return
        }

        // Prevent duplicate calls
        if isPreparingModel {
            print("⏳ Model preparation already in progress for \(model.name), skipping duplicate call")
            return
        }
        
        isPreparingModel = true
        currentStatus = "Checking model: \(model.name)"
        print("Checking files for model: \(model.name)")
        isModelReady = false

        Task { // Use Task for async operations
            do {
                let filesExist = try await checkModelFilesExist(model: model, directory: modelsDir)

                if filesExist {
                    currentStatus = "Model '\(model.name)' is ready."
                    print("All files for model \(model.name) exist locally.")
                    isModelReady = true
                    isPreparingModel = false // Reset flag
                    NotificationCenter.default.post(name: NSNotification.Name("ModelIsReady"), object: self)
                } else {
                    currentStatus = "Downloading model: \(model.name)..."
                    print("Need to download files for model \(model.name)")
                    // Clear any previous progress
                    self.downloadProgress = 0.0
                    try await downloadAndPrepareModel(model: model, directory: modelsDir)
                    // After successful download, model is ready
                    isModelReady = true
                    isPreparingModel = false // Reset flag
                    NotificationCenter.default.post(name: NSNotification.Name("ModelIsReady"), object: self)
                }
            } catch {
                currentStatus = "Error checking model files: \(error.localizedDescription)"
                print("Error checking model files: \(error)")
                isModelReady = false
                isPreparingModel = false // Reset flag on error
                NotificationCenter.default.post(name: NSNotification.Name("ModelPreparationFailed"), object: self)
            }
        }
    }

    private func checkModelFilesExist(model: Model, directory: URL) async throws -> Bool {
        for fileInfo in model.files {
            let localURL = directory.appendingPathComponent(fileInfo.filename)
            var isDirectory: ObjCBool = false

            // If it's a zip, we check for the expected *unzipped* directory name.
            // Assuming unzipped name is the zip filename without .zip
            if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                let unzippedURL = directory.appendingPathComponent(unzippedName)
                 if !(fileManager.fileExists(atPath: unzippedURL.path, isDirectory: &isDirectory) && isDirectory.boolValue) {
                    print("Missing unzipped directory: \(unzippedURL.path)")
                    return false
                }
            } else { // For .bin files, check the file itself
                if !fileManager.fileExists(atPath: localURL.path, isDirectory: &isDirectory) || isDirectory.boolValue {
                     print("Missing file: \(localURL.path)")
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

            // Always redownload for a clean start
            needsDownload = true
            
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
             NotificationCenter.default.post(name: NSNotification.Name("ModelIsReady"), object: self)
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
    
    func getPathsForSelectedModel() -> (binPath: URL, encoderDir: URL)? {
        guard let selectedID = selectedModelID else {
            print("📋 Model Manager: No model selected")
            return nil
        }
        
        guard let model = availableModels.first(where: { $0.id == selectedID }) else {
            print("📋 Model Manager: Selected model ID '\(selectedID)' not found in available models")
            return nil
        }
        
        guard let modelsDir = modelsDirectory else {
            print("📋 Model Manager: Models directory not available")
            return nil
        }
        
        print("📋 Model Manager: Getting paths for selected model: \(model.name) (ID: \(model.id))")
        print("📋 Model Manager: Models directory: \(modelsDir.path)")

        var binPath: URL?
        var encoderDir: URL?

        for fileInfo in model.files {
            let localURL = modelsDir.appendingPathComponent(fileInfo.filename)
            print("📋 Model Manager: Checking file: \(fileInfo.filename) (type: \(fileInfo.type))")
            
            if fileInfo.type == "bin" {
                // First try a more direct approach to check if the file exists
                let fileExists = fileManager.fileExists(atPath: localURL.path)
                print("📋 Model Manager: File exists check: \(fileExists)")
                
                // Get more detailed information
                do {
                    let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                    print("📋 Model Manager: Is directory: \(resourceValues.isDirectory ?? false)")
                    print("📋 Model Manager: Is regular file: \(resourceValues.isRegularFile ?? false)")
                    if let fileSize = resourceValues.fileSize {
                        print("📋 Model Manager: File size: \(fileSize) bytes")
                    }
                } catch {
                    print("📋 Model Manager: Error getting resource values: \(error)")
                }
                
                if fileExists {
                    // Additional verification that it's a valid model file
                    do {
                        let fileHandle = try FileHandle(forReadingFrom: localURL)
                        // Just check if we can read the first few bytes
                        let header = try fileHandle.read(upToCount: 16)
                        try fileHandle.close()
                        
                        if header != nil && !header!.isEmpty {
                            print("📋 Model Manager: Successfully read file header")
                            binPath = localURL
                        } else {
                            print("📋 Model Manager: Warning - File exists but couldn't read header")
                        }
                    } catch {
                        print("📋 Model Manager: Error verifying bin file: \(error)")
                        
                        // If we can't verify the file, let's see what's actually at this path
                        let enumerator = fileManager.enumerator(atPath: modelsDir.path)
                        print("📋 Model Manager: Contents of models directory:")
                        while let element = enumerator?.nextObject() as? String {
                            print("📋 Model Manager: - \(element)")
                        }
                        
                        return nil
                    }
                } else {
                    // Try to find a matching file with a different extension - perhaps it downloaded incorrectly
                    let baseName = (localURL.lastPathComponent as NSString).deletingPathExtension
                    do {
                        let directoryContents = try fileManager.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: nil)
                        for item in directoryContents {
                            if item.lastPathComponent.contains(baseName) {
                                print("📋 Model Manager: Found alternative file: \(item.path)")
                                binPath = item
                                break
                            }
                        }
                    } catch {
                        print("📋 Model Manager: Error listing directory: \(error)")
                    }
                    
                    if binPath == nil {
                        print("📋 Model Manager: Error - Expected bin file not found at: \(localURL.path)")
                        return nil
                    }
                }
            } else if fileInfo.type == "zip" {
                let unzippedName = (fileInfo.filename as NSString).deletingPathExtension
                let unzippedURL = modelsDir.appendingPathComponent(unzippedName)
                var isDirectory: ObjCBool = false
                
                if fileManager.fileExists(atPath: unzippedURL.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                    print("📋 Model Manager: Found encoder directory at: \(unzippedURL.path)")
                    
                    // Additional verification - check if it has content
                    do {
                        let contents = try fileManager.contentsOfDirectory(atPath: unzippedURL.path)
                        print("📋 Model Manager: Encoder directory contains \(contents.count) items")
                        if !contents.isEmpty {
                            encoderDir = unzippedURL
                        } else {
                            print("📋 Model Manager: Warning - Directory is empty")
                        }
                    } catch {
                        print("📋 Model Manager: Warning - Failed to list directory contents: \(error)")
                    }
                } else {
                    // Check if the directory might be at a different location
                    do {
                        let directoryContents = try fileManager.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.isDirectoryKey])
                        for item in directoryContents {
                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: item.path, isDirectory: &isDir) && isDir.boolValue {
                                if item.lastPathComponent.contains("encoder") || item.lastPathComponent.contains("mlmodelc") {
                                    print("📋 Model Manager: Found potential encoder directory at: \(item.path)")
                                    encoderDir = item
                                    break
                                }
                            }
                        }
                    } catch {
                        print("📋 Model Manager: Error listing directory for encoder dir: \(error)")
                    }
                    
                    if encoderDir == nil {
                        print("📋 Model Manager: Error - Expected unzipped encoder directory not found at: \(unzippedURL.path)")
                        return nil
                    }
                }
            }
        }

        // Ensure both paths were found
        if binPath == nil {
            print("📋 Model Manager: Error - Bin path not found for model \(model.id)")
            return nil
        }
        
        if encoderDir == nil {
            print("📋 Model Manager: Error - Encoder directory not found for model \(model.id)")
            return nil
        }
        
        guard let binPathValue = binPath, let encoderDirValue = encoderDir else {
            print("📋 Model Manager: Error - Could not find both required paths for model \(model.id)")
            return nil
        }

        print("📋 Model Manager: Successfully found model paths:")
        print("📋 Model Manager: - Bin path: \(binPathValue.path)")
        print("📋 Model Manager: - Encoder dir: \(encoderDirValue.path)")
        return (binPathValue, encoderDirValue)
    }
} 