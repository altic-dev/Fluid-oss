#!/bin/bash

set -e  # Exit on any error

echo "🚀 Starting FluidVoice release process..."

# Get version from Info.plist
VERSION=$(plutil -p Info.plist | grep CFBundleShortVersionString | cut -d '"' -f 4)
echo "📋 Release version: $VERSION"

# Validate version format
if [[ ! $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "❌ Error: Invalid version format '$VERSION'. Expected format: X.Y or X.Y.Z"
    exit 1
fi

# Check if release already exists
if gh release view "v$VERSION" --repo altic-dev/Fluid-oss >/dev/null 2>&1; then
    echo "⚠️  Warning: Release v$VERSION already exists!"
    echo "Do you want to delete and recreate it? (y/N)"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo "🗑️  Deleting existing release..."
        gh release delete "v$VERSION" --repo altic-dev/Fluid-oss --yes
    else
        echo "❌ Aborting release process"
        exit 1
    fi
fi

# Use pre-built app from Documents
APP_PATH="/Users/barathwajanandan/Documents/FluidVoice.app"
echo "📱 Using pre-built app: $APP_PATH"
if [ ! -d "$APP_PATH" ]; then
    echo "❌ Error: Built app not found at $APP_PATH"
    exit 1
fi

# Create zip with exact naming convention
ZIP_NAME="Fluid-oss-${VERSION}.zip"
echo "📦 Creating release zip: $ZIP_NAME"
cd "$(dirname "$APP_PATH")"
zip -r "$OLDPWD/$ZIP_NAME" FluidVoice.app
cd "$OLDPWD"

# Verify zip was created
if [ ! -f "$ZIP_NAME" ]; then
    echo "❌ Error: Failed to create zip file"
    exit 1
fi

echo "✅ Zip created successfully: $ZIP_NAME"

# Create DMG (traditional macOS installer)
DMG_NAME="Fluid-oss-${VERSION}.dmg"
echo "💿 Creating DMG: $DMG_NAME"

create-dmg \
  --volname "FluidVoice Installer" \
  --window-size 600 400 \
  --icon-size 100 \
  --icon "FluidVoice.app" 150 150 \
  --hide-extension "FluidVoice.app" \
  --app-drop-link 400 150 \
  "$DMG_NAME" \
  "$APP_PATH"

echo "✅ DMG created successfully: $DMG_NAME"

# Create GitHub release
echo "Creating GitHub release..."
gh release create "v$VERSION" "$ZIP_NAME" "$DMG_NAME" \
  --repo altic-dev/Fluid-oss \
  --title "FluidVoice v$VERSION" \
  --notes "## What's New in v$VERSION

New meeting transcription features and enhanced audio processing

### Changes
- **Meeting File Transcription**: Upload and transcribe audio/video files
- **Enhanced Overlay**: Improved animations and controls for better user experience
- **Live Preview Mode**: Real-time transcription preview in overlay
- **Better Audio Handling**: Improved ASR service with enhanced streaming
- **macOS 14 Support**: Updated to latest macOS version with FluidAudio 0.7.4

"

echo "Release v$VERSION created successfully!"
echo "Release URL: https://github.com/altic-dev/Fluid-oss/releases/tag/v$VERSION"
echo "Assets: $ZIP_NAME and $DMG_NAME"

# Clean up
echo "Cleaning up..."
rm "$ZIP_NAME" "$DMG_NAME"

echo "Release process completed successfully!"
echo "🎉 Release process completed successfully!"
