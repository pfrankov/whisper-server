import Foundation
import whisper
import Darwin

/// Audio transcription service using whisper.cpp
struct WhisperTranscriptionService {
    // MARK: - Type Aliases
    
    /// Re-export types from our component modules
    typealias TranscriptionSegment = WhisperSubtitleFormatter.TranscriptionSegment
    typealias ResponseFormat = WhisperSubtitleFormatter.ResponseFormat
    
    // MARK: - Constants
    
    /// Notification name for when Metal is activated
    static let metalActivatedNotificationName = Notification.Name.whisperMetalActivated
    
    // MARK: Audio Processing Constants
    private static let defaultMaxChunkDuration = 30.0 // Only used for traditional chunking when VAD is disabled
    
    /// Maximum chunk duration in seconds (only used for traditional chunking when VAD is disabled)
    public static var maxChunkDuration: Double = defaultMaxChunkDuration
    
    /// Overlap between chunks in seconds to avoid cutting words
    public static var chunkOverlap: Double = 0 // 0 seconds by default (no overlap)
    
    /// Whether to reset Whisper context between chunks for memory isolation
    /// When true: Each chunk gets a completely isolated context (prevents state interference, uses more memory)
    /// When false: All chunks share the same context (faster, uses less memory, but may have state interference)
    public static var resetContextBetweenChunks: Bool = false
    
    /// Whether to use Voice Activity Detection for smart chunking
    public static var useVADChunking: Bool = true
    
    /// Whether to remove leading silence from chunks to prevent hallucinations
    public static var removeLeadingSilence: Bool = true
    
    /// Energy threshold for VAD (0.0-1.0, lower = more sensitive)
    public static var vadEnergyThreshold: Float = 0.02
    
    /// Minimum speech duration in seconds
    public static var vadMinSpeechDuration: Double = 0.3
    
    /// Minimum silence duration in seconds to split chunks
    public static var vadMinSilenceDuration: Double = 0.5
    
    // MARK: - Delegation to Component Modules
    
    /// Formats timestamps for SRT format (HH:MM:SS,mmm)
    static func formatSRTTimestamp(_ seconds: Double) -> String {
        return WhisperSubtitleFormatter.formatSRTTimestamp(seconds)
    }
    
    /// Formats timestamps for VTT format (HH:MM:SS.mmm)
    static func formatVTTTimestamp(_ seconds: Double) -> String {
        return WhisperSubtitleFormatter.formatVTTTimestamp(seconds)
    }
    
    /// Formats segments as SRT subtitles
    static func formatAsSRT(segments: [TranscriptionSegment]) -> String {
        return WhisperSubtitleFormatter.formatAsSRT(segments: segments)
    }
    
    /// Formats segments as WebVTT subtitles
    static func formatAsVTT(segments: [TranscriptionSegment]) -> String {
        return WhisperSubtitleFormatter.formatAsVTT(segments: segments)
    }
    
    /// Formats segments as verbose JSON (OpenAI Whisper API compatible)
    static func formatAsVerboseJSON(segments: [TranscriptionSegment]) -> String {
        return WhisperSubtitleFormatter.formatAsVerboseJSON(segments: segments)
    }
    
    // MARK: - Context Management
    
    /// Frees resources on application termination
    static func cleanup() {
        WhisperContextManager.cleanup()
    }
    
    /// Forcibly releases and reinitializes the Whisper context when the model changes
    static func reinitializeContext() {
        WhisperContextManager.reinitializeContext()
    }
    
    /// Sets the inactivity timeout in seconds
    /// - Parameter seconds: Number of seconds of inactivity before resources are released
    static func setInactivityTimeout(seconds: TimeInterval) {
        WhisperContextManager.setInactivityTimeout(seconds: seconds)
    }
    
    /// Performs context check and initialization without performing transcription
    /// - Returns: True if initialization was successful
    static func preloadModelForShaderCaching(modelBinPath: URL? = nil, modelEncoderDir: URL? = nil) -> Bool {
        // Get model paths either from parameters or from the model manager
        var finalModelPaths: (binPath: URL, encoderDir: URL)?
        if let binPath = modelBinPath, let encoderDir = modelEncoderDir {
            finalModelPaths = (binPath, encoderDir)
        } else {
            // Fallback to getting paths from a temporary ModelManager instance
            let modelManager = ModelManager()
            finalModelPaths = modelManager.getModelPaths()
        }

        return WhisperContextManager.preloadModelForShaderCaching(modelPaths: finalModelPaths)
    }
    
    /// Configures context isolation behavior for chunk processing
    /// - Parameter enabled: When true, each chunk gets a completely isolated context (prevents state interference, uses more memory)
    ///                     When false, all chunks share the same context (faster, uses less memory, but may have state interference)
    static func setContextIsolationEnabled(_ enabled: Bool) {
        resetContextBetweenChunks = enabled
    }
    
