import Cocoa
import SwiftUI

// Класс для генерации иконки приложения
class IconGenerator {
    private let outputDirectory: String
    
    init(outputDirectory: String) {
        self.outputDirectory = outputDirectory
        
        // Создаем директорию, если она не существует
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputDirectory) {
            try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        }
    }
    
    // Генерация мастер-иконки
    func generateIcons() {
        print("🚀 Генерация мастер-иконки...")
        
        // Создаем исходное изображение 1024x1024 для наилучшего качества масштабирования
        guard let sourceImage = createSourceImage(size: NSSize(width: 1024, height: 1024)) else {
            print("❌ Ошибка: Не удалось создать исходное изображение")
            return
        }
        
        // Сохраняем мастер-изображение
        save(image: sourceImage, filename: "app_icon_master.png")
        
        // Создаем Contents.json
        createContentsJson()
        
        print("✅ Мастер-иконка успешно создана в \(outputDirectory)")
    }
    
    // Создание исходного изображения
    private func createSourceImage(size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        
        image.lockFocus()
        
        // Настраиваем контекст рисования
        if NSGraphicsContext.current == nil {
            image.unlockFocus()
            return nil
        }
        
        // Рисуем градиентный фон с новыми цветами (более темный синий и фиолетовый)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.13, green: 0.18, blue: 0.35, alpha: 1), // #212958 (темно-синий)
            NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.36, alpha: 1)  // #3D295C (темно-фиолетовый)
        ])
        
        // Создаем скругленный прямоугольник для градиента
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let bezierPath = NSBezierPath(roundedRect: rect, xRadius: size.width * 0.25, yRadius: size.height * 0.25)
        
        // Заполняем скругленный прямоугольник градиентом
        gradient?.draw(in: bezierPath, angle: 135)
        
        // Рисуем SF Symbol "waveform" вместо emoji
        if let waveformImage = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) {
            // Создаем конфигурацию для лучшего качества SF Symbol при масштабировании
            let configuration = NSImage.SymbolConfiguration(pointSize: size.width * 0.6, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])) // Явно задаем белый цвет
            
            // Применяем конфигурацию к изображению
            let configuredImage = waveformImage.withSymbolConfiguration(configuration) ?? waveformImage
            
            // Превращаем в template image для применения цвета
            let templateImage = configuredImage.copy() as! NSImage
            templateImage.isTemplate = true
            
            // Масштабируем SF Symbol до нужного размера (примерно 60% от размера иконки)
            let iconSize = size.width * 0.6
            
            // Создаем контекст и конфигурируем его для отрисовки
            let imageRect = NSRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )
            
            // Применяем белый цвет к иконке
            NSColor.white.set()
            
            // Устанавливаем высокое качество интерполяции для сглаживания
            NSGraphicsContext.current?.imageInterpolation = .high
            
            // Рисуем template image с белым цветом
            templateImage.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            
            // Если SF Symbol всё ещё выглядит тёмным, дублируем его для усиления яркости
            templateImage.draw(in: imageRect, from: .zero, operation: .plusLighter, fraction: 0.5)
        } else {
            // Резервный вариант: рисуем звуковую волну вручную, если SF Symbol не доступен
            drawCustomWaveform(in: NSGraphicsContext.current?.cgContext, size: size)
        }
        
        image.unlockFocus()
        
        return image
    }
    
    // Метод для ручной отрисовки звуковой волны (используется как резервный вариант)
    private func drawCustomWaveform(in context: CGContext?, size: NSSize) {
        // Устанавливаем чисто белый цвет для линий звуковой волны
        NSColor.white.setStroke()
        
        // Настройки для линий
        let lineWidth: CGFloat = max(3.0, size.width * 0.015) // Увеличиваем толщину для лучшей заметности
        let spacing: CGFloat = size.width * 0.04 // Расстояние между линиями
        let centerX = size.width / 2
        let centerY = size.height / 2
        let maxHeight = size.height * 0.4 // Максимальная высота волны
        
        // Параметры для волны
        let barCount = 7 // Количество вертикальных линий
        let heights: [CGFloat] = [0.5, 0.8, 1.0, 0.7, 0.9, 0.6, 0.4] // Относительные высоты линий
        
        // Начальная позиция X
        let startX = centerX - (CGFloat(barCount) * spacing / 2)
        
        // Рисуем каждую линию
        for i in 0..<barCount {
            let barHeight = maxHeight * heights[i]
            let xPos = startX + (CGFloat(i) * spacing)
            
            // Создаем линию
            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            
            // Верхняя точка линии
            let topPoint = NSPoint(x: xPos, y: centerY + barHeight / 2)
            // Нижняя точка линии
            let bottomPoint = NSPoint(x: xPos, y: centerY - barHeight / 2)
            
            // Рисуем линию
            path.move(to: topPoint)
            path.line(to: bottomPoint)
            path.stroke()
        }
    }
    
    // Сохранение изображения в файл
    private func save(image: NSImage, filename: String) {
        guard let tiffData = image.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            print("❌ Ошибка: Не удалось сконвертировать изображение в PNG")
            return
        }
        
        let fileURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent(filename)
        
        do {
            try pngData.write(to: fileURL)
            print("💾 Сохранено исходное изображение: \(filename)")
        } catch {
            print("❌ Ошибка при сохранении \(filename): \(error)")
        }
    }
    
    // Создание файла Contents.json для AppIcon.appiconset
    private func createContentsJson() {
        var images: [[String: Any]] = []
        
        // 16x16
        images.append(createImageEntry(size: 16, scale: 1))
        images.append(createImageEntry(size: 16, scale: 2))
        
        // 32x32
        images.append(createImageEntry(size: 32, scale: 1))
        images.append(createImageEntry(size: 32, scale: 2))
        
        // 128x128
        images.append(createImageEntry(size: 128, scale: 1))
        images.append(createImageEntry(size: 128, scale: 2))
        
        // 256x256
        images.append(createImageEntry(size: 256, scale: 1))
        images.append(createImageEntry(size: 256, scale: 2))
        
        // 512x512
        images.append(createImageEntry(size: 512, scale: 1))
        images.append(createImageEntry(size: 512, scale: 2))
        
        // Создаем JSON
        let contentsJson: [String: Any] = [
            "images": images,
            "info": [
                "author": "xcode",
                "version": 1
            ]
        ]
        
        // Преобразуем в данные
        guard let jsonData = try? JSONSerialization.data(withJSONObject: contentsJson, options: [.prettyPrinted]) else {
            print("❌ Ошибка при создании JSON-данных")
            return
        }
        
        // Сохраняем файл
        let fileURL = URL(fileURLWithPath: outputDirectory).appendingPathComponent("Contents.json")
        
        do {
            try jsonData.write(to: fileURL)
            print("📄 Создан файл Contents.json")
        } catch {
            print("❌ Ошибка при сохранении Contents.json: \(error)")
        }
    }
    
    // Создание записи для одной иконки в Contents.json
    private func createImageEntry(size: Int, scale: Int) -> [String: Any] {
        let filename = "app_icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        
        return [
            "filename": filename,
            "idiom": "mac",
            "scale": "\(scale)x",
            "size": "\(size)x\(size)"
        ]
    }
}

// Основная функция запуска генерации, принимающая путь из командной строки
func main() {
    guard CommandLine.arguments.count > 1 else {
        print("❌ Ошибка: Не указан путь для сохранения иконок")
        print("Использование: swift GenerateAppIcon.swift /путь/к/директории/AppIcon.appiconset")
        exit(1)
    }
    
    let assetCatalogPath = CommandLine.arguments[1]
    print("📂 Путь для сохранения иконок: \(assetCatalogPath)")
    
    // Создаем и запускаем генератор иконок
    let iconGenerator = IconGenerator(outputDirectory: assetCatalogPath)
    iconGenerator.generateIcons()
}

// Запускаем основную функцию
main() 