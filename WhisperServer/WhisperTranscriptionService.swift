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
    
    /// Название нотификации об активации Metal
    static let metalActivatedNotificationName = NSNotification.Name("WhisperMetalActivated")
    
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
    
    /// Получает примерное использование памяти (в МБ) для логирования
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
    
    /// Принудительно освобождает и переинициализирует контекст Whisper при смене модели
    static func reinitializeContext() {
        // Освобождаем текущий контекст, если он существует
        lock.lock()
        let memoryBefore = getMemoryUsage()
        if let ctx = sharedContext {
            whisper_free(ctx)
            sharedContext = nil
            let memoryAfter = getMemoryUsage()
            let freed = max(0, memoryBefore - memoryAfter)
            print("🔄 Whisper context released for model change, freed ~\(freed) MB")
        } else {
            print("ℹ️ No Whisper context to release for model change")
        }
        lock.unlock()
        
        // Reset the inactivity timer
        DispatchQueue.main.async {
            inactivityTimer?.invalidate()
            inactivityTimer = nil
        }
        
        // Контекст будет переинициализирован при следующем вызове transcribeAudioData
        // или preloadModelForShaderCaching автоматически
        print("✅ Context will be reinitialized on next use with new model")
    }
    
    /// Выполняет проверку и инициализацию контекста без проведения транскрипции
    /// - Returns: True если инициализация успешно завершена
    static func preloadModelForShaderCaching(modelBinPath: URL? = nil, modelEncoderDir: URL? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        
        // Если контекст уже существует, просто возвращаем успех
        if sharedContext != nil {
            print("✅ Context already initialized, reusing")
            return true
        }
        
        print("🔄 Preloading Whisper model for shader caching")
        
        #if os(macOS) || os(iOS)
        // Настраиваем постоянный кэш шейдеров Metal
        setupMetalShaderCache()
        #endif
        
        // Get model paths either from parameters or try to get from AppDelegate
        var binPath: URL?
        
        if let providedBinPath = modelBinPath {
            // Use directly provided path 
            binPath = providedBinPath
        } else {
            // Fallback to getting from AppDelegate - but now this won't be called from background thread
            print("🔄 Attempting to get paths from ModelManager via AppDelegate...")
            DispatchQueue.main.sync {
                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                    if let modelPaths = appDelegate.modelManager.getPathsForSelectedModel() {
                        binPath = modelPaths.binPath
                    }
                }
            }
        }
        
        guard let binPath = binPath else {
            print("❌ Failed to get model bin path")
            return false
        }
        
        print("📂 Using model file at: \(binPath.path)")
        
        // Verify file exists and can be accessed
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: binPath.path) {
            print("❌ Model file doesn't exist at: \(binPath.path)")
            return false
        }
        
        if !fileManager.isReadableFile(atPath: binPath.path) {
            print("❌ Model file isn't readable at: \(binPath.path)")
            return false
        }
        
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: binPath.path, isDirectory: &isDirectory) && isDirectory.boolValue {
            print("❌ Path exists but is a directory, not a file: \(binPath.path)")
            return false
        }
        
        // Log file size for debugging
        do {
            let attributes = try fileManager.attributesOfItem(atPath: binPath.path)
            if let fileSize = attributes[.size] as? UInt64 {
                print("📄 File size: \(fileSize) bytes")
                if fileSize < 1000000 { // At least 1MB for a model file
                    print("⚠️ Warning: Model file is suspiciously small")
                }
            } else {
                print("📄 File size: unknown")
            }
        } catch {
            print("📄 File size: could not be determined - \(error.localizedDescription)")
        }
        
        // Additional verification: try to read a bit of the file
        do {
            let fileHandle = try FileHandle(forReadingFrom: binPath)
            let header = try fileHandle.read(upToCount: 16)
            try fileHandle.close()
            
            if header == nil || header!.isEmpty {
                print("❌ Could not read file header - file may be empty or inaccessible")
                return false
            }
            
            print("✅ Successfully read file header")
        } catch {
            print("❌ Error reading file: \(error.localizedDescription)")
            return false
        }
        
        var contextParams = whisper_context_default_params()
        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        contextParams.flash_attn = true
        
        // Дополнительные оптимизации для Metal
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Оптимизация для размера партии
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Выделение большего количества памяти для Metal
        print("🔧 Metal settings: NDIM=128, MEM_MB=1024")
        #endif
        
        print("🔄 Initializing Whisper context with file...")
        let contextResult = whisper_init_from_file_with_params(binPath.path, contextParams)
        
        if contextResult == nil {
            print("❌ Failed to initialize Whisper context - null result returned")
            return false
        }
        
        sharedContext = contextResult
        print("✅ Whisper context initialized successfully")
        return true
    }
    
    /// Инициализирует контекст Whisper с явно переданными путями к модели
    private static func initializeContext(binPath: URL) -> OpaquePointer? {
        print("🔄 Initializing Whisper context with provided model path")
        
        #if os(macOS) || os(iOS)
        // Настраиваем постоянный кэш шейдеров Metal
        setupMetalShaderCache()
        #endif
        
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
        
        // Дополнительные оптимизации для Metal
        setenv("WHISPER_METAL_NDIM", "128", 1)  // Оптимизация для размера партии
        setenv("WHISPER_METAL_MEM_MB", "1024", 1) // Выделение большего количества памяти для Metal
        print("🔧 Metal settings: NDIM=128, MEM_MB=1024")
        #endif
        
        print("🔄 Initializing Whisper context with file...")
        guard let newContext = whisper_init_from_file_with_params(binPath.path, contextParams) else {
            print("❌ Failed to initialize Whisper context")
            return nil
        }
        
        print("✅ Whisper context initialized successfully")
        return newContext
    }
    
    /// Performs transcription of audio data received from HTTP request and returns the result
    /// - Parameters:
    ///   - audioData: Binary audio file data
    ///   - language: Audio language code (optional, by default determined automatically)
    ///   - prompt: Prompt to improve recognition (optional)
    ///   - modelPaths: Optional model paths to use for initialization if context doesn't exist
    /// - Returns: String with transcription result or nil in case of error
    static func transcribeAudioData(_ audioData: Data, language: String? = nil, prompt: String? = nil, modelPaths: (binPath: URL, encoderDir: URL)? = nil) -> String? {
        // Reset the inactivity timer since we're using Whisper now
        resetInactivityTimer()
        
        // Extract model name for logging
        let modelName = extractModelNameFromPath(modelPaths?.binPath)
        
        // Получаем или инициализируем контекст
        let context: OpaquePointer
        let isNewContext: Bool
        
        lock.lock()
        
        // Check if we have an existing context
        if let existingContext = sharedContext {
            print("✅ Using existing Whisper context for model: \(modelName ?? "Unknown")")
            context = existingContext
            isNewContext = false
            lock.unlock()
        } else {
            // We need to initialize a new context
            print("🔄 Initializing new Whisper context for model: \(modelName ?? "Unknown")")
            let memoryBefore = getMemoryUsage()
            
            // Determine how to get model paths - either use the provided paths or fail
            if let paths = modelPaths {
                print("🔄 Using provided model paths for initialization")
                
                // Verify that the files exist and are readable
                let fileManager = FileManager.default
                if !fileManager.fileExists(atPath: paths.binPath.path) {
                    lock.unlock()
                    print("❌ Model bin file does not exist at path: \(paths.binPath.path)")
                    return nil
                }
                
                if !fileManager.isReadableFile(atPath: paths.binPath.path) {
                    lock.unlock()
                    print("❌ Model bin file is not readable at path: \(paths.binPath.path)")
                    return nil
                }
                
                // Initialize context with the provided bin path
                guard let newContext = initializeContext(binPath: paths.binPath) else {
                    lock.unlock()
                    print("❌ Failed to initialize Whisper context with provided paths")
                    return nil
                }
                
                sharedContext = newContext
                context = newContext
                isNewContext = true
                
                let memoryAfter = getMemoryUsage()
                let used = max(0, memoryAfter - memoryBefore)
                print("✅ Successfully initialized new Whisper context, using ~\(used) MB")
                
                // Отправляем нотификацию о том, что Metal активирован
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: metalActivatedNotificationName,
                        object: nil,
                        userInfo: ["modelName": modelName ?? "Unknown"]
                    )
                }
                
                lock.unlock()
            } else {
                // We don't have model paths and we're in a background thread - cannot proceed
                lock.unlock()
                print("❌ No model paths provided and cannot access AppDelegate from background thread")
                return nil
            }
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