    /// Gets the current context isolation setting
    /// - Returns: True if context isolation is enabled, false otherwise
    static func isContextIsolationEnabled() -> Bool {
        return resetContextBetweenChunks
    }
    
    /// Configures audio chunking parameters (only affects traditional chunking when VAD is disabled)
    /// - Parameters:
    ///   - maxDuration: Maximum duration for traditional chunks when VAD is disabled (minimum 10 seconds)
    ///   - overlap: Overlap between traditional chunks in seconds (will be clamped to minimum 0 seconds)
    static func setChunkingParameters(maxDuration: Double, overlap: Double = 0.0) {
        let previousMaxDuration = maxChunkDuration
        let previousOverlap = chunkOverlap
        
        maxChunkDuration = max(10.0, maxDuration) // Minimum 10s for traditional chunking
        chunkOverlap = max(0.0, overlap)
        
        // Only log if values actually changed
        _ = (previousMaxDuration, previousOverlap)
    }
    
    /// Gets the current chunking parameters
    /// - Returns: Tuple with max duration and overlap in seconds
    static func getChunkingParameters() -> (maxDuration: Double, overlap: Double) {
        return (maxDuration: maxChunkDuration, overlap: chunkOverlap)
    }
    
    /// Configures Voice Activity Detection (VAD) settings
    /// - Parameters:
    ///   - enabled: Whether to use VAD for smart chunking
    ///   - removeLeadingSilence: Whether to remove silence from chunks
    ///   - energyThreshold: Energy threshold for speech detection (0.0-1.0)
    ///   - minSpeechDuration: Minimum duration to consider as speech (seconds)
    ///   - minSilenceDuration: Minimum duration to consider as silence (seconds)
    static func setVADSettings(enabled: Bool? = nil,
                              removeLeadingSilence: Bool? = nil,
                              energyThreshold: Float? = nil,
                              minSpeechDuration: Double? = nil,
                              minSilenceDuration: Double? = nil) {
        if let enabled = enabled { useVADChunking = enabled }
        
        if let remove = removeLeadingSilence { self.removeLeadingSilence = remove }
        
        if let threshold = energyThreshold { vadEnergyThreshold = max(0.0, min(1.0, threshold)) }
        
        if let speechDuration = minSpeechDuration { vadMinSpeechDuration = max(0.1, speechDuration) }
        
        if let silenceDuration = minSilenceDuration { vadMinSilenceDuration = max(0.1, silenceDuration) }
    }
    
    /// Gets the current VAD settings
    /// - Returns: Tuple with all VAD settings
    static func getVADSettings() -> (enabled: Bool, removeLeadingSilence: Bool, energyThreshold: Float, minSpeechDuration: Double, minSilenceDuration: Double) {
        return (enabled: useVADChunking, 
                removeLeadingSilence: removeLeadingSilence,
                energyThreshold: vadEnergyThreshold,
                minSpeechDuration: vadMinSpeechDuration,
                minSilenceDuration: vadMinSilenceDuration)
    }
    
    // MARK: - Core Transcription Logic
    
