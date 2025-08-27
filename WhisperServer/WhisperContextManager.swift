import Foundation
import Darwin
import whisper

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
    
    // MARK: - Context Management
    
    /// Sets the inactivity timeout in seconds
    /// - Parameter seconds: Number of seconds of inactivity before resources are released
    static func setInactivityTimeout(seconds: TimeInterval) {
        inactivityTimeout = max(5.0, seconds) // Minimum 5 seconds

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
            lock.lock(); defer { lock.unlock() }

            if let ctx = sharedContext {
                let memoryBefore = getMemoryUsage()
                whisper_free(ctx)
                sharedContext = nil
                let memoryAfter = getMemoryUsage()
                _ = max(0, memoryBefore - memoryAfter)
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
                // Directory ensured; optional cache inspection omitted
            } catch {
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
            _ = max(0, memoryBefore - memoryAfter)
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
            _ = max(0, memoryBefore - memoryAfter)
        }

        // The context will be re-initialized on the next call to getOrCreateContext

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
            _ = max(0, memoryBefore - memoryAfter)
        }
    }
    
    /// Creates an isolated Whisper context for chunk processing that doesn't interfere with shared context
    /// This function MUST be called from within a lock.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to a new isolated Whisper context, or `nil` on failure.
    static func createIsolatedContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        guard let paths = modelPaths else {
            return nil
        }

        let memoryBefore = getMemoryUsage()

        setupMetalShaderCache()

        let binPath = paths.binPath

        // Verify file exists and can be accessed
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: binPath.path),
              fileManager.isReadableFile(atPath: binPath.path) else {
            return nil
        }

        var contextParams = whisper_context_default_params()

        contextParams.use_gpu = true
        contextParams.flash_attn = true
        // Additional Metal optimizations
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Optimization for batch size
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Allocate more memory for Metal

        guard let isolatedContext = whisper_init_from_file_with_params(binPath.path, contextParams) else {
            return nil
        }

        let memoryAfter = getMemoryUsage()
        let used = max(0, memoryAfter - memoryBefore)
        _ = used

        return isolatedContext
    }
    
    /// Performs context check and initialization without performing transcription
    /// - Returns: True if initialization was successful
    static func preloadModelForShaderCaching(modelPaths: (binPath: URL, encoderDir: URL)?) -> Bool {
        guard let paths = modelPaths else {
            return false
        }

        // Use the unified getOrCreateContext method
        if getOrCreateContext(modelPaths: paths) != nil {
            return true
        } else {
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
            return existingContext
        }

        // If no context, we must create one. We need model paths.
        guard let paths = modelPaths else {
            return nil
        }

        let memoryBefore = getMemoryUsage()

        setupMetalShaderCache()

        let binPath = paths.binPath

        // Verify file exists and can be accessed
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: binPath.path),
              fileManager.isReadableFile(atPath: binPath.path) else {
            return nil
        }

        // Log file size for debugging
        _ = fileManager

        var contextParams = whisper_context_default_params()

        contextParams.use_gpu = true
        contextParams.flash_attn = true
        // Additional Metal optimizations
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Optimization for batch size
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Allocate more memory for Metal
        // Metal settings configured via env vars

        guard let newContext = whisper_init_from_file_with_params(binPath.path, contextParams) else {
            return nil
        }

        sharedContext = newContext
        let memoryAfter = getMemoryUsage()
        let used = max(0, memoryAfter - memoryBefore)
        _ = used
        
        // Send notification that Metal is active
        DispatchQueue.main.async {
            let modelName = extractModelNameFromPath(paths.binPath)
            NotificationCenter.default.post(
                name: .whisperMetalActivated,
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
