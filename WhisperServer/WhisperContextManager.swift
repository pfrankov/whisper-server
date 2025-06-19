import Foundation
import whisper
#if os(macOS) || os(iOS)
import AppKit
#endif

/// Manages Whisper context lifecycle, memory usage, and Metal shader caching
class WhisperContextManager {
    
    // MARK: - Properties
    
    /// Shared context and lock for thread-safe access
    private static var sharedContext: OpaquePointer?
    private static let lock = NSLock()
    
    /// Timeout mechanism for releasing resources after inactivity
    private static var inactivityTimer: Timer?
    private static var lastActivityTime = Date()
    private static var inactivityTimeout: TimeInterval = 30.0 // Default 30 seconds
    
    /// Notification name for when Metal is activated
    static let metalActivatedNotificationName = NSNotification.Name("WhisperMetalActivated")
    
    // MARK: - Context Management
    
    /// Sets the inactivity timeout in seconds
    /// - Parameter seconds: Number of seconds of inactivity before resources are released
    static func setInactivityTimeout(seconds: TimeInterval) {
        inactivityTimeout = max(5.0, seconds) // Minimum 5 seconds
        print("🕒 Whisper inactivity timeout set to \(Int(inactivityTimeout)) seconds")
        
        // Reset the timer with the new timeout if it's active
        if inactivityTimer != nil {
            resetInactivityTimer()
        }
    }
    
