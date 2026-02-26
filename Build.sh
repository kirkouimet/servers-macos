#!/bin/bash

# Build and deploy Servers to Applications folder

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Servers"
BUILD_DIR="/tmp/ServersBuild"

# Known ports from ~/.servers/settings.json
PORTS=(7378 2878 2666 3000 3001)

echo "🔨 Building Servers..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Build release version (quiet mode, only show errors/warnings)
BUILD_OUTPUT=$(xcodebuild -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -quiet \
    build 2>&1) || { echo "$BUILD_OUTPUT"; exit 1; }

# Show filtered output (errors/warnings only, minus noise)
echo "$BUILD_OUTPUT" | grep -v -E "^dyld\[|IDERunDestination|Using the first of multiple|platform:macOS" || true

# Find the built app
BUILT_APP=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d | head -1)

if [ -z "$BUILT_APP" ]; then
    echo "❌ Build failed - app not found"
    exit 1
fi

echo "📦 Built: $BUILT_APP"

# Kill running instance
echo "🔪 Stopping running instance..."

# First, try graceful termination
pkill -TERM -x "Servers" 2>/dev/null || true
sleep 2

# Force kill if still running
pkill -9 -x "Servers" 2>/dev/null || true
sleep 1

# Kill any orphaned processes on our ports
echo "🧹 Clearing ports..."
for port in "${PORTS[@]}"; do
    lsof -ti :$port | xargs kill -9 2>/dev/null || true
done
sleep 1

# Remove old app and install new one
echo "📲 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUILT_APP" "/Applications/"

echo "🚀 Launching Servers..."
open "/Applications/$APP_NAME.app"

echo "✅ Done! Servers is running."
echo ""
echo "API available at: http://localhost:7378/servers"
echo "Settings file: ~/.servers/settings.json"
