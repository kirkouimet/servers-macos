#!/bin/bash
#
# Servers App Icon Generator
#
# Generates app icon with dark gradient background and white server rack icon.
#
# Usage:
#     ./GenerateIcons.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MAGICK="/opt/homebrew/bin/magick"

# Source icon
ICON_SOURCE="$SCRIPT_DIR/SfServerRack-Light.png"

# Output directory
MACOS_ICONS="$PROJECT_DIR/Servers/Assets.xcassets/AppIcon.appiconset"

# Squircle dimensions
SQUIRCLE_SIZE=824
CORNER_RADIUS=185

echo "Creating dark gradient at ${SQUIRCLE_SIZE}x${SQUIRCLE_SIZE}..."
$MAGICK -size ${SQUIRCLE_SIZE}x${SQUIRCLE_SIZE} 'gradient:#3a3a3a-#2a2a2a' /tmp/gradient.png
$MAGICK /tmp/gradient.png -distort SRT 45 -gravity center -crop ${SQUIRCLE_SIZE}x${SQUIRCLE_SIZE}+0+0 +repage /tmp/rotated.png

# Composite SF Symbol onto gradient
echo "Compositing server icon..."
$MAGICK /tmp/rotated.png \( "$ICON_SOURCE" -resize 67% \) -gravity center -composite /tmp/with_icon.png

echo "Applying squircle mask (${CORNER_RADIUS}px radius)..."
$MAGICK -size ${SQUIRCLE_SIZE}x${SQUIRCLE_SIZE} xc:none -fill white \
    -draw "roundrectangle 0,0,$((SQUIRCLE_SIZE-1)),$((SQUIRCLE_SIZE-1)),${CORNER_RADIUS},${CORNER_RADIUS}" /tmp/mask.png
$MAGICK /tmp/with_icon.png /tmp/mask.png -alpha off -compose CopyOpacity -composite /tmp/masked.png

# macOS version: with shadow and padding
echo "Adding drop shadow and centering on 1024x1024 canvas..."
$MAGICK /tmp/masked.png \( +clone -background black -shadow 50x28+0+12 \) \
    +swap -background none -layers merge +repage -gravity center -extent 1024x1024 /tmp/icon_1024.png

# Generate macOS icons
if [ -d "$MACOS_ICONS" ]; then
    echo "Generating macOS icons..."
    cp /tmp/icon_1024.png "$MACOS_ICONS/icon_512x512@2x.png"
    $MAGICK /tmp/icon_1024.png -resize 512x512 "$MACOS_ICONS/icon_512x512.png"
    $MAGICK /tmp/icon_1024.png -resize 512x512 "$MACOS_ICONS/icon_256x256@2x.png"
    $MAGICK /tmp/icon_1024.png -resize 256x256 "$MACOS_ICONS/icon_256x256.png"
    $MAGICK /tmp/icon_1024.png -resize 256x256 "$MACOS_ICONS/icon_128x128@2x.png"
    $MAGICK /tmp/icon_1024.png -resize 128x128 "$MACOS_ICONS/icon_128x128.png"
    $MAGICK /tmp/icon_1024.png -resize 64x64 "$MACOS_ICONS/icon_32x32@2x.png"
    $MAGICK /tmp/icon_1024.png -resize 32x32 "$MACOS_ICONS/icon_32x32.png"
    $MAGICK /tmp/icon_1024.png -resize 32x32 "$MACOS_ICONS/icon_16x16@2x.png"
    $MAGICK /tmp/icon_1024.png -resize 16x16 "$MACOS_ICONS/icon_16x16.png"
    echo "  All sizes generated"
else
    echo "macOS icon directory not found: $MACOS_ICONS"
fi

# Save reference copy
cp /tmp/icon_1024.png ~/Desktop/servers_icon_1024.png
echo "Reference icon saved to ~/Desktop/servers_icon_1024.png"

# Cleanup
rm -f /tmp/gradient.png /tmp/rotated.png /tmp/with_icon.png /tmp/mask.png /tmp/masked.png /tmp/icon_1024.png

echo "Done!"