    /// Performs transcription of audio data received from HTTP request and returns the result
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization if context doesn't exist
    /// - Returns: String with transcription result or nil in case of error
    static func transcribeAudio(at audioURL: URL, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> String? {
        guard WhisperContextManager.getOrCreateContext(modelPaths: modelPaths) != nil else { return nil }
        guard let chunks = makeChunks(from: audioURL) else { return nil }
        return processChunks(chunks, language: language, prompt: prompt, modelPaths: modelPaths)
    }
    
    /// Performs transcription of audio data and returns segments with timestamps for subtitle formats
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization if context doesn't exist
    /// - Returns: Array of segments with timestamps or nil in case of error
    static func transcribeAudioToSegments(at audioURL: URL, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> [TranscriptionSegment]? {
        guard WhisperContextManager.getOrCreateContext(modelPaths: modelPaths) != nil else { return nil }
        guard let chunks = makeChunks(from: audioURL) else { return nil }
        return processChunksToSegments(chunks, language: language, prompt: prompt, modelPaths: modelPaths)
    }

    /// Returns audio chunks based on current configuration (VAD or standard chunking)
    private static func makeChunks(from audioURL: URL) -> [(samples: [Float], startTime: Double, endTime: Double)]? {
        if useVADChunking {
            guard let vadChunks = WhisperAudioConverter.createAudioChunksWithVAD(
                from: audioURL,
                vadEnabled: true,
                removeLeadingSilence: removeLeadingSilence,
                vadEnergyThreshold: vadEnergyThreshold,
                vadMinSpeechDuration: vadMinSpeechDuration,
                vadMinSilenceDuration: vadMinSilenceDuration
            ) else { return nil }
            return vadChunks.map { ($0.samples, $0.startTime, $0.endTime) }
        } else {
            return WhisperAudioConverter.createAudioChunks(
                from: audioURL,
                maxDuration: maxChunkDuration,
                overlap: chunkOverlap
            )
        }
    }
    
    // MARK: - Streaming Methods (for backward compatibility)
    
    /// Alias for transcribeAudioToSegments for backward compatibility
    static func transcribeAudioWithTimestamps(at audioURL: URL, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> [TranscriptionSegment]? {
        return transcribeAudioToSegments(at: audioURL, language: language, prompt: prompt, modelPaths: modelPaths)
    }
    
    /// Streams transcription with timestamps by processing chunks and calling onSegment for each segment
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization
    ///   - onSegment: Callback called for each transcribed segment with timestamps
    ///   - onCompletion: Callback called when transcription is complete
    /// - Returns: True if streaming started successfully, false otherwise
    static func transcribeAudioStreamWithTimestamps(
        at audioURL: URL, 
        language: String? = nil, 
        prompt: String? = nil, 
        modelPaths: (binPath: URL, encoderDir: URL)? = nil,
        onSegment: @escaping (TranscriptionSegment) -> Void,
        onCompletion: @escaping () -> Void
    ) -> Bool {
        // Process in background to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            if let segments = transcribeAudioToSegments(at: audioURL, language: language, prompt: prompt, modelPaths: modelPaths) {
                // Stream each segment
                for segment in segments {
                    onSegment(segment)
                }
            }
            onCompletion()
        }
        return true
    }
    
    /// Streams transcription as text by processing chunks and calling onSegment for each text chunk
    /// - Parameters:
    ///   - audioURL: URL of the original audio file
    ///   - language: Audio language code (optional)
    ///   - prompt: Prompt to improve recognition (optional)  
    ///   - modelPaths: Optional model paths to use for initialization
    ///   - onSegment: Callback called for each transcribed text segment
    ///   - onCompletion: Callback called when transcription is complete
    /// - Returns: True if streaming started successfully, false otherwise
    static func transcribeAudioStream(
        at audioURL: URL, 
        language: String? = nil, 
        prompt: String? = nil, 
        modelPaths: (binPath: URL, encoderDir: URL)? = nil,
        onSegment: @escaping (String) -> Void,
        onCompletion: @escaping () -> Void
    ) -> Bool {
        // Process in background to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            if let segments = transcribeAudioToSegments(at: audioURL, language: language, prompt: prompt, modelPaths: modelPaths) {
                // Stream each segment as text
                for segment in segments {
                    onSegment(segment.text)
                }
            }
            onCompletion()
        }
        return true
    }
    
    // MARK: - Private Methods
    
    /// Processes audio chunks and returns the combined transcription
    private static func processChunks(_ chunks: [(samples: [Float], startTime: Double, endTime: Double)], 
                                     language: String?, 
                                     prompt: String?, 
                                     modelPaths: (binPath: URL, encoderDir: URL)?) -> String? {
        guard !chunks.isEmpty else {
            print("❌ No audio chunks to process")
            return nil
        }
        
        print("🔄 Processing \(chunks.count) audio chunk(s)")
        var transcriptions = [String]()
        
        for (index, chunk) in chunks.enumerated() {
            print("🎯 Processing chunk \(index + 1)/\(chunks.count) (\(String(format: "%.1f", chunk.startTime))s - \(String(format: "%.1f", chunk.endTime))s)")
            
            if let result = transcribeChunk(chunk.samples, language: language, prompt: prompt, modelPaths: modelPaths) {
                if !result.isEmpty {
                    transcriptions.append(result)
                    print("✅ Chunk \(index + 1) transcribed: \(result.prefix(50))...")
                } else {
                    print("⚠️ Chunk \(index + 1) produced empty transcription")
                }
            } else {
                print("❌ Failed to transcribe chunk \(index + 1)")
            }
        }
        
        let finalResult = transcriptions.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        print("🎉 Final transcription: \(finalResult.isEmpty ? "EMPTY" : String(finalResult.prefix(100)))...")
        
        return finalResult.isEmpty ? nil : finalResult
    }
    
    /// Processes audio chunks and returns segments with timestamps
    private static func processChunksToSegments(_ chunks: [(samples: [Float], startTime: Double, endTime: Double)], 
                                               language: String?, 
                                               prompt: String?, 
                                               modelPaths: (binPath: URL, encoderDir: URL)?) -> [TranscriptionSegment]? {
        guard !chunks.isEmpty else {
            print("❌ No audio chunks to process")
            return nil
        }
        
        print("🔄 Processing \(chunks.count) audio chunk(s) for segments")
        var allSegments = [TranscriptionSegment]()
        
        for (index, chunk) in chunks.enumerated() {
            print("🎯 Processing chunk \(index + 1)/\(chunks.count) (\(String(format: "%.1f", chunk.startTime))s - \(String(format: "%.1f", chunk.endTime))s)")
            
            if let segments = transcribeChunkToSegments(chunk.samples, chunkStartTime: chunk.startTime, language: language, prompt: prompt, modelPaths: modelPaths) {
                allSegments.append(contentsOf: segments)
                print("✅ Chunk \(index + 1) produced \(segments.count) segment(s)")
            } else {
                print("❌ Failed to transcribe chunk \(index + 1) to segments")
            }
        }
        
        print("🎉 Total segments generated: \(allSegments.count)")
        return allSegments.isEmpty ? nil : allSegments
    }
    
    /// Transcribes a single audio chunk
    private static func transcribeChunk(_ samples: [Float],
                                       language: String?,
                                       prompt: String?,
                                       modelPaths: (binPath: URL, encoderDir: URL)?) -> String? {

        // Get context for this chunk
        let context: OpaquePointer?
        if resetContextBetweenChunks {
            context = WhisperContextManager.createIsolatedContext(modelPaths: modelPaths)
        } else {
            context = WhisperContextManager.getOrCreateContext(modelPaths: modelPaths)
        }
        guard let ctx = context else { return nil }
        
        defer {
            // Clean up isolated context
            if resetContextBetweenChunks, let ctx = context {
                whisper_free(ctx)
            }
        }
        
        // Configure parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.max_tokens = 0
        params.audio_ctx = 0
        
        // Prepare stable C-strings for language and prompt (freed after call)
        var langPtr: UnsafeMutablePointer<CChar>? = nil
        var promptPtr: UnsafeMutablePointer<CChar>? = nil
        if let lang = language { langPtr = strdup(lang) }
        if let promptText = prompt { promptPtr = strdup(promptText) }
        params.language = UnsafePointer(langPtr)
        params.initial_prompt = UnsafePointer(promptPtr)

        // Process the audio
        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        // Free temporary C-strings
        if let lp = langPtr { free(lp) }
        if let pp = promptPtr { free(pp) }
        
        guard result == 0 else {
            print("❌ whisper_full failed with code: \(result)")
            return nil
        }
        
        // Extract transcription
        let segmentCount = whisper_full_n_segments(ctx)
        var transcription = ""
        
        for i in 0..<segmentCount {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                let text = String(cString: segmentText).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    transcription += text + " "
                }
            }
        }
        
        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Transcribes a single audio chunk and returns segments with timestamps
    private static func transcribeChunkToSegments(_ samples: [Float], 
                                                 chunkStartTime: Double,
                                                 language: String?, 
                                                 prompt: String?, 
                                                 modelPaths: (binPath: URL, encoderDir: URL)?) -> [TranscriptionSegment]? {
        
        // Get context for this chunk
        let context: OpaquePointer?
        if resetContextBetweenChunks {
            context = WhisperContextManager.createIsolatedContext(modelPaths: modelPaths)
        } else {
            context = WhisperContextManager.getOrCreateContext(modelPaths: modelPaths)
        }
        guard let ctx = context else { return nil }
        
        defer {
            // Clean up isolated context
            if resetContextBetweenChunks, let ctx = context {
                whisper_free(ctx)
            }
        }
        
        // Configure parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = true
        params.print_special = false
        params.translate = false
        params.single_segment = false
        params.max_tokens = 0
        params.audio_ctx = 0
        
        // Prepare stable C-strings for language and prompt (freed after call)
        var langPtr: UnsafeMutablePointer<CChar>? = nil
        var promptPtr: UnsafeMutablePointer<CChar>? = nil
        if let lang = language { langPtr = strdup(lang) }
        if let promptText = prompt { promptPtr = strdup(promptText) }
        params.language = UnsafePointer(langPtr)
        params.initial_prompt = UnsafePointer(promptPtr)

        // Process the audio
        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full(ctx, params, buffer.baseAddress, Int32(buffer.count))
        }

        // Free temporary C-strings
        if let lp = langPtr { free(lp) }
        if let pp = promptPtr { free(pp) }
        
        guard result == 0 else {
            print("❌ whisper_full failed with code: \(result)")
            return nil
        }
        
        // Extract segments with timestamps
        let segmentCount = whisper_full_n_segments(ctx)
        var segments = [TranscriptionSegment]()
        
        for i in 0..<segmentCount {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                let text = String(cString: segmentText).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    let startTime = Double(whisper_full_get_segment_t0(ctx, i)) / 100.0 + chunkStartTime
                    let endTime = Double(whisper_full_get_segment_t1(ctx, i)) / 100.0 + chunkStartTime
                    
                    segments.append(TranscriptionSegment(
                        startTime: startTime,
                        endTime: endTime,
                        text: text
                    ))
                }
            }
        }
        
        return segments
    }
}
