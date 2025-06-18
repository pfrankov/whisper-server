import Foundation
import whisper
#if os(macOS) || os(iOS)
import SwiftUI
import AVFoundation
import Darwin
#endif

/// Audio transcription service using whisper.cpp
struct WhisperTranscriptionService {
    // MARK: - Constants
    
    /// Notification name for when Metal is activated
    static let metalActivatedNotificationName = NSNotification.Name("WhisperMetalActivated")
    
    /// Maximum chunk duration in seconds (5 minutes)
    public static var maxChunkDuration: Double = 30 // 5 minutes by default
    
    /// Overlap between chunks in seconds to avoid cutting words
    public static var chunkOverlap: Double = 0 // 5 seconds by default
    
    /// Whether to reset Whisper context between chunks for memory isolation
    /// When true: Each chunk gets a completely isolated context (prevents state interference, uses more memory)
    /// When false: All chunks share the same context (faster, uses less memory, but may have state interference)
    public static var resetContextBetweenChunks: Bool = false
    
    // MARK: - Subtitle Data Structures
    
    /// Represents a segment of transcription with timing information
    struct TranscriptionSegment {
        let startTime: Double    // Start time in seconds
        let endTime: Double      // End time in seconds
        let text: String         // Transcribed text
    }
    
    /// Response formats for transcription
    enum ResponseFormat: String, CaseIterable {
        case json = "json"
        case text = "text"
        case verboseJson = "verbose_json"
        case srt = "srt"
        case vtt = "vtt"
    }
    
    // MARK: - Subtitle Formatting Functions
    
