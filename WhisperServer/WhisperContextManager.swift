import Foundation
import Darwin
import whisper

/// Small deterministic state machine for the shared Whisper context lifecycle.
/// Kept separate from timers and whisper.cpp calls so lifecycle behavior can be unit tested.
struct WhisperContextLifecycleState {
    private(set) var activeUseCount = 0
    private(set) var pendingFree = false

    mutating func acquire() {
        activeUseCount += 1
    }

    /// Returns true when an inactivity timeout may release the shared context now.
    func canReleaseForInactivity() -> Bool {
        activeUseCount == 0
    }

    /// Requests a model reinitialization.
    /// - Returns: true if the context may be freed immediately; false if freeing must be deferred.
    mutating func requestReinitialization() -> Bool {
        guard activeUseCount > 0 else {
            return true
        }

        pendingFree = true
        return false
    }

    /// Releases one active lease.
    /// - Returns: true when the final lease should perform a previously deferred free.
    mutating func release() -> Bool {
        guard activeUseCount > 0 else {
            return false
        }

        activeUseCount -= 1
        guard activeUseCount == 0, pendingFree else {
            return false
        }

        pendingFree = false
        return true
    }
}

/// Manages Whisper context lifecycle, memory usage, and Metal shader caching
class WhisperContextManager {
    
    // MARK: - Properties
    
    /// Shared context and lock for thread-safe access
    private static var sharedContext: OpaquePointer?
    private static let lock = NSLock()
    private static var lifecycleState = WhisperContextLifecycleState()
    private static let logQueue = DispatchQueue(label: "com.whisperserver.whisper.log", qos: .utility)
    private static var isLoggingConfigured = false

    /// Timeout mechanism for releasing resources after inactivity
    private static var inactivityTimer: Timer?
    private static var lastActivityTime = Date()
    private static var inactivityTimeout: TimeInterval = 30.0 // Default 30 seconds
    private static let logCallback: ggml_log_callback = { level, messagePtr, _ in
        WhisperContextManager.handleLog(level: level, messagePtr: messagePtr)
    }
    
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

            // A transcription is still running on the context; freeing it now
            // would be a use-after-free. releaseContext() restarts the timer.
            guard lifecycleState.canReleaseForInactivity() else { return }

            freeSharedContextUnsafe()
        }
    }

    /// Frees the shared context. This function MUST be called from within the lock.
    private static func freeSharedContextUnsafe() {
        if let ctx = sharedContext {
            whisper_free(ctx)
            sharedContext = nil
        }
    }

    /// Acquires the shared context for a transcription operation and marks it as
    /// in use so it cannot be freed until the matching releaseContext() call.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to the Whisper context, or `nil` on failure.
    static func acquireContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        lock.lock(); defer { lock.unlock() }

        resetInactivityTimer()

        guard let context = getOrCreateContextUnsafe(modelPaths: modelPaths) else {
            return nil
        }
        lifecycleState.acquire()
        return context
    }

    /// Releases a context previously obtained via acquireContext(). Performs any
    /// free that was deferred while the context was in use and restarts the
    /// inactivity countdown from the end of the operation.
    static func releaseContext() {
        lock.lock(); defer { lock.unlock() }

        if lifecycleState.release() {
            freeSharedContextUnsafe()
        }
        resetInactivityTimer()
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
    
    /// Requests resource release on termination without invalidating an in-flight lease.
    static func cleanup() {
        reinitializeContext()
    }
    
    /// Forcibly releases and reinitializes the Whisper context when the model changes
    static func reinitializeContext() {
        lock.lock(); defer { lock.unlock() }

        // Free the current context, or defer the free if a transcription is
        // still running on it (the last releaseContext() will perform it).
        if lifecycleState.requestReinitialization() {
            freeSharedContextUnsafe()
        }

        // The context will be re-initialized on the next call to getOrCreateContext

        // Reset the inactivity timer
        DispatchQueue.main.async {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
        }
    }
    
    /// Requests a context reset while respecting active leases and acquiring the manager lock.
    static func resetContextForChunk() {
        reinitializeContext()
    }
    
    /// Creates an isolated Whisper context for chunk processing that doesn't interfere with shared context
    /// This function MUST be called from within a lock.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to a new isolated Whisper context, or `nil` on failure.
    static func createIsolatedContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
        guard let paths = modelPaths else {
            return nil
        }

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

        configureLoggingIfNeeded()

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
        configureLoggingIfNeeded()
        
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

    private static func configureLoggingIfNeeded() {
        guard !isLoggingConfigured else { return }
        whisper_log_set(logCallback, nil)
        isLoggingConfigured = true
    }

    private static func handleLog(level: ggml_log_level, messagePtr: UnsafePointer<CChar>?) {
        guard let messagePtr else { return }
        let rawMessage = String(cString: messagePtr)
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        let prefix: String
        switch level.rawValue {
        case GGML_LOG_LEVEL_ERROR.rawValue:
            prefix = "❌"
        case GGML_LOG_LEVEL_WARN.rawValue:
            prefix = "⚠️"
        case GGML_LOG_LEVEL_INFO.rawValue:
            prefix = "ℹ️"
        default:
            prefix = "➖"
        }

        logQueue.async {
            print("\(prefix) whisper.cpp: \(message)")
        }
    }

}
