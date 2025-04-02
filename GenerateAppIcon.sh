#!/bin/bash

# Скрипт для генерации иконок приложения WhisperServer
# Запускает Swift-скрипт для генерации мастер-иконки и затем создает различные размеры иконок

echo "🎨 Запуск генерации иконок приложения WhisperServer..."

# Определяем текущую директорию скрипта
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}"

# Правильный путь к Assets.xcassets: PROJECT_ROOT/WhisperServer/Assets.xcassets
ASSET_DIR="${PROJECT_ROOT}/WhisperServer/Assets.xcassets"
if [ ! -d "${ASSET_DIR}" ]; then
    # Если не существует, создаем ее
    mkdir -p "${ASSET_DIR}/AppIcon.appiconset"
    echo "📁 Создана директория для ассетов: ${ASSET_DIR}"
fi

# Показываем пути для отладки
echo "📂 Директория проекта: ${PROJECT_ROOT}"
echo "📂 Директория ассетов: ${ASSET_DIR}"

# Проверяем наличие Swift
if ! command -v swift &> /dev/null; then
    echo "❌ Ошибка: Swift не установлен"
    echo "Пожалуйста, установите Swift или используйте Xcode для запуска скрипта."
    exit 1
fi

# Проверяем наличие Swift-файла
SWIFT_SCRIPT="${SCRIPT_DIR}/GenerateAppIcon.swift"
if [ ! -f "${SWIFT_SCRIPT}" ]; then
    echo "❌ Ошибка: Файл GenerateAppIcon.swift не найден"
    echo "Пожалуйста, убедитесь, что файл GenerateAppIcon.swift находится в том же каталоге"
    exit 1
fi

# Запускаем Swift-скрипт с явно указанным абсолютным путем
ICON_DIR="${ASSET_DIR}/AppIcon.appiconset"
swift "${SWIFT_SCRIPT}" "${ICON_DIR}"

# Проверяем код выхода
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    # Используем sips для создания иконок нужных размеров из мастер-изображения
    MASTER_ICON="${ICON_DIR}/app_icon_master.png"
    
    echo "🔄 Создание иконок с точными размерами с помощью sips..."
    
    # 16x16
    sips -z 16 16 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_16x16.png"
    sips -z 32 32 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_16x16@2x.png"
    
    # 32x32
    sips -z 32 32 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_32x32.png"
    sips -z 64 64 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_32x32@2x.png"
    
    # 128x128
    sips -z 128 128 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_128x128.png"
    sips -z 256 256 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_128x128@2x.png"
    
    # 256x256
    sips -z 256 256 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_256x256.png"
    sips -z 512 512 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_256x256@2x.png"
    
    # 512x512
    sips -z 512 512 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_512x512.png"
    sips -z 1024 1024 "${MASTER_ICON}" --out "${ICON_DIR}/app_icon_512x512@2x.png"
    
    # Удаляем мастер-изображение
    rm "${MASTER_ICON}"
    
    echo "✅ Генерация иконок успешно завершена!"
    echo "📦 Иконки сгенерированы в ${ASSET_DIR}/AppIcon.appiconset"
else
    echo "❌ Ошибка: Не удалось сгенерировать иконки (код ошибки: $EXIT_CODE)"
    exit 1
fi 