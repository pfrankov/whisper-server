import Foundation
import whisper
#if os(macOS) || os(iOS)
import SwiftUI
#endif

/// Audio transcription service using whisper.cpp
struct WhisperTranscriptionService {
    // Разделяемый контекст и блокировка для многопоточного доступа
    private static var sharedContext: OpaquePointer?
    private static let lock = NSLock()
    
    /// Настраивает постоянный кэш шейдеров Metal
    private static func setupMetalShaderCache() {
        #if os(macOS) || os(iOS)
        // Папка для хранения кэша шейдеров Metal
        var cacheDirectory: URL
        
        // Создаем путь к папке с кэшем в Application Support
        if let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let bundleId = Bundle.main.bundleIdentifier ?? "com.whisperserver"
            let whisperCacheDir = appSupportDir.appendingPathComponent(bundleId).appendingPathComponent("MetalCache")
            
            // Создаем директорию, если она не существует
            do {
                try FileManager.default.createDirectory(at: whisperCacheDir, withIntermediateDirectories: true)
                cacheDirectory = whisperCacheDir
                print("✅ Set Metal shader cache directory: \(whisperCacheDir.path)")
                
                // Проверяем существует ли уже кэш
                let fileManager = FileManager.default
                let cacheFolderContents = try? fileManager.contentsOfDirectory(at: whisperCacheDir, includingPropertiesForKeys: nil)
                if let contents = cacheFolderContents, !contents.isEmpty {
                    print("📋 Found existing Metal cache with \(contents.count) files")
                }
            } catch {
                print("⚠️ Failed to create Metal cache directory: \(error.localizedDescription)")
                // Используем временную директорию как запасной вариант
                cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperMetalCache")
            }
            
            // Устанавливаем переменные окружения для Metal
            setenv("MTL_SHADER_CACHE_PATH", cacheDirectory.path, 1)
            setenv("MTL_SHADER_CACHE", "1", 1)
            setenv("MTL_SHADER_CACHE_SKIP_VALIDATION", "1", 1)
            
            // Дополнительные настройки для отладки кэширования
            #if DEBUG
            setenv("MTL_DEBUG_SHADER_CACHE", "1", 1)
            #endif
        }
        #endif
    }
    
    /// Освобождает ресурсы при завершении работы приложения
    static func cleanup() {
        lock.lock(); defer { lock.unlock() }
        if let ctx = sharedContext {
            whisper_free(ctx)
            sharedContext = nil
            print("🧹 Whisper context released")
        }
    }
    
    /// Выполняет проверку и инициализацию контекста без проведения транскрипции
    /// - Returns: True если инициализация успешно завершена
    static func preloadModelForShaderCaching() -> Bool {
        lock.lock(); defer { lock.unlock() }
        
        // Если контекст уже существует, просто возвращаем успех
        if sharedContext != nil {
            return true
        }
        
        print("🔄 Preloading Whisper model for shader caching")
        
        #if os(macOS) || os(iOS)
        // Настраиваем постоянный кэш шейдеров Metal
        setupMetalShaderCache()
        #endif
        
        guard let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo-q5_0", withExtension: "bin") else {
            print("❌ Failed to find Whisper model")
            return false
        }
        
        var contextParams = whisper_context_default_params()
        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        
        // Дополнительные оптимизации для Metal
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Оптимизация для размера партии
        setenv("WHISPER_METAL_MEM_MB", "512", 1) // Выделение большего количества памяти для Metal
        #endif
        
        guard let newContext = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            print("❌ Failed to initialize Whisper context")
            return false
        }
        
        sharedContext = newContext
        print("✅ Whisper context initialized successfully")
        return true
    }
    
    /// Performs transcription of audio data received from HTTP request and returns the result
    /// - Parameters:
    ///   - audioData: Binary audio file data
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    /// - Returns: String with transcription result or nil in case of error
    static func transcribeAudioData(_ audioData: Data, language: String? = nil, prompt: String? = nil) -> String? {
        // Получаем или инициализируем контекст
        let context: OpaquePointer
        
        lock.lock()
        if let existingContext = sharedContext {
            context = existingContext
            lock.unlock()
        } else {
            // Инициализируем новый контекст
            print("🔄 Initializing Whisper context (this may take a while on first run)")
            
            #if os(macOS) || os(iOS)
            // Настраиваем постоянный кэш шейдеров Metal
            setupMetalShaderCache()
            #endif
        
            
            guard let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin") else {
                lock.unlock()
                print("❌ Failed to find Whisper model")
                return nil
            }
            
            var contextParams = whisper_context_default_params()
            #if os(macOS) || os(iOS)
            contextParams.use_gpu = true
            contextParams.flash_attn = true
            
            // Дополнительные оптимизации для Metal
            setenv("WHISPER_METAL_NDIM", "128", 1)  // Оптимизация для размера партии
            setenv("WHISPER_METAL_MEM_MB", "512", 1) // Выделение большего количества памяти для Metal
            #endif
            
            guard let newContext = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
                lock.unlock()
                print("❌ Failed to initialize Whisper context")
                return nil
            }
            
            sharedContext = newContext
            context = newContext
            print("✅ Whisper context initialized successfully")
            lock.unlock()
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
        
        return transcription.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Converts audio data to sample array for Whisper
    private static func convertAudioToSamples(_ audioData: Data) -> [Float] {
        // Perform detailed analysis of the audio format
        print("🔍 Analyzing audio data of size \(audioData.count) bytes")
        
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
        
        // Debug first few bytes
        let previewLength = min(16, audioData.count)
        let bytesPreview = audioData.prefix(previewLength).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("🔍 First \(previewLength) bytes: \(bytesPreview)")
        
        if isWav {
            print("✅ Processing WAV format audio")
            let samples = convertWavDataToSamples(audioData)
            print("✅ Converted WAV data to \(samples.count) samples")
            if samples.isEmpty {
                print("⚠️ WAV conversion resulted in 0 samples, attempting raw PCM conversion")
                return convertRawPCMToSamples(audioData)
            }
            return samples
        } else if isMp3 {
            print("⚠️ MP3 format detected but not directly supported. Converting as raw PCM")
            let samples = convertRawPCMToSamples(audioData)
            print("✅ Converted MP3 data to \(samples.count) samples using raw PCM approach")
            return samples
        } else {
            print("⚠️ Unknown audio format, attempting to interpret as raw PCM")
            let samples = convertRawPCMToSamples(audioData)
            print("✅ Converted unknown format to \(samples.count) samples using raw PCM approach")
            return samples
        }
    }
    
    /// Converts WAV data to sample array
    private static func convertWavDataToSamples(_ audioData: Data) -> [Float] {
        return audioData.withUnsafeBytes { rawBufferPointer -> [Float] in
            let headerSize = findWavDataChunk(audioData)
            let bytesPerSample = 2 // 16-bit PCM
            
            print("🔍 WAV header size detected as \(headerSize) bytes")
            
            guard headerSize > 0 && audioData.count > headerSize + bytesPerSample else {
                print("❌ WAV file invalid or too short: header=\(headerSize), total size=\(audioData.count)")
                return []
            }
            
            guard let baseAddress = rawBufferPointer.baseAddress else {
                return []
            }
            
            let dataPtr = baseAddress.advanced(by: headerSize)
            let int16Ptr = dataPtr.assumingMemoryBound(to: Int16.self)
            
            let numSamples = (audioData.count - headerSize) / bytesPerSample
            print("🔍 Creating \(numSamples) samples from WAV data")
            
            var samples = [Float](repeating: 0, count: numSamples)
            
            for i in 0..<numSamples {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
            
            return samples
        }
    }
    
    /// Finds the actual start of audio data in a WAV file by looking for the 'data' chunk
    private static func findWavDataChunk(_ audioData: Data) -> Int {
        // Standard WAV header is 44 bytes, but we'll search for the 'data' chunk to be sure
        guard audioData.count >= 44 else { return 0 }
        
        // Try the standard position first (most common case)
        if audioData.count >= 44 + 4 &&
           audioData[36] == 0x64 && // d
           audioData[37] == 0x61 && // a
           audioData[38] == 0x74 && // t
           audioData[39] == 0x61 {  // a
            // Get the data chunk size (4 bytes after 'data')
            let chunkSizeBytes = [audioData[40], audioData[41], audioData[42], audioData[43]]
            let chunkSize = UInt32(chunkSizeBytes[0]) | (UInt32(chunkSizeBytes[1]) << 8) | 
                           (UInt32(chunkSizeBytes[2]) << 16) | (UInt32(chunkSizeBytes[3]) << 24)
            print("🔍 Found standard WAV header with data chunk size: \(chunkSize) bytes")
            return 44
        }
        
        // Search for the 'data' chunk in the file
        for i in 12..<(audioData.count - 8) {
            if audioData[i] == 0x64 && // d
               audioData[i+1] == 0x61 && // a
               audioData[i+2] == 0x74 && // t
               audioData[i+3] == 0x61 {  // a
                let headerSize = i + 8 // Skip 'data' + 4 bytes of chunk size
                print("🔍 Found WAV data chunk at offset \(i), header size: \(headerSize)")
                return headerSize
            }
        }
        
        print("⚠️ Could not find 'data' chunk in WAV file, using standard 44-byte header")
        return 44 // Default to standard WAV header if we can't find the data chunk
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
