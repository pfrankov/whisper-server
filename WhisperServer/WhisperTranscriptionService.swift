import Foundation
import whisper

/// Audio transcription service using whisper.cpp
struct WhisperTranscriptionService {
    
    /// Performs transcription of audio data received from HTTP request and returns the result
    /// - Parameters:
    ///   - audioData: Binary audio file data
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    /// - Returns: String with transcription result or nil in case of error
    static func transcribeAudioData(_ audioData: Data, language: String? = nil, prompt: String? = nil) -> String? {
        let modelFilename = "ggml-base.en.bin"
        
        // Find the model
        guard let modelURL = Bundle.main.url(forResource: "ggml-base.en", withExtension: "bin", subdirectory: "models") else {
            print("❌ Failed to find Whisper model")
            return nil
        }
        
        // Initialize Whisper context
        var contextParams = whisper_context_default_params()
        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        #endif
        
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            print("❌ Failed to initialize Whisper context")
            return nil
        }
        
        defer {
            whisper_free(context)
        }
        
        // Configure parameters
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        
        // Set language if specified
        if let language = language {
            language.withCString { lang in
                params.language = lang
            }
        }
        
        // Set prompt if specified
        if let prompt = prompt {
            prompt.withCString { p in
                params.initial_prompt = p
            }
        }
        
        // Use available CPU cores efficiently
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        
        // Convert audio to samples for Whisper
        let samples = convertAudioToSamples(audioData)
        
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
        
        return transcription
    }
    
    /// Converts audio data to sample array for Whisper
    private static func convertAudioToSamples(_ audioData: Data) -> [Float] {
        // Check WAV header (RIFF)
        let isWav = audioData.count > 12 && 
                    audioData[0] == 0x52 && // R
                    audioData[1] == 0x49 && // I
                    audioData[2] == 0x46 && // F
                    audioData[3] == 0x46    // F
        
        // Check MP3 header
        let isMp3 = audioData.count > 3 && 
                    (audioData[0] == 0x49 && audioData[1] == 0x44 && audioData[2] == 0x33) || // ID3
                    (audioData[0] == 0xFF && audioData[1] == 0xFB) // MP3 sync
        
        if isWav {
            print("✅ Processing WAV format audio")
            return convertWavDataToSamples(audioData)
        } else if isMp3 {
            print("⚠️ MP3 format detected but not directly supported. Converting as raw PCM")
            return convertRawPCMToSamples(audioData)
        } else {
            print("⚠️ Unknown audio format, attempting to interpret as raw PCM")
            return convertRawPCMToSamples(audioData)
        }
    }
    
    /// Converts WAV data to sample array
    private static func convertWavDataToSamples(_ audioData: Data) -> [Float] {
        return audioData.withUnsafeBytes { rawBufferPointer -> [Float] in
            let header = 44 // Standard WAV header size
            let bytesPerSample = 2 // 16-bit PCM
            
            guard audioData.count > header + bytesPerSample else {
                print("❌ WAV file too short")
                return []
            }
            
            guard let baseAddress = rawBufferPointer.baseAddress else {
                return []
            }
            
            let dataPtr = baseAddress.advanced(by: header)
            let int16Ptr = dataPtr.assumingMemoryBound(to: Int16.self)
            
            let numSamples = (audioData.count - header) / bytesPerSample
            var samples = [Float](repeating: 0, count: numSamples)
            
            for i in 0..<numSamples {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
            
            return samples
        }
    }
    
    /// Interprets audio data as raw PCM
    private static func convertRawPCMToSamples(_ audioData: Data) -> [Float] {
        return audioData.withUnsafeBytes { rawBufferPointer -> [Float] in
            let bytesPerSample = 2 // Assume 16-bit PCM
            let numSamples = audioData.count / bytesPerSample
            var samples = [Float](repeating: 0, count: numSamples)
            
            if let baseAddress = rawBufferPointer.baseAddress {
                let int16Ptr = baseAddress.assumingMemoryBound(to: Int16.self)
                
                for i in 0..<numSamples {
                    samples[i] = Float(int16Ptr[i]) / 32768.0
                }
            }
            
            return samples
        }
    }
}