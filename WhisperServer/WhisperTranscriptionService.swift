import Foundation
import whisper
#if os(macOS) || os(iOS)
import SwiftUI
import AVFoundation
#endif

/// Audio transcription service using whisper.cpp
struct WhisperTranscriptionService {
    // MARK: - Audio Conversion
    
    /// Handles conversion of various audio formats to 16-bit, 16kHz mono WAV required by Whisper
    class AudioConverter {
        /// Converts audio data from any supported format to the format required by Whisper
        /// - Parameter audioData: Original audio data in any format (mp3, m4a, ogg, wav, etc.)
        /// - Returns: Converted audio data as PCM 16-bit 16kHz mono samples, or nil if conversion failed
        static func convertToWhisperFormat(_ audioData: Data) -> [Float]? {
            #if os(macOS) || os(iOS)
            return convertUsingAVFoundation(audioData)
            #else
            print("❌ Audio conversion is only supported on macOS and iOS")
            return nil
            #endif
        }
        
        #if os(macOS) || os(iOS)
        /// Converts audio using AVFoundation framework - unified approach for all formats
        private static func convertUsingAVFoundation(_ audioData: Data) -> [Float]? {
            print("🔄 Converting audio to Whisper format (16kHz mono float)")
            
            // Target format: 16kHz mono float
            let targetSampleRate = 16000.0
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: targetSampleRate,
                                           channels: 1,
                                           interleaved: false)!
            
            // Create a temporary file for the input audio
            let tempInputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".audio")
            
            do {
                // Write input data to temporary file
                try audioData.write(to: tempInputURL)
                
                defer {
                    // Clean up temporary file
                    try? FileManager.default.removeItem(at: tempInputURL)
                }
                
                // Try to create an AVAudioFile from the data
                guard let audioFile = try? AVAudioFile(forReading: tempInputURL) else {
                    print("❌ Failed to create AVAudioFile for reading")
                    return nil
                }
                
                let sourceFormat = audioFile.processingFormat
                print("🔍 Source format: \(sourceFormat.sampleRate)Hz, \(sourceFormat.channelCount) channels")
                
                // Convert the audio file to the required format
                return convertAudioFile(audioFile, toFormat: outputFormat)
            } catch {
                print("❌ Failed during audio file preparation: \(error.localizedDescription)")
                return nil
            }
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
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Выделение большего количества памяти для Metal
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
            setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Выделение большего количества памяти для Metal
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
        
        // Convert audio to samples for Whisper using the new converter
        guard let samples = AudioConverter.convertToWhisperFormat(audioData) else {
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
}