    /// Resets the inactivity timer
    private static func resetInactivityTimer() {
        DispatchQueue.main.async {
            // Invalidate existing timer
            inactivityTimer?.invalidate()
            
            // Update last activity time
            lastActivityTime = Date()
            
            // Create new timer
            inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityTimeout, repeats: false) { _ in
                checkAndReleaseResources()
            }
        }
    }
    
    /// Checks if timeout has elapsed and releases resources if needed
    private static func checkAndReleaseResources() {
        let currentTime = Date()
        let elapsedTime = currentTime.timeIntervalSince(lastActivityTime)
        
        if elapsedTime >= inactivityTimeout {
            print("🕒 Inactivity timeout (\(Int(inactivityTimeout))s) reached - releasing Whisper resources")
            lock.lock(); defer { lock.unlock() }
            
            if let ctx = sharedContext {
                let memoryBefore = getMemoryUsage()
                whisper_free(ctx)
                sharedContext = nil
                let memoryAfter = getMemoryUsage()
                let freed = max(0, memoryBefore - memoryAfter)
                print("🧹 Whisper context released due to inactivity, freed ~\(freed) MB")
            }
        }
    }
    
    /// Gets approximate memory usage (in MB) for logging
    private static func getMemoryUsage() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS else {
            return 0
        }
        
        // Convert bytes to MB (more precise calculation)
        let bytesInMB = Double(1024 * 1024)
        return Int(Double(info.resident_size) / bytesInMB)
    }
    
    /// Configures a persistent Metal shader cache
    private static func setupMetalShaderCache() {
        #if os(macOS) || os(iOS)
        // Directory for storing the Metal shader cache
        var cacheDirectory: URL
        
        // Create path to cache folder in Application Support
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "com.whisperserver"
            let whisperCacheDir = appSupportDir.appendingPathComponent(bundleId).appendingPathComponent("MetalCache")
            
            // Create the directory if it doesn't exist
            do {
                try FileManager.default.createDirectory(at: whisperCacheDir, withIntermediateDirectories: true)
                cacheDirectory = whisperCacheDir
                print("✅ Set Metal shader cache directory: \(whisperCacheDir.path)")
                
                // Check if cache already exists
                let fileManager = FileManager.default
                let cacheFolderContents = try? fileManager.contentsOfDirectory(at: whisperCacheDir, includingPropertiesForKeys: nil)
                if let contents = cacheFolderContents, !contents.isEmpty {
                    print("📋 Found existing Metal cache with \(contents.count) files")
                }
            } catch {
                print("⚠️ Failed to create Metal cache directory: \(error.localizedDescription)")
                // Use temporary directory as a fallback
                cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperMetalCache")
            }
            
            // Set environment variables for Metal
            setenv("MTL_SHADER_CACHE_PATH", cacheDirectory.path, 1)
            setenv("MTL_SHADER_CACHE", "1", 1)
            setenv("MTL_SHADER_CACHE_SKIP_VALIDATION", "1", 1)
            
            // Additional settings for cache debugging
            #if DEBUG
            setenv("MTL_DEBUG_SHADER_CACHE", "1", 1)
            #endif
        }
        #endif
    }
    
    /// Frees resources on application termination
    static func cleanup() {
        DispatchQueue.main.async {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
        }
        
        lock.lock(); defer { lock.unlock() }
        if let ctx = sharedContext {
            let memoryBefore = getMemoryUsage()
            whisper_free(ctx)
            sharedContext = nil
            let memoryAfter = getMemoryUsage()
            let freed = max(0, memoryBefore - memoryAfter)
            print("🧹 Whisper context released during app termination, freed ~\(freed) MB")
        }
    }
    
    /// Forcibly releases and reinitializes the Whisper context when the model changes
    static func reinitializeContext() {
        lock.lock(); defer { lock.unlock() }

        // First, free the current context if it exists
        if let ctx = sharedContext {
            let memoryBefore = getMemoryUsage()
            whisper_free(ctx)
            sharedContext = nil
            let memoryAfter = getMemoryUsage()
            let freed = max(0, memoryBefore - memoryAfter)
            print("🔄 Whisper context released for model change, freed ~\(freed) MB")
        }

        // The context will be re-initialized on the next call to getOrCreateContext
        print("✅ Context will be reinitialized on next use with new model")
        
        // Reset the inactivity timer
        DispatchQueue.main.async {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
        }
    }
    
    /// Forces release of the current Whisper context for memory isolation between chunks
    /// This function MUST be called from within a lock.
    static func resetContextForChunk() {
        // Release current context if it exists
        if let ctx = sharedContext {
            let memoryBefore = getMemoryUsage()
            whisper_free(ctx)
            sharedContext = nil
            let memoryAfter = getMemoryUsage()
            let freed = max(0, memoryBefore - memoryAfter)
            print("🔄 Whisper context reset between chunks, freed ~\(freed) MB")
        }
    }
    
    /// Creates an isolated Whisper context for chunk processing that doesn't interfere with shared context
    /// This function MUST be called from within a lock.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to a new isolated Whisper context, or `nil` on failure.
    static func createIsolatedContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        guard let paths = modelPaths else {
            print("❌ Cannot create isolated context: Model paths are not provided.")
            return nil
        }

        let memoryBefore = getMemoryUsage()

        #if os(macOS) || os(iOS)
        setupMetalShaderCache()
        #endif

        let binPath = paths.binPath
        print("🔄 Creating isolated Whisper context from: \(binPath.lastPathComponent)")

        // Verify file exists and can be accessed
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: binPath.path),
              fileManager.isReadableFile(atPath: binPath.path) else {
            print("❌ Model file doesn't exist or isn't readable at: \(binPath.path)")
            return nil
        }

        var contextParams = whisper_context_default_params()

        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        // Additional Metal optimizations
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Optimization for batch size
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Allocate more memory for Metal
        #endif

        guard let isolatedContext = whisper_init_from_file_with_params(binPath.path, contextParams) else {
            print("❌ Failed to create isolated Whisper context from file.")
            return nil
        }

        let memoryAfter = getMemoryUsage()
        let used = max(0, memoryAfter - memoryBefore)
        print("✅ Isolated Whisper context created, using ~\(used) MB")

        return isolatedContext
    }
    
    /// Performs context check and initialization without performing transcription
    /// - Returns: True if initialization was successful
    static func preloadModelForShaderCaching(modelPaths: (binPath: URL, encoderDir: URL)?) -> Bool {
        guard let paths = modelPaths else {
            print("❌ Failed to get model paths for preloading")
            return false
        }

        print("🔄 Preloading Whisper model for shader caching")
        
        // Use the unified getOrCreateContext method
        if getOrCreateContext(modelPaths: paths) != nil {
            print("✅ Preloading successful, context is ready.")
            return true
        } else {
            print("❌ Preloading failed.")
            return false
        }
    }
    
    /// Initializes or retrieves the Whisper context with activity tracking
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to the Whisper context, or `nil` on failure.
    static func getOrCreateContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        lock.lock(); defer { lock.unlock() }
        
        // Reset the inactivity timer since we're using Whisper now
        resetInactivityTimer()
        
        return getOrCreateContextUnsafe(modelPaths: modelPaths)
    }
    
    /// Initializes or retrieves the Whisper context. This function MUST be called from within a lock.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to the Whisper context, or `nil` on failure.
    static func getOrCreateContextUnsafe(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        // If context already exists, we're done.
        if let existingContext = sharedContext {
            print("✅ Reusing existing Whisper context.")
            return existingContext
        }

        // If no context, we must create one. We need model paths.
        print("🔄 No existing context. Initializing new Whisper context.")
        guard let paths = modelPaths else {
            print("❌ Cannot initialize context: Model paths are not provided.")
            return nil
        }

        let memoryBefore = getMemoryUsage()

        #if os(macOS) || os(iOS)
        setupMetalShaderCache()
        #endif

        let binPath = paths.binPath
        print("📂 Using model file at: \(binPath.path)")

        // Verify file exists and can be accessed
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: binPath.path),
              fileManager.isReadableFile(atPath: binPath.path) else {
            print("❌ Model file doesn't exist or isn't readable at: \(binPath.path)")
            return nil
        }

        // Log file size for debugging
        do {
            let attributes = try fileManager.attributesOfItem(atPath: binPath.path)
            if let fileSize = attributes[.size] as? UInt64 {
                print("📄 File size: \(fileSize) bytes")
            } else {
                print("📄 File size: unknown")
            }
        } catch {
            print("📄 File size: could not be determined - \(error.localizedDescription)")
        }

        var contextParams = whisper_context_default_params()

        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        // Additional Metal optimizations
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Optimization for batch size
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Allocate more memory for Metal
        print("🔧 Metal settings: NDIM=128, MEM_MB=1024")
        #endif

        print("🔄 Initializing Whisper context from file...")
        guard let newContext = whisper_init_from_file_with_params(binPath.path, contextParams) else {
            print("❌ Failed to initialize Whisper context from file.")
            return nil
        }

        sharedContext = newContext
        let memoryAfter = getMemoryUsage()
        let used = max(0, memoryAfter - memoryBefore)
        print("✅ New Whisper context initialized, using ~\(used) MB")
        
        // Send notification that Metal is active
        DispatchQueue.main.async {
            let modelName = extractModelNameFromPath(paths.binPath)
            NotificationCenter.default.post(
                name: metalActivatedNotificationName,
                object: nil,
                userInfo: ["modelName": modelName ?? "Unknown"]
            )
        }

        return newContext
    }
    
    /// Extracts model name from URL path for better logging
    private static func extractModelNameFromPath(_ path: URL?) -> String? {
        guard let path = path else { return nil }
        
        let filename = path.lastPathComponent
        let modelPatterns = ["tiny", "base", "small", "medium", "large"]
        
        for pattern in modelPatterns {
            if filename.lowercased().contains(pattern) {
                return pattern.capitalized
            }
        }
        
        return (filename as NSString).deletingPathExtension
    }
} 