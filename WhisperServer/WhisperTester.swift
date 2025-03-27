import Foundation
import whisper

/// Класс для тестирования функциональности whisper.cpp
class WhisperTester {
    
    /// Выполняет транскрипцию аудиофайла и возвращает результат
    /// - Returns: Строка с результатом транскрипции или nil в случае ошибки
    static func transcribe() -> String? {
        let modelFilename = "ggml-base.en.bin"
        let audioFilename = "jfk.wav"
        
        // Находим необходимые файлы
        guard let modelURL = findResourceFile(named: modelFilename, inSubdirectory: "models"),
              let audioURL = findResourceFile(named: audioFilename) else {
            return nil
        }
        
        // Инициализируем контекст Whisper
        var contextParams = whisper_context_default_params()
        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        #endif
        
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            return nil
        }
        
        defer {
            whisper_free(context)
        }
        
        // Выполняем распознавание речи
        do {
            let audioData = try Data(contentsOf: audioURL)
            
            // Настраиваем параметры
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.no_context = true
            params.single_segment = false
            
            "en".withCString { en in
                params.language = en
            }
            
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
            
            // Преобразуем аудио в формат для Whisper
            let samples = convertWavToSamples(audioData)
            
            // Запускаем транскрипцию
            var result: Int32 = -1
            samples.withUnsafeBufferPointer { samples in
                result = whisper_full(context, params, samples.baseAddress, Int32(samples.count))
            }
            
            if result != 0 {
                return nil
            }
            
            // Собираем результаты
            let numSegments = whisper_full_n_segments(context)
            var transcription = ""
            
            for i in 0..<numSegments {
                transcription += String(cString: whisper_full_get_segment_text(context, i))
            }
            
            return transcription
            
        } catch {
            return nil
        }
    }
    
    /// Выполняет транскрипцию аудиоданных, полученных из HTTP-запроса, и возвращает результат
    /// - Parameters:
    ///   - audioData: Бинарные данные аудиофайла
    ///   - language: Код языка аудио (необязательно, по умолчанию определяется автоматически)
    ///   - prompt: Подсказка для улучшения распознавания (необязательно)
    /// - Returns: Строка с результатом транскрипции или nil в случае ошибки
    static func transcribeAudioData(_ audioData: Data, language: String? = nil, prompt: String? = nil) -> String? {
        let modelFilename = "ggml-base.en.bin"
        
        // Находим модель
        guard let modelURL = findResourceFile(named: modelFilename, inSubdirectory: "models") else {
            print("❌ Не удалось найти модель Whisper")
            return nil
        }
        
        // Инициализируем контекст Whisper
        var contextParams = whisper_context_default_params()
        #if os(macOS) || os(iOS)
        contextParams.use_gpu = true
        #endif
        
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParams) else {
            print("❌ Не удалось инициализировать контекст Whisper")
            return nil
        }
        
        defer {
            whisper_free(context)
        }
        
        do {
            // Настраиваем параметры
            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.print_realtime = false
            params.print_progress = false
            params.print_timestamps = false
            params.print_special = false
            params.translate = false
            params.no_context = true
            params.single_segment = false
            
            // Устанавливаем язык, если он указан
            if let language = language {
                language.withCString { lang in
                    params.language = lang
                }
            }
            
            // Устанавливаем подсказку, если она указана
            if let prompt = prompt {
                prompt.withCString { p in
                    params.initial_prompt = p
                }
            }
            
            params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
            
            // Преобразуем аудио в формат для Whisper
            let samples = convertWavToSamples(audioData)
            
            // Запускаем транскрипцию
            var result: Int32 = -1
            samples.withUnsafeBufferPointer { samples in
                result = whisper_full(context, params, samples.baseAddress, Int32(samples.count))
            }
            
            if result != 0 {
                print("❌ Ошибка при выполнении транскрипции")
                return nil
            }
            
            // Собираем результаты
            let numSegments = whisper_full_n_segments(context)
            var transcription = ""
            
            for i in 0..<numSegments {
                transcription += String(cString: whisper_full_get_segment_text(context, i))
            }
            
            return transcription
            
        } catch {
            print("❌ Произошла ошибка при обработке аудио: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Ищет файл в ресурсах приложения
    private static func findResourceFile(named filename: String, inSubdirectory subdirectory: String? = nil) -> URL? {
        // Имя и расширение файла
        let components = filename.split(separator: ".")
        let name = String(components.first ?? "")
        let ext = components.count > 1 ? String(components.last!) : nil
        
        // Ищем в ресурсах бандла
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
            return url
        }
        
        // Ищем в директории ресурсов
        if let resourceURL = Bundle.main.resourceURL {
            var resourcePath = resourceURL
            if let subdirectory = subdirectory {
                resourcePath = resourcePath.appendingPathComponent(subdirectory)
            }
            let fileURL = resourcePath.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                return fileURL
            }
        }
        
        return nil
    }
    
    /// Преобразует аудио-данные в массив сэмплов для Whisper
    /// Поддерживает WAV-формат и делает базовую проверку формата аудио
    private static func convertWavToSamples(_ audioData: Data) -> [Float] {
        // Проверка WAV заголовка (RIFF)
        let isWav = audioData.count > 12 && 
                    audioData[0] == 0x52 && // R
                    audioData[1] == 0x49 && // I
                    audioData[2] == 0x46 && // F
                    audioData[3] == 0x46    // F
        
        if isWav {
            print("✅ Обнаружен WAV формат аудио")
            return convertWavDataToSamples(audioData)
        } else {
            print("⚠️ Неизвестный формат аудио, попытка интерпретации как raw PCM")
            // Для не-WAV аудио можно попытаться интерпретировать как raw PCM
            // Это может работать, если данные уже в правильном формате
            return convertRawPCMToSamples(audioData)
        }
    }
    
    /// Преобразует WAV-данные в массив сэмплов
    private static func convertWavDataToSamples(_ audioData: Data) -> [Float] {
        return audioData.withUnsafeBytes { bufferPtr -> [Float] in
            let header = 44 // Стандартный размер WAV-заголовка
            let bytesPerSample = 2 // 16-bit PCM
            
            // Проверяем, достаточно ли данных
            guard audioData.count > header + bytesPerSample else {
                print("❌ WAV файл слишком короткий")
                return []
            }
            
            let dataPtr = bufferPtr.baseAddress!.advanced(by: header)
            let int16Ptr = dataPtr.bindMemory(to: Int16.self, capacity: (audioData.count - header) / bytesPerSample)
            
            let numSamples = (audioData.count - header) / bytesPerSample
            var samples = [Float](repeating: 0, count: numSamples)
            
            for i in 0..<numSamples {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
            
            return samples
        }
    }
    
    /// Пытается интерпретировать произвольные аудиоданные как raw PCM
    private static func convertRawPCMToSamples(_ audioData: Data) -> [Float] {
        return audioData.withUnsafeBytes { bufferPtr -> [Float] in
            let bytesPerSample = 2 // Предполагаем 16-bit PCM
            
            // Пропускаем некоторое количество начальных байт, которые могут содержать метаданные
            // Это эвристика, может потребоваться настройка для разных форматов
            let assumedHeaderSize = min(1024, audioData.count / 2) // Пропускаем первые 1024 байта или половину файла
            
            guard audioData.count > assumedHeaderSize + bytesPerSample else {
                print("❌ Аудиофайл слишком короткий")
                return []
            }
            
            let dataPtr = bufferPtr.baseAddress!.advanced(by: assumedHeaderSize)
            let int16Ptr = dataPtr.bindMemory(to: Int16.self, capacity: (audioData.count - assumedHeaderSize) / bytesPerSample)
            
            let numSamples = (audioData.count - assumedHeaderSize) / bytesPerSample
            var samples = [Float](repeating: 0, count: numSamples)
            
            for i in 0..<numSamples {
                samples[i] = Float(int16Ptr[i]) / 32768.0
            }
            
            return samples
        }
    }
} 
