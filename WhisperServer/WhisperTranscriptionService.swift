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
        
        // Get or initialize context
        guard let context = getOrCreateContext(modelPaths: modelPaths) else {
            print("❌ Failed to get or create Whisper context.")
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
        
        // Convert audio to samples for Whisper using the new converter
        guard let samples = AudioConverter.convertToWhisperFormat(from: audioURL) else {
            print("❌ Failed to convert audio data to Whisper format")
            return nil
        }
        
        // Start transcription
        var result: Int32 = -1
        samples.withUnsafeBufferPointer { samples in
            result = whisper_full(context, params, samples.baseAddress, Int32(samples.count))
        }
        
        if result != 0 {
            print("❌ Error during transcription execution")
            return nil
        }
        
        // Collect results
        let numSegments = whisper_full_n_segments(context)
        var transcription = ""
        
        for i in 0..<numSegments {
            transcription += String(cString: whisper_full_get_segment_text(context, i))
        }
        
        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
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
        
        // Get or initialize context
        guard let context = getOrCreateContext(modelPaths: modelPaths) else {
            print("❌ Failed to get or create Whisper context.")
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
        
        // Convert audio to samples for Whisper using the new converter
        guard let samples = AudioConverter.convertToWhisperFormat(from: audioURL) else {
            print("❌ Failed to convert audio data to Whisper format")
            return nil
        }
        
        // Start transcription
        var result: Int32 = -1
        samples.withUnsafeBufferPointer { samples in
            result = whisper_full(context, params, samples.baseAddress, Int32(samples.count))
        }
        
        if result != 0 {
            print("❌ Error during transcription execution")
            return nil
        }
        
        // Collect segments with timestamps
        let numSegments = whisper_full_n_segments(context)
        var segments: [TranscriptionSegment] = []
        
        for i in 0..<numSegments {
            let text = String(cString: whisper_full_get_segment_text(context, i))
            let startTime = Double(whisper_full_get_segment_t0(context, i)) / 100.0  // Convert to seconds
            let endTime = Double(whisper_full_get_segment_t1(context, i)) / 100.0    // Convert to seconds
            
            let segment = TranscriptionSegment(
                startTime: startTime,
                endTime: endTime,
                text: text
            )
            segments.append(segment)
        }
        
        return segments
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
        
        for i in (n_segments - n_new)..<n_segments {
            // Avoid processing the same segment twice
            if i > userData.lastSegment {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    userData.onSegment(String(cString: text))
                    userData.lastSegment = Int(i)
                }
            }
        }
    }
    
    /// C-style callback for new segments with timestamps
    private static let newSegmentWithTimestampsCallback: whisper_new_segment_callback = { (ctx, _, n_new, user_data) in
        guard let user_data = user_data else { return }
        let userData = Unmanaged<TranscriptionUserDataWithTimestamps>.fromOpaque(user_data).takeUnretainedValue()
        
        let n_segments = whisper_full_n_segments(ctx)
        
        for i in (n_segments - n_new)..<n_segments {
            // Avoid processing the same segment twice
            if i > userData.lastSegment {
                if let text = whisper_full_get_segment_text(ctx, i) {
                    let startTime = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0
                    let endTime = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0
                    
                    let segment = TranscriptionSegment(
                        startTime: startTime,
                        endTime: endTime,
                        text: String(cString: text)
                    )
                    userData.onSegment(segment)
                    userData.lastSegment = Int(i)
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

            guard let context = getOrCreateContext(modelPaths: modelPaths) else {
                print("❌ Failed to get or create Whisper context for streaming.")
                onCompletion()
                return
            }

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

            // Run transcription
            samples.withUnsafeBufferPointer { samplesBuffer in
                let result = whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count))
                if result != 0 {
                    print("❌ Error during streaming transcription execution")
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

            guard let context = getOrCreateContext(modelPaths: modelPaths) else {
                print("❌ Failed to get or create Whisper context for timestamp streaming.")
                onCompletion()
                return
            }

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

            // Run transcription
            samples.withUnsafeBufferPointer { samplesBuffer in
                let result = whisper_full(context, params, samplesBuffer.baseAddress, Int32(samplesBuffer.count))
                if result != 0 {
                    print("❌ Error during timestamp streaming transcription execution")
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
