#!/bin/sh

# Копирование ресурсов в бандл приложения

# Путь к папке ресурсов в проекте
SOURCE_RESOURCES="${SRCROOT}/WhisperServer/Resources"

# Путь к папке ресурсов в бандле приложения
TARGET_RESOURCES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"

# Создаем папку ресурсов, если она еще не существует
mkdir -p "${TARGET_RESOURCES}"

# Копируем модель и аудиофайл
echo "Копирование ресурсов из ${SOURCE_RESOURCES} в ${TARGET_RESOURCES}"

# Создаем директорию models, если ее нет
mkdir -p "${TARGET_RESOURCES}/models"

# Копируем модельный файл
if [ -f "${SOURCE_RESOURCES}/models/ggml-base.en.bin" ]; then
    echo "Копирование ggml-base.en.bin..."
    cp -R "${SOURCE_RESOURCES}/models/ggml-base.en.bin" "${TARGET_RESOURCES}/models/"
else
    echo "Ошибка: Файл модели ggml-base.en.bin не найден в ${SOURCE_RESOURCES}/models/"
fi

# Копируем папку модели Core ML
if [ -d "${SOURCE_RESOURCES}/models/ggml-base.en-encoder.mlmodelc" ]; then
    echo "Копирование ggml-base.en-encoder.mlmodelc..."
    cp -R "${SOURCE_RESOURCES}/models/ggml-base.en-encoder.mlmodelc" "${TARGET_RESOURCES}/models/"
else
    echo "Ошибка: Директория ggml-base.en-encoder.mlmodelc не найдена в ${SOURCE_RESOURCES}/models/"
fi

# Копируем аудиофайл
if [ -f "${SOURCE_RESOURCES}/jfk.wav" ]; then
    echo "Копирование jfk.wav..."
    cp -R "${SOURCE_RESOURCES}/jfk.wav" "${TARGET_RESOURCES}/"
else
    echo "Ошибка: Файл jfk.wav не найден в ${SOURCE_RESOURCES}/"
fi

echo "Копирование ресурсов завершено." 