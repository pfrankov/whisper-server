//
//  SimpleHTTPServer.swift
//  WhisperServer
//
//  Created by Frankov Pavel on 24.03.2025.
//

import Foundation
import Network

/// HTTP сервер для обработки Whisper API запросов
final class SimpleHTTPServer {
    // MARK: - Types
    
    /// Форматы ответов API
    private enum ResponseFormat: String {
        case json, text, srt, vtt, verbose_json
        
        static func from(string: String?) -> ResponseFormat {
            guard let string = string, !string.isEmpty else { return .json }
            return ResponseFormat(rawValue: string) ?? .json
        }
    }
    
    /// Структура запроса Whisper API
    private struct WhisperAPIRequest {
        var audioData: Data?
        var prompt: String?
        var responseFormat: ResponseFormat = .json
        var temperature: Double = 0.0
        var language: String?
        
        var isValid: Bool {
            return audioData != nil && !audioData!.isEmpty
        }
    }
    
    // MARK: - Properties
    
    /// Порт, на котором слушает сервер
    private let port: UInt16
    
    /// Флаг, показывающий, запущен ли сервер
    private(set) var isRunning = false
    
    /// Сетевой слушатель для приема входящих соединений
    private var listener: NWListener?
    
    /// Очередь для обработки операций сервера
    private let serverQueue = DispatchQueue(label: "com.whisperserver.server", qos: .userInitiated)
    
    // MARK: - Initialization
    
    /// Создает новый экземпляр HTTP-сервера
    /// - Parameter port: Порт, на котором слушать соединения
    init(port: UInt16) {
        self.port = port
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Public Methods
    
    /// Запускает HTTP-сервер
    func start() {
        guard !isRunning else { return }
        
        // Устанавливаем флаг попыток запуска
        let maxRetries = 3
        var retryCount = 0
        var lastError: Error?
        
        func tryStartServer() {
            do {
                // Создаем TCP параметры
                let parameters = NWParameters.tcp
                
                // Устанавливаем таймаут для соединений
                parameters.allowLocalEndpointReuse = true  // Это позволит переиспользовать порт быстрее, если он был недавно закрыт
                parameters.requiredInterfaceType = .loopback  // Слушаем только локальные соединения
                
                // Создаем порт из UInt16
                let port = NWEndpoint.Port(rawValue: self.port)!
                
                // Инициализируем слушатель с параметрами и портом
                listener = try NWListener(using: parameters, on: port)
                
                // Настраиваем обработчики
                configureStateHandler()
                configureConnectionHandler()
                
                // Начинаем слушать соединения
                listener?.start(queue: serverQueue)
                
            } catch {
                lastError = error
                print("❌ Не удалось создать HTTP-сервер: \(error.localizedDescription)")
                
                // Пробуем перезапустить с задержкой, если не превышено максимальное число попыток
                if retryCount < maxRetries {
                    retryCount += 1
                    print("🔄 Повторная попытка запуска сервера (\(retryCount)/\(maxRetries)) через 2 секунды...")
                    
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        tryStartServer()
                    }
                } else {
                    print("❌ Не удалось запустить сервер после \(maxRetries) попыток: \(error.localizedDescription)")
                }
            }
        }
        
        // Запускаем первую попытку
        tryStartServer()
    }
    
