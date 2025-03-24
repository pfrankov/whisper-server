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
        
        do {
            // Создаем TCP параметры
            let parameters = NWParameters.tcp
            
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
            print("❌ Не удалось создать HTTP-сервер: \(error.localizedDescription)")
        }
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
    
    /// Обрабатывает новое соединение
    /// - Parameter connection: Соединение для обработки
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            
            switch state {
            case .ready:
                self.receiveData(from: connection)
                
            case .failed(let error):
                print("❌ Соединение прервано: \(error.localizedDescription)")
                connection.cancel()
                
            default:
                break
            }
        }
        
        connection.start(queue: serverQueue)
    }
    
    /// Получает данные из соединения
    /// - Parameter connection: Соединение, из которого получать данные
    private func receiveData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            
            defer {
                if isComplete {
                    connection.cancel()
                }
            }
            
            if let error = error {
                print("❌ Ошибка при получении данных: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            
            guard let data = data else { return }
            
            if let request = self.parseHTTPRequest(data: data) {
                self.routeRequest(connection: connection, request: request)
            } else {
                self.sendDefaultResponse(to: connection)
            }
        }
    }
    
    // MARK: - Обработка HTTP-запросов
    
    /// Разбирает данные HTTP-запроса
    /// - Parameter data: Необработанные данные запроса
    /// - Returns: Словарь с компонентами запроса или nil, если разбор не удался
    private func parseHTTPRequest(data: Data) -> [String: Any]? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Разделяем запрос на строки
        let lines = requestString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        
        // Получаем строку запроса
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count >= 3 else { return nil }
        
        let method = requestLine[0]
        let path = requestLine[1]
        
        // Разбираем заголовки
        var headers: [String: String] = [:]
        var i = 1
        
        while i < lines.count && !lines[i].isEmpty {
            let headerComponents = lines[i].components(separatedBy: ": ")
            if headerComponents.count >= 2 {
                let key = headerComponents[0]
                let value = headerComponents.dropFirst().joined(separator: ": ")
                headers[key] = value
            }
            i += 1
        }
        
        // Находим тело, если оно есть
        var body: Data?
        if i < lines.count - 1 {
            let bodyStartIndex = requestString.distance(
                from: requestString.startIndex,
                to: requestString.range(of: "\r\n\r\n")?.upperBound ?? requestString.endIndex
            )
            
            if bodyStartIndex < requestString.count {
                let bodyRange = data.index(data.startIndex, offsetBy: bodyStartIndex)..<data.endIndex
                body = data.subdata(in: bodyRange)
            }
        }
        
        return [
            "method": method,
            "path": path,
            "headers": headers,
            "body": body ?? Data()
        ]
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
            sendDefaultResponse(to: connection)
            return
        }
        
        print("📥 Получен \(method) запрос: \(path)")
        
        if path.hasSuffix("/v1/audio/transcriptions") {
            handleTranscriptionRequest(connection: connection, request: request)
        } else {
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
            let contentTypeHeader = headers["Content-Type"],
            let body = request["body"] as? Data
        else {
            sendErrorResponse(to: connection, message: "Неверный запрос")
            return
        }
        
        if !contentTypeHeader.starts(with: "multipart/form-data") {
            sendErrorResponse(to: connection, message: "Content-Type должен быть multipart/form-data")
            return
        }
        
        let whisperRequest = parseMultipartFormData(data: body, contentType: contentTypeHeader)
        
        if whisperRequest.isValid {
            sendTranscriptionResponse(to: connection, format: whisperRequest.responseFormat)
        } else {
            sendErrorResponse(to: connection, message: "Неверный запрос: Отсутствует аудиофайл")
        }
    }
    
    // MARK: - Обработка multipart/form-data
    
    /// Разбирает содержимое multipart/form-data
    /// - Parameters:
    ///   - data: Необработанные multipart данные формы
    ///   - contentType: Значение заголовка Content-Type
    /// - Returns: WhisperAPIRequest, содержащий разобранные поля
    private func parseMultipartFormData(data: Data, contentType: String) -> WhisperAPIRequest {
        var request = WhisperAPIRequest()
        
        // Извлекаем границу из Content-Type
        let boundaryComponents = contentType.components(separatedBy: "boundary=")
        guard boundaryComponents.count > 1 else {
            print("❌ Граница не найдена в Content-Type")
            return request
        }
        
        let boundary = boundaryComponents[1]
        let fullBoundary = "--\(boundary)".data(using: .utf8)!
        let endBoundary = "--\(boundary)--".data(using: .utf8)!
        
        // Создаем сканер данных
        let scanner = BinaryDataScanner(data: data)
        
        // Сканируем части запроса
        while !scanner.isAtEnd {
            // Пропускаем данные до следующей границы
            _ = scanner.scanUpTo(fullBoundary)
            if scanner.isAtEnd { break }
            
            // Найдена граница, пропускаем ее и CRLF
            scanner.skip(fullBoundary.count)
            scanner.skipCRLF()
            
            // Проверяем, не является ли это конечной границей
            if scanner.peek(endBoundary.count) == endBoundary {
                break
            }
            
            // Читаем заголовки
            let headers = readHeaders(scanner: scanner)
            
            // Извлекаем имя поля и имя файла
            guard let (fieldName, filename) = extractFieldInfo(from: headers) else {
                continue
            }
            
            if let filename = filename {
                print("📤 Получен файл: \(filename)")
            }
            
            // Обрабатываем содержимое части
            processPartContent(scanner: scanner, fieldName: fieldName, boundary: fullBoundary, request: &request)
        }
        
        // Проверяем, есть ли валидные аудиоданные
        if let audioData = request.audioData, !audioData.isEmpty {
            print("✅ Успешно разобран аудиофайл размером \(audioData.count) байт")
        } else {
            print("❌ Аудиоданные не найдены в запросе")
        }
        
        return request
    }
    
    /// Читает заголовки из сканера
    /// - Parameter scanner: Бинарный сканер данных
    /// - Returns: Словарь с заголовками
    private func readHeaders(scanner: BinaryDataScanner) -> [String: String] {
        var headers = [String: String]()
        
        while true {
            guard let line = scanner.scanLine(), !line.isEmpty else { break }
            
            let components = line.components(separatedBy: ": ")
            if components.count >= 2 {
                let key = components[0]
                let value = components.dropFirst().joined(separator: ": ")
                headers[key] = value
            }
        }
        
        return headers
    }
    
    /// Извлекает информацию о поле из заголовков
    /// - Parameter headers: Заголовки для анализа
    /// - Returns: Кортеж с именем поля и опционально именем файла
    private func extractFieldInfo(from headers: [String: String]) -> (fieldName: String, filename: String?)? {
        guard let contentDisposition = headers["Content-Disposition"] else {
            return nil
        }
        
        // Извлекаем имя поля
        guard let nameMatch = contentDisposition.range(of: "name=\"([^\"]+)\"", options: .regularExpression) else {
            return nil
        }
        
        let nameStart = contentDisposition.index(nameMatch.lowerBound, offsetBy: 6)
        let nameEnd = contentDisposition.index(nameMatch.upperBound, offsetBy: -1)
        let fieldName = String(contentDisposition[nameStart..<nameEnd])
        
        // Извлекаем имя файла, если есть
        var filename: String?
        if let filenameMatch = contentDisposition.range(of: "filename=\"([^\"]+)\"", options: .regularExpression) {
            let filenameStart = contentDisposition.index(filenameMatch.lowerBound, offsetBy: 10)
            let filenameEnd = contentDisposition.index(filenameMatch.upperBound, offsetBy: -1)
            filename = String(contentDisposition[filenameStart..<filenameEnd])
        }
        
        return (fieldName, filename)
    }
    
    /// Обрабатывает содержимое части multipart/form-data
    /// - Parameters:
    ///   - scanner: Бинарный сканер данных
    ///   - fieldName: Имя поля
    ///   - boundary: Граница части
    ///   - request: Запрос Whisper API для обновления
    private func processPartContent(scanner: BinaryDataScanner, fieldName: String, boundary: Data, request: inout WhisperAPIRequest) {
        let startPos = scanner.position
        
        // Ищем следующую границу
        guard let nextBoundaryPos = scanner.position(of: boundary) else {
            return
        }
        
        // Вычисляем длину содержимого, исключая CRLF перед границей
        let contentLength = nextBoundaryPos - startPos - 2 // -2 для CRLF
        let contentData = scanner.data.subdata(in: startPos..<(startPos + contentLength))
        
        // Обрабатываем различные типы полей
        switch fieldName {
        case "file":
            request.audioData = contentData
            
        case "prompt":
            if let textValue = String(data: contentData, encoding: .utf8) {
                request.prompt = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
        case "response_format":
            if let textValue = String(data: contentData, encoding: .utf8) {
                let format = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                request.responseFormat = ResponseFormat.from(string: format)
            }
            
        case "temperature":
            if let textValue = String(data: contentData, encoding: .utf8),
               let temp = Double(textValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                request.temperature = temp
            }
            
        case "language":
            if let textValue = String(data: contentData, encoding: .utf8) {
                request.language = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
        default:
            if let textValue = String(data: contentData, encoding: .utf8) {
                print("📝 Необработанное поле: \(fieldName) = \(textValue.prefix(50))")
            } else {
                print("📝 Необработанное бинарное поле: \(fieldName)")
            }
        }
        
        // Перемещаем сканер на позицию границы
        scanner.position = nextBoundaryPos
    }
    
    // MARK: - Отправка ответов
    
    /// Отправляет ответ с транскрипцией на соединение
    /// - Parameters:
    ///   - connection: Сетевое соединение
    ///   - format: Формат ответа (json, text и т.д.)
    private func sendTranscriptionResponse(to connection: NWConnection, format: ResponseFormat) {
        let sampleText = "Это пример транскрипции загруженного аудио."
        let (contentType, responseBody) = createResponseBody(format: format, text: sampleText)
        
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
    /// - Returns: Кортеж с типом контента и телом ответа
    private func createResponseBody(format: ResponseFormat, text: String) -> (contentType: String, body: String) {
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
            let verboseResponse: [String: Any] = [
                "task": "transcribe",
                "language": "ru",
                "duration": 10.5,
                "text": text,
                "segments": [
                    [
                        "id": 0,
                        "seek": 0,
                        "start": 0.0,
                        "end": 5.0,
                        "text": "Это пример",
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": 0.0,
                        "avg_logprob": -0.45,
                        "compression_ratio": 1.275,
                        "no_speech_prob": 0.1
                    ],
                    [
                        "id": 1,
                        "seek": 500,
                        "start": 5.0,
                        "end": 10.0,
                        "text": "транскрипции загруженного аудио.",
                        "tokens": [50364, 13, 11, 263, 6116],
                        "temperature": 0.0,
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
            let srtText = """
            1
            00:00:00,000 --> 00:00:05,000
            Это пример
            
            2
            00:00:05,000 --> 00:00:10,000
            транскрипции загруженного аудио.
            """
            return ("text/plain", srtText)
            
        case .vtt:
            let vttText = """
            WEBVTT
            
            00:00:00.000 --> 00:00:05.000
            Это пример
            
            00:00:05.000 --> 00:00:10.000
            транскрипции загруженного аудио.
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
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("❌ Ошибка отправки ответа: \(error.localizedDescription)")
            } else {
                onSuccess()
            }
            
            connection.cancel()
        })
    }
}

// MARK: - BinaryDataScanner

/// Вспомогательный класс для сканирования бинарных данных
private class BinaryDataScanner {
    let data: Data
    var position: Int = 0
    
    var isAtEnd: Bool {
        return position >= data.count
    }
    
    init(data: Data) {
        self.data = data
    }
    
    func peek(_ length: Int) -> Data? {
        guard position + length <= data.count else { return nil }
        return data.subdata(in: position..<(position + length))
    }
    
    func skip(_ length: Int) {
        position = min(position + length, data.count)
    }
    
    func skipCRLF() {
        if position + 2 <= data.count && data[position] == 13 && data[position + 1] == 10 {
            position += 2
        }
    }
    
    func scanLine() -> String? {
        let startPos = position
        
        while position < data.count {
            if position + 1 < data.count && data[position] == 13 && data[position + 1] == 10 {
                let line = String(data: data.subdata(in: startPos..<position), encoding: .utf8) ?? ""
                position += 2  // Пропускаем CRLF
                return line
            }
            position += 1
        }
        
        return nil
    }
    
    func scanUpTo(_ pattern: Data) -> Data? {
        let startPos = position
        
        while position <= data.count - pattern.count {
            var found = true
            for i in 0..<pattern.count {
                if data[position + i] != pattern[i] {
                    found = false
                    break
                }
            }
            
            if found {
                return data.subdata(in: startPos..<position)
            }
            
            position += 1
        }
        
        position = data.count
        return nil
    }
    
    func position(of pattern: Data) -> Int? {
        var searchPos = position
        
        while searchPos <= data.count - pattern.count {
            var found = true
            for i in 0..<pattern.count {
                if data[searchPos + i] != pattern[i] {
                    found = false
                    break
                }
            }
            
            if found {
                return searchPos
            }
            
            searchPos += 1
        }
        
        return nil
    }
} 