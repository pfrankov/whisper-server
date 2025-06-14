#!/bin/bash

# Script for generating WhisperServer app icons from user's icon.png
# Takes the icon.png file and creates all necessary sizes with proper macOS spacing

echo "🎨 Generating WhisperServer app icons from your custom icon.png..."

# Define script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="${SCRIPT_DIR}"

# Path to Assets.xcassets: PROJECT_ROOT/WhisperServer/Assets.xcassets
ASSET_DIR="${PROJECT_ROOT}/WhisperServer/Assets.xcassets"
APPICON_DIR="${ASSET_DIR}/AppIcon.appiconset"

# Check if the source icon exists
SOURCE_ICON="${PROJECT_ROOT}/icon.png"
if [ ! -f "${SOURCE_ICON}" ]; then
    echo "❌ Error: icon.png not found in project root"
    echo "Please make sure icon.png is in the project root directory"
    exit 1
fi

# Create directories if they don't exist
if [ ! -d "${ASSET_DIR}" ]; then
    mkdir -p "${APPICON_DIR}"
    echo "📁 Created assets directory: ${ASSET_DIR}"
fi

# Show paths for debugging
echo "📂 Project directory: ${PROJECT_ROOT}"
echo "📂 Assets directory: ${ASSET_DIR}"
echo "📂 Source icon: ${SOURCE_ICON}"

# Check if sips is available (it should be on macOS)
if ! command -v sips &> /dev/null; then
    echo "❌ Error: sips command not found"
    echo "This script requires macOS sips utility for image processing"
    exit 1
fi

echo "🔄 Creating icons with proper macOS spacing using sips..."

# For macOS icons, we scale to about 90% to leave room for visual effects and shadows
# This creates a more authentic macOS look

# 16x16 (scale to ~14x14 centered in 16x16)
sips -z 14 14 "${SOURCE_ICON}" --out "/tmp/temp_14.png" > /dev/null 2>&1
sips -p 16 16 -c 16 16 "/tmp/temp_14.png" --out "${APPICON_DIR}/app_icon_16x16.png" > /dev/null 2>&1

# 16x16@2x = 32x32 (scale to ~28x28 centered in 32x32)
sips -z 28 28 "${SOURCE_ICON}" --out "/tmp/temp_28.png" > /dev/null 2>&1
sips -p 32 32 -c 32 32 "/tmp/temp_28.png" --out "${APPICON_DIR}/app_icon_16x16@2x.png" > /dev/null 2>&1

# 32x32 (scale to ~29x29 centered in 32x32)
sips -z 29 29 "${SOURCE_ICON}" --out "/tmp/temp_29.png" > /dev/null 2>&1
sips -p 32 32 -c 32 32 "/tmp/temp_29.png" --out "${APPICON_DIR}/app_icon_32x32.png" > /dev/null 2>&1

# 32x32@2x = 64x64 (scale to ~58x58 centered in 64x64)
sips -z 58 58 "${SOURCE_ICON}" --out "/tmp/temp_58.png" > /dev/null 2>&1
sips -p 64 64 -c 64 64 "/tmp/temp_58.png" --out "${APPICON_DIR}/app_icon_32x32@2x.png" > /dev/null 2>&1

# 128x128 (scale to ~115x115 centered in 128x128)
sips -z 115 115 "${SOURCE_ICON}" --out "/tmp/temp_115.png" > /dev/null 2>&1
sips -p 128 128 -c 128 128 "/tmp/temp_115.png" --out "${APPICON_DIR}/app_icon_128x128.png" > /dev/null 2>&1

# 128x128@2x = 256x256 (scale to ~230x230 centered in 256x256)
sips -z 230 230 "${SOURCE_ICON}" --out "/tmp/temp_230.png" > /dev/null 2>&1
sips -p 256 256 -c 256 256 "/tmp/temp_230.png" --out "${APPICON_DIR}/app_icon_128x128@2x.png" > /dev/null 2>&1

# 256x256 (scale to ~230x230 centered in 256x256)
sips -z 230 230 "${SOURCE_ICON}" --out "/tmp/temp_230_alt.png" > /dev/null 2>&1
sips -p 256 256 -c 256 256 "/tmp/temp_230_alt.png" --out "${APPICON_DIR}/app_icon_256x256.png" > /dev/null 2>&1

# 256x256@2x = 512x512 (scale to ~460x460 centered in 512x512)
sips -z 460 460 "${SOURCE_ICON}" --out "/tmp/temp_460.png" > /dev/null 2>&1
sips -p 512 512 -c 512 512 "/tmp/temp_460.png" --out "${APPICON_DIR}/app_icon_256x256@2x.png" > /dev/null 2>&1

# 512x512 (scale to ~460x460 centered in 512x512)
sips -z 460 460 "${SOURCE_ICON}" --out "/tmp/temp_460_alt.png" > /dev/null 2>&1
sips -p 512 512 -c 512 512 "/tmp/temp_460_alt.png" --out "${APPICON_DIR}/app_icon_512x512.png" > /dev/null 2>&1

# 512x512@2x = 1024x1024 (scale to ~920x920 centered in 1024x1024)
sips -z 920 920 "${SOURCE_ICON}" --out "/tmp/temp_920.png" > /dev/null 2>&1
sips -p 1024 1024 -c 1024 1024 "/tmp/temp_920.png" --out "${APPICON_DIR}/app_icon_512x512@2x.png" > /dev/null 2>&1

# Clean up temporary files
rm -f /tmp/temp_*.png

echo "✅ Icon generation completed successfully!"
echo "📦 Icons generated in ${APPICON_DIR}"
echo "💡 Icons are scaled to ~90% with proper macOS spacing for visual effects" 