    /// Останавливает HTTP-сервер
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        listener?.cancel()
        listener = nil
        print("🛑 HTTP-сервер остановлен")
    }
    
    // MARK: - Настройка слушателя
    
    /// Настраивает обработчик состояния для слушателя
    private func configureStateHandler() {
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.isRunning = true
                print("✅ HTTP-сервер запущен на http://localhost:\(self.port)")
                print("   Whisper API доступен по адресу: http://localhost:\(self.port)/v1/audio/transcriptions")
                
            case .failed(let error):
                print("❌ HTTP-сервер завершился с ошибкой: \(error.localizedDescription)")
                self.stop()
                
            case .cancelled:
                self.isRunning = false
                
            default:
                break
            }
        }
    }
    
    /// Настраивает обработчик новых соединений
    private func configureConnectionHandler() {
        listener?.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            self.handleConnection(connection)
        }
    }
    
    // MARK: - Обработка соединений
    
    /// Обрабатывает входящее сетевое соединение
    /// - Parameter connection: Новое сетевое соединение
    private func handleConnection(_ connection: NWConnection) {
        print("📥 Получено новое соединение")
        
        // Максимальный размер запроса (50 МБ для больших аудиофайлов)
        let maxRequestSize = 50 * 1024 * 1024
        
        // Стартуем соединение
        connection.start(queue: serverQueue)
        
        // Настраиваем обработчик получения данных
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            // Удаляем преждевременное закрытие соединения 
            // defer {
            //     connection.cancel()
            // }
            
            // Обработка ошибок
            if let error = error {
                print("❌ Ошибка при получении данных: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            // Проверка наличия данных
            guard let data = data, !data.isEmpty else {
                print("⚠️ Получены пустые данные")
                self.sendDefaultResponse(to: connection)
                return
            }
            
            print("📥 Получено \(data.count) байт данных")
            
            // Проверка размера запроса
            if data.count > maxRequestSize {
                print("⚠️ Превышен максимальный размер запроса (\(maxRequestSize / 1024 / 1024) MB)")
                self.sendErrorResponse(to: connection, message: "Запрос слишком большой")
                return
            }
            
            // Обработка HTTP-запроса
            if let request = self.parseHTTPRequest(data: data) {
                self.routeRequest(connection: connection, request: request)
            } else {
                print("⚠️ Не удалось распарсить HTTP-запрос")
                self.sendDefaultResponse(to: connection)
            }
        }
    }
    
    // MARK: - Обработка HTTP-запросов
    
    /// Разбирает данные HTTP-запроса
    /// - Parameter data: Необработанные данные запроса
    /// - Returns: Словарь с компонентами запроса или nil, если разбор не удался
    private func parseHTTPRequest(data: Data) -> [String: Any]? {
        print("🔍 Получен HTTP-запрос размером \(data.count) байт")
        
        // Ищем разделитель между заголовками и телом (двойной CRLF: \r\n\r\n)
        let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n в виде данных
        
        // Ищем границу между заголовками и телом
        guard let headerEndIndex = find(pattern: doubleCRLF, in: data) else {
            print("❌ Не удалось найти границу между заголовками и телом запроса")
            return nil
        }
        
        // Извлекаем только заголовки для парсинга текста
        let headersData = data.prefix(headerEndIndex)
        
        // Пытаемся декодировать заголовки как UTF-8 (это должно быть всегда возможно)
        guard let headersString = String(data: headersData, encoding: .utf8) else {
            print("❌ Не удалось декодировать заголовки запроса как UTF-8")
            return nil
        }
        
        print("📋 Заголовки запроса:\n\(headersString)")
        
        // Разделяем заголовки на строки
        let lines = headersString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            print("❌ Запрос не содержит строк")
            return nil
        }
        
        // Парсим строку запроса (первая строка)
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 3 else {
            print("❌ Неверный формат строки запроса: \(lines[0])")
            return nil
        }
        
        let method = requestLine[0]
        let path = requestLine[1]
        
        print("📋 Метод: \(method), Путь: \(path)")
        
        // Парсим заголовки
        var headers: [String: String] = [:]
        
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue } // Пропускаем пустые строки
            
            let headerComponents = line.components(separatedBy: ": ")
            if headerComponents.count >= 2 {
                let key = headerComponents[0]
                let value = headerComponents.dropFirst().joined(separator: ": ")
                headers[key] = value
                print("📋 Заголовок: \(key): \(value)")
            } else {
                print("⚠️ Неверный формат заголовка: \(line)")
            }
        }
        
        // Теперь извлекаем тело запроса (после двойного CRLF)
        let bodyStartIndex = headerEndIndex + doubleCRLF.count
        let body = data.count > bodyStartIndex ? data.subdata(in: bodyStartIndex..<data.count) : Data()
        
        print("✅ Тело запроса успешно извлечено, размер: \(body.count) байт")
        
        // Для multipart/form-data запросов проверяем наличие boundary
        if let contentType = headers["Content-Type"], 
           contentType.starts(with: "multipart/form-data") {
            
            print("📋 Обнаружен multipart/form-data запрос")
            
            // Если отсутствует boundary, пытаемся его определить
            if !contentType.contains("boundary=") {
                print("⚠️ В Content-Type отсутствует boundary, пытаемся определить автоматически")
                
                // Ищем возможный boundary в начале тела (обычно начинается с --)
                if body.count > 2, body[0] == 0x2D, body[1] == 0x2D { // "--" в ASCII
                    // Ищем конец строки с boundary
                    if let boundaryEndIndex = find(pattern: Data([0x0D, 0x0A]), in: body) {
                        let potentialBoundary = body.prefix(boundaryEndIndex)
                        if let boundaryString = String(data: potentialBoundary, encoding: .utf8) {
                            // Удаляем -- в начале
                            let boundary = boundaryString.dropFirst(2)
                            let newContentType = "\(contentType); boundary=\(boundary)"
                            print("✅ Автоматически определен boundary: \(boundary)")
                            headers["Content-Type"] = newContentType
                        }
                    }
                }
            }
        }
        
        return [
            "method": method,
            "path": path,
            "headers": headers,
            "body": body
        ]
    }
    
    /// Вспомогательный метод для поиска шаблона в данных
    /// - Parameters:
    ///   - pattern: Шаблон для поиска
    ///   - data: Данные, в которых искать
    /// - Returns: Индекс начала найденного шаблона или nil, если шаблон не найден
    private func find(pattern: Data, in data: Data) -> Int? {
        // Базовые проверки безопасности
        guard !pattern.isEmpty, !data.isEmpty, pattern.count <= data.count else { 
            return nil 
        }
        
        // Простая реализация алгоритма поиска подстроки
        // Для больших данных стоит рассмотреть более эффективные алгоритмы (KMP, Boyer-Moore)
        let patternLength = pattern.count
        let dataLength = data.count
        
        // Последний возможный индекс, с которого может начинаться шаблон
        let lastPossibleIndex = dataLength - patternLength
        
        for i in 0...lastPossibleIndex {
            var matched = true
            
            for j in 0..<patternLength {
                // Безопасная проверка индексов
                guard i + j < dataLength else {
                    matched = false
                    break
                }
                
                if data[i + j] != pattern[j] {
                    matched = false
                    break
                }
            }
            
            if matched {
                return i
            }
        }
        
        return nil
    }
    
    /// Маршрутизирует запрос к соответствующему обработчику на основе пути
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - request: Разобранный HTTP-запрос
    private func routeRequest(connection: NWConnection, request: [String: Any]) {
        guard 
            let method = request["method"] as? String,
            let path = request["path"] as? String
        else {
            print("❌ Не удалось получить метод или путь запроса")
            sendDefaultResponse(to: connection)
            return
        }
        
        print("📥 Получен \(method) запрос: \(path)")
        
        // Нормализуем путь и проверяем соответствие эндпоинту транскрипции
        let normalizedPath = path.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        print("🔍 Нормализованный путь: \(normalizedPath)")
        
        if normalizedPath.hasSuffix("/v1/audio/transcriptions") || normalizedPath == "/v1/audio/transcriptions" {
            print("✅ Обработка запроса транскрипции")
            handleTranscriptionRequest(connection: connection, request: request)
        } else {
            print("❌ Неизвестный путь: \(path)")
            sendDefaultResponse(to: connection)
        }
    }
    
    // MARK: - Обработка API запросов
    
    /// Обрабатывает запрос транскрипции аудио
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - request: Разобранный HTTP-запрос
    private func handleTranscriptionRequest(connection: NWConnection, request: [String: Any]) {
        guard 
            let headers = request["headers"] as? [String: String],
            let body = request["body"] as? Data
        else {
            print("❌ Ошибка: Невозможно получить заголовки или тело запроса")
            sendErrorResponse(to: connection, message: "Неверный запрос")
            return
        }
        
        // Отладочная информация о размере
        let bodyMB = Double(body.count) / 1024.0 / 1024.0
        print("📊 Размер тела запроса: \(body.count) байт (\(String(format: "%.2f", bodyMB)) MB)")
        
        // Проверка на разумный размер
        if body.count < 100 {
            print("⚠️ Предупреждение: Тело запроса подозрительно маленькое (\(body.count) байт)")
            sendErrorResponse(to: connection, message: "Тело запроса слишком маленькое, возможно, аудиофайл не был передан")
            return
        }
        
        if body.count > 100 * 1024 * 1024 { // > 100 MB
            print("⚠️ Предупреждение: Тело запроса слишком большое (\(String(format: "%.2f", bodyMB)) MB)")
            sendErrorResponse(to: connection, message: "Тело запроса слишком большое, максимальный размер аудиофайла - 100 MB")
            return
        }
        
        // Отладочная информация о заголовках
        print("📋 Полученные заголовки:")
        for (key, value) in headers {
            print("   \(key): \(value)")
        }
        
        // Проверяем Content-Type
        let contentTypeHeader = headers["Content-Type"] ?? ""
        print("📋 Content-Type: \(contentTypeHeader)")
        
        // Засекаем время обработки
        let startTime = Date()
        
        // Создаем запрос в зависимости от типа контента
        var whisperRequest: WhisperAPIRequest
        
        if contentTypeHeader.starts(with: "multipart/form-data") {
            // Стандартный путь обработки multipart/form-data
            print("🔄 Начинаем парсинг multipart/form-data...")
            whisperRequest = parseMultipartFormData(data: body, contentType: contentTypeHeader)
            
            // Если стандартный парсер не справился, пробуем альтернативный подход
            if !whisperRequest.isValid && body.count > 0 {
                print("⚠️ Стандартный парсер не смог извлечь аудиоданные, пробуем альтернативный подход")
                whisperRequest = parseAudioDataDirectly(from: body, contentType: contentTypeHeader)
            }
        } else {
            // Для других типов контента просто используем все тело как аудиоданные
            print("⚠️ Необычный тип контента, пробуем обработать тело как аудиоданные напрямую")
            var request = WhisperAPIRequest()
            request.audioData = body
            whisperRequest = request
        }
        
        // Логируем время, затраченное на парсинг
        let parsingTime = Date().timeIntervalSince(startTime)
        print("⏱️ Время парсинга запроса: \(String(format: "%.2f", parsingTime)) секунд")
        
        if whisperRequest.isValid {
            // Устанавливаем таймаут на соединение для долгих запросов (10 минут)
            let timeoutDispatchItem = DispatchWorkItem {
                // Проверяем состояние соединения
                if case .cancelled = connection.state {
                    return // Соединение уже закрыто
                }
                
                if case .failed(_) = connection.state {
                    return // Соединение уже в ошибке
                }
                
                print("⚠️ Превышено время ожидания транскрипции (10 минут), отменяем запрос")
                self.sendErrorResponse(to: connection, message: "Превышено время ожидания обработки аудио")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeoutDispatchItem)
            
            // Выполняем транскрипцию с использованием Whisper
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { 
                    timeoutDispatchItem.cancel()
                    return 
                }
                
                let transcriptionStartTime = Date()
                
                // Проверяем размер аудиоданных
                if let audioData = whisperRequest.audioData {
                    let sizeMB = Double(audioData.count) / 1024.0 / 1024.0
                    print("🔄 Начинаем транскрипцию аудио размером \(audioData.count) байт (\(String(format: "%.2f", sizeMB)) MB)")
                    
                    // Дополнительная проверка целостности данных
                    if audioData.count < 1000 {
                        print("⚠️ Предупреждение: аудиофайл подозрительно мал, возможно данные были обрезаны")
                    } else {
                        print("✅ Размер аудио данных выглядит нормальным")
                    }
                } else {
                    print("⚠️ Странно, но аудиоданные стали nil, хотя проверка isValid была пройдена")
                }
                
                // Используем наш класс WhisperTester для транскрипции
                print("🔄 Запускаем процесс транскрипции...")
                let transcription = WhisperTester.transcribeAudioData(
                    whisperRequest.audioData!,
                    language: whisperRequest.language,
                    prompt: whisperRequest.prompt
                )
                
                // Отменяем таймаут, так как транскрипция завершена
                timeoutDispatchItem.cancel()
                
                // Вычисляем время транскрипции
                let transcriptionTime = Date().timeIntervalSince(transcriptionStartTime)
                print("⏱️ Время транскрипции: \(String(format: "%.2f", transcriptionTime)) секунд")
                
                // Проверяем, активно ли ещё соединение перед отправкой ответа
                if case .cancelled = connection.state {
                    print("⚠️ Соединение было закрыто во время транскрипции, ответ не отправлен")
                    return
                }
                
                if case .failed(_) = connection.state {
                    print("⚠️ Соединение в ошибочном состоянии, ответ не отправлен")
                    return
                }
                
                DispatchQueue.main.async {
                    if let transcription = transcription {
                        let previewLength = min(100, transcription.count)
                        let previewText = transcription.prefix(previewLength)
                        print("✅ Транскрипция успешно выполнена: \"\(previewText)...\" (\(transcription.count) символов)")
                        self.sendTranscriptionResponse(
                            to: connection,
                            format: whisperRequest.responseFormat,
                            text: transcription,
                            temperature: whisperRequest.temperature
                        )
                    } else {
                        print("❌ Не удалось выполнить транскрипцию")
                        self.sendErrorResponse(
                            to: connection,
                            message: "Ошибка при транскрипции аудио. Убедитесь, что формат аудио поддерживается."
                        )
                    }
                    
                    // Общее время обработки запроса
                    let totalTime = Date().timeIntervalSince(startTime)
                    print("⏱️ Общее время обработки запроса: \(String(format: "%.2f", totalTime)) секунд")
                }
            }
        } else {
            print("❌ Ошибка: Запрос не содержит аудиофайла или другие обязательные данные")
            sendErrorResponse(to: connection, message: "Неверный запрос: Отсутствует аудиофайл")
        }
    }
    
    /// Альтернативный метод для прямого извлечения аудиоданных из запроса
    /// - Parameters:
    ///   - body: Тело запроса
    ///   - contentType: Заголовок Content-Type
    /// - Returns: Запрос WhisperAPI с извлеченными данными
    private func parseAudioDataDirectly(from body: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        print("🔍 Пытаемся определить аудиоданные напрямую из тела размером \(body.count) байт")
        
        // Ищем WAV-заголовок (RIFF)
        func findWavHeader(in data: Data) -> Int? {
            // WAV начинается с "RIFF"
            let riffSignature = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF" в ASCII
            return find(pattern: riffSignature, in: data)
        }
        
        // Ищем MP3-заголовок (ID3 или MPEG frame sync)
        func findMp3Header(in data: Data) -> Int? {
            // ID3 тэг начинается с "ID3"
            let id3Signature = Data([0x49, 0x44, 0x33]) // "ID3" в ASCII
            
            // MPEG frame sync обычно начинается с 0xFF 0xFB или похожих байтов
            let mpegFrameSync = Data([0xFF, 0xFB])
            
            if let id3Position = find(pattern: id3Signature, in: data) {
                return id3Position
            }
            
            return find(pattern: mpegFrameSync, in: data)
        }
        
        // Поиск аудиоданных
        var audioStart: Int? = nil
        
        // Проверяем наличие WAV-заголовка
        if let wavPos = findWavHeader(in: body) {
            print("✅ Найден WAV-заголовок на позиции \(wavPos)")
            audioStart = wavPos
        } 
        // Проверяем наличие MP3-заголовка
        else if let mp3Pos = findMp3Header(in: body) {
            print("✅ Найден MP3-заголовок на позиции \(mp3Pos)")
            audioStart = mp3Pos
        }
        // Если не нашли заголовки, но есть достаточно данных, предполагаем что всё тело - аудио
        else if body.count > 1000 {
            print("⚠️ Аудиозаголовки не найдены, но есть данные - предполагаем, что всё тело может быть аудио")
            audioStart = 0
        }
        
        // Если нашли начало аудиоданных, извлекаем их
        if let start = audioStart {
            request.audioData = body.subdata(in: start..<body.count)
            print("✅ Извлечены аудиоданные размером \(request.audioData?.count ?? 0) байт")
            
            // Добавляем параметры по умолчанию
            request.responseFormat = .json
        }
        
        return request
    }
    
    // MARK: - Обработка multipart/form-data
    
    /// Разбирает содержимое multipart/form-data
    /// - Parameters:
    ///   - data: Необработанные multipart данные формы
    ///   - contentType: Значение заголовка Content-Type
    /// - Returns: WhisperAPIRequest, содержащий разобранные поля
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        print("🔍 Начинаем разбор multipart/form-data размером \(data.count) байт")
        
        // Отладка: выводим первые байты данных в hex формате
        if data.count > 50 {
            let previewBytes = data.prefix(50)
            let hexString = previewBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("🔍 Первые 50 байт: \(hexString)")
        }
        
        // Извлекаем границу из Content-Type
        let boundaryComponents = contentType.components(separatedBy: "boundary=")
        guard boundaryComponents.count > 1 else {
            print("❌ Граница не найдена в Content-Type: \(contentType)")
            return request
        }
        
        // Извлекаем boundary, удаляя кавычки, если они есть
        var boundary = boundaryComponents[1]
        if boundary.contains(";") {
            boundary = boundary.components(separatedBy: ";")[0]
        }
        if boundary.hasPrefix("\"") && boundary.hasSuffix("\"") {
            boundary = String(boundary.dropFirst().dropLast())
        }
        print("✅ Найдена граница: \(boundary)")
        
        // Создаем полную границу и конечную границу как данные
        // ВАЖНО: формат границы в теле: "--boundary" (без \r\n!)
        let fullBoundaryString = "--\(boundary)"
        let endBoundaryString = "--\(boundary)--"
        
        guard let fullBoundary = fullBoundaryString.data(using: .utf8),
              let endBoundary = endBoundaryString.data(using: .utf8) else {
            print("❌ Не удалось создать границы как данные")
            return request
        }
        
        print("🔍 Полная граница: \(fullBoundaryString)")
        print("🔍 Конечная граница: \(endBoundaryString)")
        
        // Отладка: поиск границы в первых 100 байтах
        if data.count > 100 {
            let searchRange = data.prefix(100)
            if let firstBoundaryPos = find(pattern: fullBoundary, in: searchRange) {
                print("✅ Найдена первая граница на позиции \(firstBoundaryPos)")
                
                // Выводим 10 байт до и после границы для проверки
                let startIdx = max(0, firstBoundaryPos - 10)
                let endIdx = min(searchRange.count, firstBoundaryPos + fullBoundary.count + 10)
                let contextData = searchRange.subdata(in: startIdx..<endIdx)
                let hexContext = contextData.map { String(format: "%02x", $0) }.joined(separator: " ")
                print("🔍 Контекст границы: \(hexContext)")
            } else {
                print("❌ Граница не найдена в первых 100 байтах")
            }
        }
        
        // Ищем все вхождения границы в данных
        var boundaryPositions: [Int] = []
        
        // Сначала ищем первую границу
        if let firstPosition = find(pattern: fullBoundary, in: data) {
            boundaryPositions.append(firstPosition)
            
            // Теперь ищем последующие границы
            var currentPosition = firstPosition + fullBoundary.count
            
            while currentPosition < data.count - fullBoundary.count {
                if let nextPosition = find(pattern: fullBoundary, in: data.subdata(in: currentPosition..<data.count)) {
                    let absolutePosition = currentPosition + nextPosition
                    boundaryPositions.append(absolutePosition)
                    currentPosition = absolutePosition + fullBoundary.count
                } else {
                    break
                }
            }
        }
        
        // Также проверяем наличие конечной границы
        if let endBoundaryPosition = find(pattern: endBoundary, in: data) {
            boundaryPositions.append(endBoundaryPosition)
        }
        
        print("🔍 Найдено \(boundaryPositions.count) границ в данных: \(boundaryPositions)")
        
        // Если нет границ, не можем продолжать
        if boundaryPositions.isEmpty {
            print("❌ Границы не найдены в данных")
            return request
        }
        
        // Обрабатываем каждую часть между границами
        for i in 0..<(boundaryPositions.count - 1) {
            // Начальная позиция части (пропускаем границу и CRLF после неё)
            let partStart = boundaryPositions[i] + fullBoundary.count + 2 // +2 для \r\n после границы
            let partEnd = boundaryPositions[i + 1]
            
            if partStart >= partEnd || partStart >= data.count {
                print("⚠️ Пустая или некорректная часть между границами \(i) и \(i+1): \(partStart) - \(partEnd)")
                continue
            }
            
            let partData = data.subdata(in: partStart..<partEnd)
            print("🔍 Обработка части #\(i+1) размером \(partData.count) байт")
            
            // Ищем разделитель между заголовками и содержимым части (двойной CRLF)
            let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
            
            guard let headerEndIndex = find(pattern: doubleCRLF, in: partData) else {
                print("❌ Не удалось найти заголовки в части #\(i+1)")
                continue
            }
            
            // Извлекаем заголовки
            let headersData = partData.prefix(headerEndIndex)
            guard let headersString = String(data: headersData, encoding: .utf8) else {
                print("❌ Не удалось декодировать заголовки части #\(i+1)")
                continue
            }
            
            // Преобразуем заголовки в словарь
            var headers: [String: String] = [:]
            
            let headerLines = headersString.components(separatedBy: "\r\n")
            for line in headerLines where !line.isEmpty {
                let headerComponents = line.components(separatedBy: ": ")
                if headerComponents.count >= 2 {
                    let key = headerComponents[0]
                    let value = headerComponents.dropFirst().joined(separator: ": ")
                    headers[key] = value
                }
            }
            
            print("📋 Заголовки части #\(i+1):")
            for (key, value) in headers {
                print("   \(key): \(value)")
            }
            
            // Извлекаем информацию о поле из Content-Disposition
            guard let contentDisposition = headers["Content-Disposition"],
                  let fieldName = extractFieldName(from: contentDisposition) else {
                print("❌ Не удалось извлечь имя поля из заголовка Content-Disposition")
                continue
            }
            
            print("📋 Имя поля: \(fieldName)")
            
            // Извлекаем имя файла, если оно есть
            let filename = extractFilename(from: contentDisposition)
            if let filename = filename {
                print("📋 Имя файла: \(filename)")
            }
            
            // Извлекаем содержимое части (после заголовков)
            let contentStartIndex = headerEndIndex + doubleCRLF.count
            
            if contentStartIndex < partData.count {
                let contentData = partData.subdata(in: contentStartIndex..<partData.count)
                print("📋 Размер содержимого поля \(fieldName): \(contentData.count) байт")
                
                // Обрабатываем различные типы полей
                processFieldContent(fieldName: fieldName, data: contentData, request: &request)
            } else {
                print("⚠️ Пустое содержимое для поля \(fieldName)")
            }
        }
        
        // Проверяем, есть ли валидные аудиоданные
        if let audioData = request.audioData, !audioData.isEmpty {
            print("✅ Успешно разобран аудиофайл размером \(audioData.count) байт")
        } else {
            print("❌ Аудиоданные не найдены в запросе")
        }
        
        return request
    }
    
    /// Извлекает имя поля из заголовка Content-Disposition
    /// - Parameter contentDisposition: Значение заголовка Content-Disposition
    /// - Returns: Имя поля или nil, если не удалось извлечь
    private func extractFieldName(from contentDisposition: String) -> String? {
        guard let nameMatch = contentDisposition.range(of: "name=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let nameStart = contentDisposition.index(nameMatch.lowerBound, offsetBy: 6)
        let nameEnd = contentDisposition.index(nameMatch.upperBound, offsetBy: -1)
        return String(contentDisposition[nameStart..<nameEnd])
    }
    
    /// Извлекает имя файла из заголовка Content-Disposition
    /// - Parameter contentDisposition: Значение заголовка Content-Disposition
    /// - Returns: Имя файла или nil, если файла нет
    private func extractFilename(from contentDisposition: String) -> String? {
        guard let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let filenameStart = contentDisposition.index(filenameMatch.lowerBound, offsetBy: 10)
        let filenameEnd = contentDisposition.index(filenameMatch.upperBound, offsetBy: -1)
        return String(contentDisposition[filenameStart..<filenameEnd])
    }
    
    /// Обрабатывает содержимое поля формы
    /// - Parameters:
    ///   - fieldName: Имя поля
    ///   - data: Данные содержимого
    ///   - request: Запрос для обновления
    private func processFieldContent(fieldName: String, data: Data, request: inout WhisperAPIRequest) {
        // Показываем начало данных (если возможно как текст)
        let previewSize = min(20, data.count)
        if let textPreview = String(data: data.prefix(previewSize), encoding: .utf8) {
            print("🔍 Начало содержимого \(fieldName) (текст): \(textPreview)")
        } else {
            print("🔍 Бинарные данные для поля \(fieldName)")
        }
        
        // Обрабатываем различные типы полей
        switch fieldName {
        case "file":
            request.audioData = data
            let sizeMB = Double(data.count) / 1024.0 / 1024.0
            print("✅ Установлены аудиоданные размером \(data.count) байт (\(String(format: "%.2f", sizeMB)) MB)")
            
            // Проверка наличия корректных аудиоданных
            if data.count < 1000 {
                print("⚠️ Предупреждение: аудиофайл слишком мал (\(data.count) байт), возможно, данные обрезаны")
            } else if data.count > 5 * 1024 * 1024 {
                print("ℹ️ Информация: обрабатываем большой аудиофайл (\(String(format: "%.2f", sizeMB)) MB)")
            }
            
        case "prompt":
            if let textValue = String(data: data, encoding: .utf8) {
                let prompt = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.prompt = prompt
                print("✅ Установлена подсказка: \(prompt)")
            } else {
                print("❌ Не удалось декодировать содержимое подсказки как текст")
            }
            
        case "response_format":
            if let textValue = String(data: data, encoding: .utf8) {
                let format = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.responseFormat = ResponseFormat.from(string: format)
                print("✅ Установлен формат ответа: \(format)")
            } else {
                print("❌ Не удалось декодировать формат ответа как текст")
            }
            
        case "temperature":
            if let textValue = String(data: data, encoding: .utf8),
               let temp = Double(textValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                request.temperature = temp
                print("✅ Установлена температура: \(temp)")
            } else {
                print("❌ Не удалось декодировать температуру как число")
            }
            
        case "language":
            if let textValue = String(data: data, encoding: .utf8) {
                let language = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.language = language
                print("✅ Установлен язык: \(language)")
            } else {
                print("❌ Не удалось декодировать язык как текст")
            }
            
        case "model":
            if let textValue = String(data: data, encoding: .utf8) {
                let model = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                print("✅ Получена модель: \(model) (игнорируется)")
                // Просто логируем, не используем, так как мы используем встроенную модель
            } else {
                print("❌ Не удалось декодировать модель как текст")
            }
            
        default:
            if let textValue = String(data: data, encoding: .utf8) {
                print("📝 Необработанное поле: \(fieldName) = \(textValue.prefix(50))")
            } else {
                print("📝 Необработанное бинарное поле: \(fieldName) размером \(data.count) байт")
            }
        }
    }
    
    // MARK: - Отправка ответов
    
    /// Отправляет ответ с транскрипцией на соединение
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - format: Формат ответа (json, text и т.д.)
    ///   - text: Текст транскрипции
    ///   - temperature: Температура, использованная при генерации
    private func sendTranscriptionResponse(
        to connection: NWConnection, 
        format: ResponseFormat, 
        text: String,
        temperature: Double
    ) {
        // Получаем тело ответа и тип контента
        let (contentType, responseBody) = createResponseBody(format: format, text: text, temperature: temperature)
        
        // Логируем информацию о формате ответа
        print("📤 Отправляем ответ в формате \(format.rawValue) (\(contentType))")
        
        // Выводим размер ответа
        let responseSizeKB = Double(responseBody.utf8.count) / 1024.0
        print("📤 Размер ответа: \(responseBody.utf8.count) байт (\(String(format: "%.2f", responseSizeKB)) KB)")
        
        // Выводим превью текста транскрипции
        let previewLength = min(50, text.count)
        let textPreview = text.prefix(previewLength)
        print("📝 Превью текста: \"\(textPreview)\(text.count > previewLength ? "..." : "")\"")
        
        // Отправляем HTTP-ответ
        sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: contentType,
            body: responseBody,
            onSuccess: { print("✅ Ответ API Whisper успешно отправлен") }
        )
    }
    
    /// Создает тело ответа в нужном формате
    /// - Parameters:
    ///   - format: Требуемый формат ответа
    ///   - text: Текст транскрипции
    ///   - temperature: Температура, использованная при генерации
    /// - Returns: Кортеж с типом контента и телом ответа
    private func createResponseBody(format: ResponseFormat, text: String, temperature: Double = 0.0) -> (contentType: String, body: String) {
        switch format {
        case .json:
            let jsonResponse: [String: Any] = ["text": text]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: jsonResponse),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ("application/json", jsonString)
            } else {
                return ("application/json", "{\"text\": \"Ошибка создания JSON-ответа\"}")
            }
            
        case .verbose_json:
            // Разбиваем текст на два сегмента для примера
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            // Оцениваем длительность аудио (приблизительно)
            let estimatedDuration = Double(text.count) / 20.0 // примерная оценка
            
            let verboseResponse: [String: Any] = [
                "task": "transcribe",
                "language": "auto", // определяется автоматически
                "duration": estimatedDuration,
                "text": text,
                "segments": [
                    [
                        "id": 0,
                        "seek": 0,
                        "start": 0.0,
                        "end": estimatedDuration / 2.0,
                        "text": firstSegment,
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": temperature,
                        "avg_logprob": -0.45,
                        "compression_ratio": 1.275,
                        "no_speech_prob": 0.1
                    ],
                    [
                        "id": 1,
                        "seek": 500,
                        "start": estimatedDuration / 2.0,
                        "end": estimatedDuration,
                        "text": secondSegment,
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": temperature,
                        "avg_logprob": -0.45,
                        "compression_ratio": 1.275,
                        "no_speech_prob": 0.1
                    ]
                ]
            ]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: verboseResponse),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return ("application/json", jsonString)
            } else {
                return ("application/json", "{\"text\": \"Ошибка создания подробного JSON-ответа\"}")
            }
            
        case .text:
            return ("text/plain", text)
            
        case .srt:
            // Разбиваем текст на сегменты для создания субтитров
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let estimatedDuration = Double(text.count) / 20.0 // примерная оценка
            let midpoint = estimatedDuration / 2.0
            
            let srtText = """
            1
            00:00:00,000 --> 00:00:\(String(format: "%.3f", midpoint).replacingOccurrences(of: ".", with: ","))000
            \(firstSegment)
            
            2
            00:00:\(String(format: "%.3f", midpoint).replacingOccurrences(of: ".", with: ","))000 --> 00:00:\(String(format: "%.3f", estimatedDuration).replacingOccurrences(of: ".", with: ","))000
            \(secondSegment)
            """
            return ("text/plain", srtText)
            
        case .vtt:
            // Разбиваем текст на сегменты для создания субтитров
            let words = text.components(separatedBy: " ")
            let halfIndex = max(1, words.count / 2)
            let firstSegment = words[0..<halfIndex].joined(separator: " ")
            let secondSegment = words[halfIndex..<words.count].joined(separator: " ")
            
            let estimatedDuration = Double(text.count) / 20.0 // примерная оценка
            let midpoint = estimatedDuration / 2.0
            
            let vttText = """
            WEBVTT
            
            00:00:00.000 --> 00:00:\(String(format: "%.3f", midpoint))
            \(firstSegment)
            
            00:00:\(String(format: "%.3f", midpoint)) --> 00:00:\(String(format: "%.3f", estimatedDuration))
            \(secondSegment)
            """
            return ("text/plain", vttText)
        }
    }
    
    /// Отправляет ответ об ошибке
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - message: Сообщение об ошибке
    private func sendErrorResponse(to connection: NWConnection, message: String) {
        let errorResponse: [String: Any] = [
            "error": [
                "message": message,
                "type": "invalid_request_error"
            ]
        ]
        
        var responseBody = "{\"error\": {\"message\": \"Внутренняя ошибка сервера\"}}"
        if let jsonData = try? JSONSerialization.data(withJSONObject: errorResponse),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            responseBody = jsonString
        }
        
        sendHTTPResponse(
            to: connection,
            statusCode: 400,
            statusMessage: "Bad Request",
            contentType: "application/json",
            body: responseBody,
            onSuccess: { print("✅ Ответ с ошибкой отправлен") }
        )
    }
    
    /// Отправляет стандартный ответ "OK"
    /// - Parameter connection: Соединение для отправки ответа
    private func sendDefaultResponse(to connection: NWConnection) {
        sendHTTPResponse(
            to: connection,
            statusCode: 200,
            statusMessage: "OK",
            contentType: "text/plain",
            body: "OK",
            onSuccess: { print("✅ Стандартный ответ отправлен") }
        )
    }
    
    /// Отправляет HTTP-ответ на соединение
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - statusCode: Код статуса HTTP
    ///   - statusMessage: Сообщение о статусе HTTP
    ///   - contentType: Тип содержимого
    ///   - body: Тело ответа
    ///   - onSuccess: Замыкание, вызываемое при успешной отправке
    private func sendHTTPResponse(
        to connection: NWConnection,
        statusCode: Int,
        statusMessage: String,
        contentType: String,
        body: String,
        onSuccess: @escaping () -> Void
    ) {
        let contentLength = body.utf8.count
        let response = """
        HTTP/1.1 \(statusCode) \(statusMessage)
        Content-Type: \(contentType)
        Content-Length: \(contentLength)
        Connection: close
        
        \(body)
        """
        
        let responseData = Data(response.utf8)
        
        // Добавляем проверку состояния соединения перед отправкой данных
        if case .cancelled = connection.state {
            print("⚠️ Попытка отправить данные через закрытое соединение")
            return
        }
        
        if case .failed(_) = connection.state {
            print("⚠️ Попытка отправить данные через ошибочное соединение")
            return
        }
        
        // Определим timeout на основе размера ответа. Даем больше времени для больших ответов.
        let timeoutSeconds: TimeInterval = min(5.0, Double(contentLength) / 10000 + 1.0)
        print("🕒 Установлен таймаут на отправку ответа: \(String(format: "%.1f", timeoutSeconds)) секунд")
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Ошибка отправки ответа: \(error.localizedDescription)")
            } else {
                onSuccess()
                print("✅ Ответ успешно обработан, размер: \(contentLength) байт")
            }
            
            // Задержка перед закрытием соединения для обеспечения отправки данных
            // Используем более продолжительную задержку для больших ответов
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
                // Проверяем состояние соединения
                if case .cancelled = connection.state {
                    // Соединение уже закрыто
                    return
                }
                
                print("🔄 Закрываем соединение после отправки данных")
                connection.cancel()
            }
        })
    }
} 