    /// Formats timestamps for SRT format (HH:MM:SS,mmm)
    static func formatSRTTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, milliseconds)
    }
    
    /// Formats timestamps for VTT format (HH:MM:SS.mmm)
    static func formatVTTTimestamp(_ seconds: Double) -> String {
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
    }
    
    /// Formats segments as SRT subtitles
    static func formatAsSRT(segments: [TranscriptionSegment]) -> String {
        var srtString = ""
        
        for (index, segment) in segments.enumerated() {
            let startTime = formatSRTTimestamp(segment.startTime)
            let endTime = formatSRTTimestamp(segment.endTime)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty segments
            if !text.isEmpty {
                srtString += "\(index + 1)\n"
                srtString += "\(startTime) --> \(endTime)\n"
                srtString += "\(text)\n\n"
            }
        }
        
        return srtString
    }
    
    /// Formats segments as WebVTT subtitles
    static func formatAsVTT(segments: [TranscriptionSegment]) -> String {
        var vttString = "WEBVTT\n\n"
        
        for segment in segments {
            let startTime = formatVTTTimestamp(segment.startTime)
            let endTime = formatVTTTimestamp(segment.endTime)
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty segments
            if !text.isEmpty {
                vttString += "\(startTime) --> \(endTime)\n"
                vttString += "\(text)\n\n"
            }
        }
        
        return vttString
    }
    
    /// Formats segments as verbose JSON (OpenAI Whisper API compatible)
    static func formatAsVerboseJSON(segments: [TranscriptionSegment]) -> String {
        let fullTranscription = segments.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        
        let segmentDicts = segments.compactMap { segment -> [String: Any]? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            
            return [
                "start": segment.startTime,
                "end": segment.endTime,
                "text": text
            ]
        }
        
        let responseDict: [String: Any] = [
            "text": fullTranscription,
            "segments": segmentDicts
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            return jsonString
        } else {
            // Fallback to simple JSON
            return "{\"text\": \"\(fullTranscription)\", \"error\": \"Failed to format verbose JSON\"}"
        }
    }
    
    // MARK: - Audio Conversion
    
    /// Handles conversion of various audio formats to 16-bit, 16kHz mono WAV required by Whisper
    class AudioConverter {
        /// Converts audio data from any supported format to the format required by Whisper
        /// - Parameter audioURL: URL of the original audio file
        /// - Returns: Converted audio data as PCM 16-bit 16kHz mono samples, or nil if conversion failed
        static func convertToWhisperFormat(from audioURL: URL) -> [Float]? {
            #if os(macOS) || os(iOS)
            return convertUsingAVFoundation(from: audioURL)
            #else
            print("❌ Audio conversion is only supported on macOS and iOS")
            return nil
            #endif
        }
        
        #if os(macOS) || os(iOS)
        /// Converts audio using AVFoundation framework - unified approach for all formats
        private static func convertUsingAVFoundation(from audioURL: URL) -> [Float]? {
            print("🔄 Converting audio to Whisper format (16kHz mono float)")
            
            // Target format: 16kHz mono float
            let targetSampleRate = 16000.0
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: targetSampleRate,
                                           channels: 1,
                                           interleaved: false)!
            
            // Try to create an AVAudioFile from the data
            guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
                print("❌ Failed to create AVAudioFile for reading from URL: \(audioURL.path)")
                return nil
            }
            
            let sourceFormat = audioFile.processingFormat
            print("🔍 Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")
            
            // Convert the audio file to the required format
            return convertAudioFile(audioFile, toFormat: outputFormat)
        }
        
        /// Converts an audio file to the specified format
        private static func convertAudioFile(_ file: AVAudioFile, toFormat outputFormat: AVAudioFormat) -> [Float]? {
            let sourceFormat = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            
            // If the file is empty, return nil
            if frameCount == 0 {
                print("❌ Audio file is empty")
                return nil
            }
            
            // Read the entire file into a buffer
                guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                print("❌ Failed to create source PCM buffer")
                return nil
            }
            
            do {
                try file.read(into: buffer)
                } catch {
                print("❌ Failed to read audio file: \(error.localizedDescription)")
                return nil
            }
            
            // If source format matches target format, just return the samples
            if abs(sourceFormat.sampleRate - outputFormat.sampleRate) < 1.0 && 
               sourceFormat.channelCount == outputFormat.channelCount {
                return extractSamplesFromBuffer(buffer)
        }
            
            // Create converter and convert
            guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
                print("❌ Failed to create audio converter")
                return nil
            }
            
            // Calculate output buffer size with some margin
            let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
            let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio * 1.1)
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
                print("❌ Failed to create output buffer")
                return nil
            }
            
            // Perform conversion
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            let status = converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            
            if status == .error || error != nil {
                print("❌ Conversion failed: \(error?.localizedDescription ?? "unknown error")")
                return nil
            }
            
            if outputBuffer.frameLength == 0 {
                print("❌ No frames were converted")
                return nil
            }
            
            print("✅ Successfully converted to \(outputBuffer.frameLength) frames at \(outputFormat.sampleRate)Hz")
            
            return extractSamplesFromBuffer(outputBuffer)
        }
        
        /// Extracts float samples from an audio buffer
        private static func extractSamplesFromBuffer(_ buffer: AVAudioPCMBuffer) -> [Float]? {
            guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
                print("❌ No valid channel data in buffer")
                return nil
            }
            
            // Extract samples from the first channel (mono)
            let data = UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength))
            return Array(data)
        }
        
        /// Creates audio chunks from the source audio file
        /// - Parameters:
        ///   - audioURL: URL of the original audio file
        ///   - maxDuration: Maximum duration of each chunk in seconds
        ///   - overlap: Overlap between chunks in seconds
        /// - Returns: Array of audio sample arrays, each representing a chunk
        static func createAudioChunks(from audioURL: URL, maxDuration: Double, overlap: Double) -> [(samples: [Float], startTime: Double, endTime: Double)]? {
            print("🔄 Creating audio chunks (max: \(Int(maxDuration))s, overlap: \(Int(overlap))s)")
            
            // Target format: 16kHz mono float
            let targetSampleRate = 16000.0
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: targetSampleRate,
                                           channels: 1,
                                           interleaved: false)!
            
            // Try to create an AVAudioFile from the data
            guard let audioFile = try? AVAudioFile(forReading: audioURL) else {
                print("❌ Failed to create AVAudioFile for reading from URL: \(audioURL.path)")
                return nil
            }
            
            let sourceFormat = audioFile.processingFormat
            let totalDuration = Double(audioFile.length) / sourceFormat.sampleRate
            
            print("🔍 Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")
            print("🔍 Total duration: \(String(format: "%.1f", totalDuration)) seconds")
            
            // If the audio is shorter than maxDuration, process as single chunk
            if totalDuration <= maxDuration {
                print("📋 Audio is short enough, processing as single chunk")
                guard let samples = convertAudioFile(audioFile, toFormat: outputFormat) else {
                    return nil
                }
                return [(samples: samples, startTime: 0.0, endTime: totalDuration)]
            }
            
            // Calculate chunks
            var chunks: [(samples: [Float], startTime: Double, endTime: Double)] = []
            var currentStart: Double = 0.0
            
            while currentStart < totalDuration {
                let currentEnd = min(currentStart + maxDuration, totalDuration)
                let actualStart = max(0.0, currentStart - (chunks.count > 0 ? overlap : 0.0))
                
                print("🔄 Processing chunk \(chunks.count + 1): \(String(format: "%.1f", actualStart))s - \(String(format: "%.1f", currentEnd))s")
                
                // Extract chunk samples
                guard let chunkSamples = extractAudioChunk(from: audioFile, 
                                                          startTime: actualStart, 
                                                          endTime: currentEnd, 
                                                          targetFormat: outputFormat) else {
                    print("❌ Failed to extract chunk at \(actualStart)s - \(currentEnd)s")
                    return nil
                }
                
                chunks.append((samples: chunkSamples, startTime: currentStart, endTime: currentEnd))
                
                // Move to next chunk
                currentStart = currentEnd
            }
            
            print("✅ Created \(chunks.count) audio chunks")
            return chunks
        }
        
        /// Extracts a specific time segment from audio file
        private static func extractAudioChunk(from audioFile: AVAudioFile, 
                                            startTime: Double, 
                                            endTime: Double, 
                                            targetFormat: AVAudioFormat) -> [Float]? {
            let sourceFormat = audioFile.processingFormat
            let startFrame = AVAudioFramePosition(startTime * sourceFormat.sampleRate)
            let endFrame = AVAudioFramePosition(endTime * sourceFormat.sampleRate)
            let frameCount = AVAudioFrameCount(endFrame - startFrame)
            
            guard frameCount > 0 else {
                print("❌ Invalid frame count: \(frameCount)")
                return nil
            }
            
            // Create buffer for the chunk
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                print("❌ Failed to create chunk buffer")
                return nil
            }
            
            // Seek to start position and read chunk
            audioFile.framePosition = startFrame
            do {
                try audioFile.read(into: buffer, frameCount: frameCount)
            } catch {
                print("❌ Failed to read audio chunk: \(error.localizedDescription)")
                return nil
            }
            
            // Convert to target format if needed
            if abs(sourceFormat.sampleRate - targetFormat.sampleRate) < 1.0 && 
               sourceFormat.channelCount == targetFormat.channelCount {
                return extractSamplesFromBuffer(buffer)
            } else {
                // Create converter for this chunk
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                    print("❌ Failed to create chunk converter")
                    return nil
                }
                
                let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
                let outputFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio * 1.1)
                
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else {
                    print("❌ Failed to create chunk output buffer")
                    return nil
                }
                
                var error: NSError?
                let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                if status == .error || error != nil {
                    print("❌ Chunk conversion failed: \(error?.localizedDescription ?? "unknown error")")
                    return nil
                }
                
                return extractSamplesFromBuffer(outputBuffer)
            }
        }
        #endif
    }

    // Shared context and lock for thread-safe access
    private static var sharedContext: OpaquePointer?
    private static let lock = NSLock()
    
    // Timeout mechanism for releasing resources after inactivity
    private static var inactivityTimer: Timer?
    private static var lastActivityTime = Date()
    private static var inactivityTimeout: TimeInterval = 30.0 // Default 30 seconds inactivity timeout
    
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
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            return Int(info.resident_size / (1024 * 1024))
        } else {
            return 0
        }
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

        // Immediately try to re-initialize with the currently selected model.
        // This avoids a "contextless" state and surfaces errors immediately.
        print("🔄 Attempting to immediately re-initialize context with new model...")
        let modelManager = ModelManager() // Create a temporary instance to get paths
        if let newModelPaths = modelManager.getModelPaths() {
            if getOrCreateContext(modelPaths: newModelPaths) != nil {
                print("✅ Successfully re-initialized context with model '\(modelManager.selectedModelName ?? "Unknown")'")
            } else {
                print("❌ Failed to re-initialize context with new model. It will be created on next request.")
            }
        } else {
            print("⚠️ Could not get new model paths to re-initialize context immediately.")
        }
        
        // Reset the inactivity timer
        DispatchQueue.main.async {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
        }
        
        // The context will be re-initialized on the next call to transcribeAudio
        // or preloadModelForShaderCaching automatically
        print("✅ Context will be reinitialized on next use with new model")
    }
    
    /// Configures context isolation behavior for chunk processing
    /// - Parameter enabled: When true, each chunk gets a completely isolated context (prevents state interference, uses more memory)
    ///                     When false, all chunks share the same context (faster, uses less memory, but may have state interference)
    static func setContextIsolationEnabled(_ enabled: Bool) {
        resetContextBetweenChunks = enabled
        print("🔧 Context isolation between chunks: \(enabled ? "ENABLED" : "DISABLED")")
        print("   - \(enabled ? "Each chunk gets isolated context (more memory, no state interference)" : "Chunks share context (less memory, potential state interference)")")
    }
    
    /// Gets the current context isolation setting
    /// - Returns: True if context isolation is enabled, false otherwise
    static func isContextIsolationEnabled() -> Bool {
        return resetContextBetweenChunks
    }
    
    /// Configures audio chunking parameters
    /// - Parameters:
    ///   - maxDuration: Maximum duration of each chunk in seconds (minimum 10 seconds)
    ///   - overlap: Overlap between chunks in seconds (minimum 0 seconds)
    static func setChunkingParameters(maxDuration: Double, overlap: Double = 0.0) {
        maxChunkDuration = max(10.0, maxDuration) // Minimum 10 seconds
        chunkOverlap = max(0.0, overlap) // Minimum 0 seconds
        print("🔧 Chunking parameters updated:")
        print("   - Max chunk duration: \(Int(maxChunkDuration)) seconds")
        print("   - Chunk overlap: \(Int(chunkOverlap)) seconds")
    }
    
    /// Gets the current chunking parameters
    /// - Returns: Tuple with max duration and overlap in seconds
    static func getChunkingParameters() -> (maxDuration: Double, overlap: Double) {
        return (maxDuration: maxChunkDuration, overlap: chunkOverlap)
    }
    
    /// Forces release of the current Whisper context for memory isolation between chunks
    /// This function MUST be called from within a lock.
    private static func resetContextForChunk() {
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
    private static func createIsolatedContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
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
    static func preloadModelForShaderCaching(modelBinPath: URL? = nil, modelEncoderDir: URL? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Get model paths either from parameters or from the model manager
        var finalModelPaths: (binPath: URL, encoderDir: URL)?
        if let binPath = modelBinPath, let encoderDir = modelEncoderDir {
            finalModelPaths = (binPath, encoderDir)
        } else {
            // Fallback to getting paths from a temporary ModelManager instance
            print("🔄 Attempting to get paths from ModelManager...")
            let modelManager = ModelManager()
            finalModelPaths = modelManager.getModelPaths()
        }

        guard let modelPaths = finalModelPaths else {
            print("❌ Failed to get model paths for preloading")
            return false
        }

        print("🔄 Preloading Whisper model for shader caching")
        
        // Use the unified getOrCreateContext method
        if getOrCreateContext(modelPaths: modelPaths) != nil {
            print("✅ Preloading successful, context is ready.")
            return true
        } else {
            print("❌ Preloading failed.")
            return false
        }
    }
    
    /// Initializes or retrieves the Whisper context. This function MUST be called from within a lock.
    /// - Parameter modelPaths: The paths to the model files.
    /// - Returns: An `OpaquePointer` to the Whisper context, or `nil` on failure.
    private static func getOrCreateContext(modelPaths: (binPath: URL, encoderDir: URL)?) -> OpaquePointer? {
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

    /// Performs transcription of audio data received from HTTP request and returns the result
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization if context doesn't exist
    /// - Returns: String with transcription result or nil in case of error
    static func transcribeAudio(at audioURL: URL, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> String? {
        // Lock the entire transcription process to ensure thread safety
        lock.lock(); defer { lock.unlock() }

        // Reset the inactivity timer since we're using Whisper now
        resetInactivityTimer()
        
        // Get or initialize context (we create isolated contexts for each chunk)
        guard getOrCreateContext(modelPaths: modelPaths) != nil else {
            print("❌ Failed to get or create Whisper context.")
            return nil
        }
        
        // Create audio chunks
        guard let chunks = AudioConverter.createAudioChunks(from: audioURL, 
                                                           maxDuration: maxChunkDuration, 
                                                           overlap: chunkOverlap) else {
            print("❌ Failed to create audio chunks")
            return nil
        }
        
        // Configure parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        
        // Set language if specified
        var lang_cstr: UnsafeMutablePointer<CChar>?
        if let language = language {
            lang_cstr = strdup(language)
        } else {
            lang_cstr = nil
        }
        params.language = UnsafePointer(lang_cstr)
        defer { free(lang_cstr) }

        // Set prompt if specified
        var prompt_cstr: UnsafeMutablePointer<CChar>?
        if let prompt = prompt {
            prompt_cstr = strdup(prompt)
        } else {
            prompt_cstr = nil
        }
        params.initial_prompt = UnsafePointer(prompt_cstr)
        defer { free(prompt_cstr) }
        
        // Use available CPU cores efficiently
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        
        var combinedTranscription: [String] = []
        
        // Process each chunk
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1)/\(chunks.count) (\(String(format: "%.1f", chunk.startTime))s - \(String(format: "%.1f", chunk.endTime))s)")
            
            // Create isolated context for each chunk to prevent state interference
            let currentContext: OpaquePointer
            if resetContextBetweenChunks {
                guard let isolatedContext = createIsolatedContext(modelPaths: modelPaths) else {
                    print("❌ Failed to create isolated Whisper context for chunk \(index + 1)")
                    continue
                }
                currentContext = isolatedContext
                print("✅ Isolated Whisper context created for chunk \(index + 1)")
            } else {
                // Use shared context for compatibility
                guard let sharedContext = getOrCreateContext(modelPaths: modelPaths) else {
                    print("❌ Failed to get shared Whisper context for chunk \(index + 1)")
                    continue
                }
                currentContext = sharedContext
            }
            
            // Start transcription for this chunk
            var result: Int32 = -1
            chunk.samples.withUnsafeBufferPointer { samples in
                result = whisper_full(currentContext, params, samples.baseAddress, Int32(samples.count))
            }
            
            if result != 0 {
                print("❌ Error during transcription execution for chunk \(index + 1)")
                continue // Skip this chunk and continue with others
            }
            
            // Collect results from this chunk
            let numSegments = whisper_full_n_segments(currentContext)
            var chunkTranscription = ""
            
            for i in 0..<numSegments {
                chunkTranscription += String(cString: whisper_full_get_segment_text(currentContext, i))
            }
            
            let trimmedChunk = chunkTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedChunk.isEmpty {
                // Apply overlap filtering for chunks after the first one
                if index > 0 && !combinedTranscription.isEmpty {
                    let filteredChunk = removeOverlapFromChunk(trimmedChunk, previousChunk: combinedTranscription.last ?? "")
                    combinedTranscription.append(filteredChunk)
                } else {
                    combinedTranscription.append(trimmedChunk)
                }
                print("✅ Chunk \(index + 1) processed successfully (\(trimmedChunk.count) characters)")
            } else {
                print("⚠️ Chunk \(index + 1) produced no transcription")
            }
            
            // Free isolated context immediately after processing this chunk
            if resetContextBetweenChunks {
                let memoryBefore = getMemoryUsage()
                whisper_free(currentContext)
                let memoryAfter = getMemoryUsage()
                let freed = max(0, memoryBefore - memoryAfter)
                print("🧹 Isolated context for chunk \(index + 1) freed, released ~\(freed) MB")
            }
        }
        
        let finalResult = combinedTranscription.joined(separator: " ")
        print("✅ Combined transcription complete (\(finalResult.count) characters total)")
        
        return finalResult.isEmpty ? nil : finalResult
    }
    
    /// Removes potential overlap from a chunk by comparing with the end of the previous chunk
    private static func removeOverlapFromChunk(_ currentChunk: String, previousChunk: String) -> String {
        // Simple overlap detection: check if the beginning of current chunk matches the end of previous
        let words = currentChunk.split(separator: " ", omittingEmptySubsequences: true)
        let prevWords = previousChunk.split(separator: " ", omittingEmptySubsequences: true)
        
        // Check for overlap up to 10 words
        let maxOverlapWords = min(10, min(words.count, prevWords.count))
        
        for overlapLength in (1...maxOverlapWords).reversed() {
            let currentStart = Array(words.prefix(overlapLength))
            let previousEnd = Array(prevWords.suffix(overlapLength))
            
            if currentStart.map(String.init) == previousEnd.map(String.init) {
                print("🔄 Detected \(overlapLength)-word overlap, removing from current chunk")
                let filteredWords = Array(words.dropFirst(overlapLength))
                return filteredWords.joined(separator: " ")
            }
        }
        
        return currentChunk
    }
    
    /// Performs transcription of audio data and returns segments with timestamps for subtitle formats
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization if context doesn't exist
    /// - Returns: Array of TranscriptionSegment with timestamps or nil in case of error
    static func transcribeAudioWithTimestamps(at audioURL: URL, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> [TranscriptionSegment]? {
        // Lock the entire transcription process to ensure thread safety
        lock.lock(); defer { lock.unlock() }

        // Reset the inactivity timer since we're using Whisper now
        resetInactivityTimer()
        
        // Get or initialize context (we create isolated contexts for each chunk)
        guard getOrCreateContext(modelPaths: modelPaths) != nil else {
            print("❌ Failed to get or create Whisper context.")
            return nil
        }
        
        // Create audio chunks
        guard let chunks = AudioConverter.createAudioChunks(from: audioURL, 
                                                           maxDuration: maxChunkDuration, 
                                                           overlap: chunkOverlap) else {
            print("❌ Failed to create audio chunks")
            return nil
        }
        
        // Configure parameters with timestamps enabled
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = true  // Enable timestamps for subtitles
        params.print_special = false
        params.translate = false
        params.no_context = true
        
        // Set language if specified
        var lang_cstr: UnsafeMutablePointer<CChar>?
        if let language = language {
            lang_cstr = strdup(language)
        } else {
            lang_cstr = nil
        }
        params.language = UnsafePointer(lang_cstr)
        defer { free(lang_cstr) }

        // Set prompt if specified
        var prompt_cstr: UnsafeMutablePointer<CChar>?
        if let prompt = prompt {
            prompt_cstr = strdup(prompt)
        } else {
            prompt_cstr = nil
        }
        params.initial_prompt = UnsafePointer(prompt_cstr)
        defer { free(prompt_cstr) }
        
        // Use available CPU cores efficiently
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        
        var allSegments: [TranscriptionSegment] = []
        
        // Process each chunk
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1)/\(chunks.count) for timestamps (\(String(format: "%.1f", chunk.startTime))s - \(String(format: "%.1f", chunk.endTime))s)")
            
            // Create isolated context for each chunk to prevent state interference
            let currentContext: OpaquePointer
            if resetContextBetweenChunks {
                guard let isolatedContext = createIsolatedContext(modelPaths: modelPaths) else {
                    print("❌ Failed to create isolated Whisper context for timestamps chunk \(index + 1)")
                    continue
                }
                currentContext = isolatedContext
                print("✅ Isolated Whisper context created for timestamps chunk \(index + 1)")
            } else {
                // Use shared context for compatibility
                guard let sharedContext = getOrCreateContext(modelPaths: modelPaths) else {
                    print("❌ Failed to get shared Whisper context for timestamps chunk \(index + 1)")
                    continue
                }
                currentContext = sharedContext
            }
            
            // Start transcription for this chunk
            var result: Int32 = -1
            chunk.samples.withUnsafeBufferPointer { samples in
                result = whisper_full(currentContext, params, samples.baseAddress, Int32(samples.count))
            }
            
            if result != 0 {
                print("❌ Error during transcription execution for chunk \(index + 1)")
                continue // Skip this chunk and continue with others
            }
            
            // Collect segments with timestamps from this chunk
            let numSegments = whisper_full_n_segments(currentContext)
            var chunkSegments: [TranscriptionSegment] = []
            
            for i in 0..<numSegments {
                let text = String(cString: whisper_full_get_segment_text(currentContext, i))
                let segmentStartTime = Double(whisper_full_get_segment_t0(currentContext, i)) / 100.0  // Convert to seconds
                let segmentEndTime = Double(whisper_full_get_segment_t1(currentContext, i)) / 100.0    // Convert to seconds
                
                // Adjust timestamps to account for chunk offset
                let adjustedStartTime = chunk.startTime + segmentStartTime
                let adjustedEndTime = chunk.startTime + segmentEndTime
                
                let segment = TranscriptionSegment(
                    startTime: adjustedStartTime,
                    endTime: adjustedEndTime,
                    text: text
                )
                chunkSegments.append(segment)
            }
            
            // Filter overlapping segments for chunks after the first one
            if index > 0 && !allSegments.isEmpty {
                let filteredSegments = removeOverlappingSegments(chunkSegments, previousSegments: allSegments)
                allSegments.append(contentsOf: filteredSegments)
            } else {
                allSegments.append(contentsOf: chunkSegments)
            }
            
            print("✅ Chunk \(index + 1) processed successfully (\(chunkSegments.count) segments)")
            
            // Free isolated context immediately after processing this chunk
            if resetContextBetweenChunks {
                let memoryBefore = getMemoryUsage()
                whisper_free(currentContext)
                let memoryAfter = getMemoryUsage()
                let freed = max(0, memoryBefore - memoryAfter)
                print("🧹 Isolated context for timestamps chunk \(index + 1) freed, released ~\(freed) MB")
            }
        }
        
        print("✅ Combined timestamp transcription complete (\(allSegments.count) segments total)")
        
        return allSegments.isEmpty ? nil : allSegments
    }
    
    /// Removes overlapping segments from current chunk by comparing with previous segments
    private static func removeOverlappingSegments(_ currentSegments: [TranscriptionSegment], previousSegments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        guard !previousSegments.isEmpty, !currentSegments.isEmpty else {
            return currentSegments
        }
        
        // Find the last segment from previous chunks
        guard let lastPreviousSegment = previousSegments.last else {
            return currentSegments
        }
        
        // Find segments that might overlap based on time
        let overlapThreshold = chunkOverlap // Use the same overlap duration
        var filteredSegments: [TranscriptionSegment] = []
        
        for segment in currentSegments {
            // Skip segments that are too close to the end of the previous chunk
            let timeDifference = segment.startTime - lastPreviousSegment.endTime
            if timeDifference > overlapThreshold || !segmentsHaveTextOverlap(segment, lastPreviousSegment) {
                filteredSegments.append(segment)
            } else {
                print("🔄 Skipping overlapping segment: '\(segment.text.prefix(30))...'")
            }
        }
        
        return filteredSegments
    }
    
    /// Checks if two segments have overlapping text content
    private static func segmentsHaveTextOverlap(_ segment1: TranscriptionSegment, _ segment2: TranscriptionSegment) -> Bool {
        let words1 = segment1.text.split(separator: " ", omittingEmptySubsequences: true)
        let words2 = segment2.text.split(separator: " ", omittingEmptySubsequences: true)
        
        // Check for any common words (simple overlap detection)
        let commonWords = Set(words1).intersection(Set(words2))
        return commonWords.count > 2 // Require at least 3 common words to consider overlap
    }
    
    /// User data structure to pass to whisper.cpp callbacks
    private class TranscriptionUserData {
        var onSegment: (String) -> Void
        var onCompletion: () -> Void
        var lastSegment: Int = -1

        init(onSegment: @escaping (String) -> Void, onCompletion: @escaping () -> Void) {
            self.onSegment = onSegment
            self.onCompletion = onCompletion
        }
    }
    
    /// User data structure for streaming with timestamps (for subtitle formats)
    private class TranscriptionUserDataWithTimestamps {
        var onSegment: (TranscriptionSegment) -> Void
        var onCompletion: () -> Void
        var lastSegment: Int = -1

        init(onSegment: @escaping (TranscriptionSegment) -> Void, onCompletion: @escaping () -> Void) {
            self.onSegment = onSegment
            self.onCompletion = onCompletion
        }
    }

    /// C-style callback for new segments
    private static let newSegmentCallback: whisper_new_segment_callback = { (ctx, _, n_new, user_data) in
        guard let user_data = user_data else { return }
        let userData = Unmanaged<TranscriptionUserData>.fromOpaque(user_data).takeUnretainedValue()
        
        let n_segments = whisper_full_n_segments(ctx)
        print("🔄 Whisper callback: \(n_new) new segments, total: \(n_segments)")
        
        for i in (n_segments - n_new)..<n_segments {
            // Avoid processing the same segment twice
            if i > userData.lastSegment {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    let segmentText = String(cString: text)
                    print("🎯 Generated segment #\(i): '\(segmentText.prefix(50))...'")
                    userData.onSegment(segmentText)
                    userData.lastSegment = Int(i)
                    print("✅ Segment #\(i) sent to callback")
                }
            }
        }
    }
    
    /// C-style callback for new segments with timestamps
    private static let newSegmentWithTimestampsCallback: whisper_new_segment_callback = { (ctx, _, n_new, user_data) in
        guard let user_data = user_data else { return }
        let userData = Unmanaged<TranscriptionUserDataWithTimestamps>.fromOpaque(user_data).takeUnretainedValue()
        
        let n_segments = whisper_full_n_segments(ctx)
        print("🔄 Whisper timestamp callback: \(n_new) new segments, total: \(n_segments)")
        
        for i in (n_segments - n_new)..<n_segments {
            // Avoid processing the same segment twice
            if i > userData.lastSegment {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    let startTime = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
                    let endTime = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
                    let segmentText = String(cString: text)
                    
                    print("🎯 Generated timestamped segment #\(i): [\(String(format: "%.2f", startTime))-\(String(format: "%.2f", endTime))s] '\(segmentText.prefix(50))...'")
                    
                    let segment = TranscriptionSegment(
                        startTime: startTime,
                        endTime: endTime,
                        text: segmentText
                    )
                    userData.onSegment(segment)
                    userData.lastSegment = Int(i)
                    print("✅ Timestamped segment #\(i) sent to callback")
                }
            }
        }
    }

    /// Performs streaming transcription of audio data.
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code.
    ///   - prompt: Prompt to improve recognition.
    ///   - modelPaths: Optional model paths.
    ///   - onSegment: Callback for each new transcribed segment.
    ///   - onCompletion: Callback for when transcription is complete.
    /// - Returns: Boolean indicating if transcription started successfully.
    static func transcribeAudioStream(
        at audioURL: URL,
        language: String? = nil,
        prompt: String? = nil,
        modelPaths: (binPath: URL, encoderDir: URL)? = nil,
        onSegment: @escaping (String) -> Void,
        onCompletion: @escaping () -> Void
    ) -> Bool {
        // We cannot lock the whole scope here because whisper_full will be called
        // on a background thread. The transcription must be queued and executed serially.
        // For simplicity, we will run the entire streaming transcription inside the lock on a background thread.
        // This is not ideal for performance but guarantees safety.
        // A better approach would be an actor or a dedicated serial queue.
        
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock(); defer { lock.unlock() }

            resetInactivityTimer()
            
            print("🎵 Starting regular streaming transcription for file: \(audioURL.lastPathComponent)")

            guard let context = getOrCreateContext(modelPaths: modelPaths) else {
                print("❌ Failed to get or create Whisper context for streaming.")
                onCompletion()
                return
            }
            
            print("✅ Whisper context ready for regular streaming")

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.no_context = true
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))

            var lang_cstr: UnsafeMutablePointer<CChar>?
            if let language = language {
                lang_cstr = strdup(language)
            } else {
                lang_cstr = nil
            }
            params.language = UnsafePointer(lang_cstr)
            defer { free(lang_cstr) }

            var prompt_cstr: UnsafeMutablePointer<CChar>?
            if let prompt = prompt {
                prompt_cstr = strdup(prompt)
            } else {
                prompt_cstr = nil
            }
            params.initial_prompt = UnsafePointer(prompt_cstr)
            defer { free(prompt_cstr) }

            // Setup streaming callback
            let userData = TranscriptionUserData(onSegment: onSegment, onCompletion: onCompletion)
            let unmanagedUserData = Unmanaged.passRetained(userData)
            params.new_segment_callback = newSegmentCallback
            params.new_segment_callback_user_data = unmanagedUserData.toOpaque()

            guard let samples = AudioConverter.convertToWhisperFormat(from: audioURL) else {
                print("❌ Failed to convert audio data to Whisper format")
                unmanagedUserData.release()
                onCompletion()
                return
            }
            
            print("🔊 Audio converted, starting whisper_full with \(samples.count) samples")

            // Run transcription
            samples.withUnsafeBufferPointer { samplesBuffer in
                let result = whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count))
                if result != 0 {
                    print("❌ Error during streaming transcription execution")
                } else {
                    print("✅ Regular streaming transcription completed successfully")
                }
                // Call completion handler
                userData.onCompletion()
            }
            // Release user data after transcription is complete
            unmanagedUserData.release()
        }
        
        return true
    }
    
    /// Performs streaming transcription with timestamps for subtitle formats
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code.
    ///   - prompt: Prompt to improve recognition.
    ///   - modelPaths: Optional model paths.
    ///   - onSegment: Callback for each new transcribed segment with timestamps.
    ///   - onCompletion: Callback for when transcription is complete.
    /// - Returns: Boolean indicating if transcription started successfully.
    static func transcribeAudioStreamWithTimestamps(
        at audioURL: URL,
        language: String? = nil,
        prompt: String? = nil,
        modelPaths: (binPath: URL, encoderDir: URL)? = nil,
        onSegment: @escaping (TranscriptionSegment) -> Void,
        onCompletion: @escaping () -> Void
    ) -> Bool {
        DispatchQueue.global(qos: .userInitiated).async {
            lock.lock(); defer { lock.unlock() }

            resetInactivityTimer()

            print("🎵 Starting timestamp streaming transcription for file: \(audioURL.lastPathComponent)")

            guard let context = getOrCreateContext(modelPaths: modelPaths) else {
                print("❌ Failed to get or create Whisper context for timestamp streaming.")
                onCompletion()
                return
            }
            
            print("✅ Whisper context ready for timestamp streaming")

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = true  // Enable timestamps for subtitles
            params.print_special = false
            params.translate = false
            params.no_context = true
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))

            var lang_cstr: UnsafeMutablePointer<CChar>?
            if let language = language {
                lang_cstr = strdup(language)
            } else {
                lang_cstr = nil
            }
            params.language = UnsafePointer(lang_cstr)
            defer { free(lang_cstr) }

            var prompt_cstr: UnsafeMutablePointer<CChar>?
            if let prompt = prompt {
                prompt_cstr = strdup(prompt)
            } else {
                prompt_cstr = nil
            }
            params.initial_prompt = UnsafePointer(prompt_cstr)
            defer { free(prompt_cstr) }

            // Setup streaming callback with timestamps
            let userData = TranscriptionUserDataWithTimestamps(onSegment: onSegment, onCompletion: onCompletion)
            let unmanagedUserData = Unmanaged.passRetained(userData)
            params.new_segment_callback = newSegmentWithTimestampsCallback
            params.new_segment_callback_user_data = unmanagedUserData.toOpaque()

            guard let samples = AudioConverter.convertToWhisperFormat(from: audioURL) else {
                print("❌ Failed to convert audio data to Whisper format")
                unmanagedUserData.release()
                onCompletion()
                return
            }

            print("🔊 Audio converted, starting whisper_full with \(samples.count) samples (timestamps enabled)")

            // Run transcription
            samples.withUnsafeBufferPointer { samplesBuffer in
                let result = whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count))
                if result != 0 {
                    print("❌ Error during timestamp streaming transcription execution")
                } else {
                    print("✅ Timestamp streaming transcription completed successfully")
                }
                // Call completion handler
                userData.onCompletion()
            }
            // Release user data after transcription is complete
            unmanagedUserData.release()
        }
        
        return true
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
