#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="NTE Piano MIDI Player"
PROJECT_PATH="$ROOT_DIR/NTEPianoMidiPlayer.xcodeproj"
SCHEME="NTEPianoMidiPlayer"
VERSION="${VERSION:-1.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-4}"

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DERIVED_DATA_DIR="$ROOT_DIR/DerivedData/Release"
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
VIRTUAL_HID_VENDOR_DIR="$ROOT_DIR/Vendor/Karabiner-DriverKit-VirtualHIDDevice"
VIRTUAL_HID_VERSION_FILE="$VIRTUAL_HID_VENDOR_DIR/version.json"
VIRTUAL_HID_HELPER="$APP_DIR/Contents/Helpers/NTEVirtualHIDBridge"
ZIP_PATH="$DIST_DIR/NTE-Piano-MIDI-Player-macOS-unsigned.zip"

if [[ ! -f "$VIRTUAL_HID_VERSION_FILE" ]]; then
    echo "Karabiner VirtualHID submodule is missing. Run: git submodule update --init --recursive" >&2
    exit 1
fi

if ! /usr/bin/grep -q '"package_version": "8.2.0"' "$VIRTUAL_HID_VERSION_FILE"; then
    echo "Karabiner VirtualHID must be pinned to package version 8.2.0." >&2
    exit 1
fi

echo "Building the native Xcode Release app..."
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    build

rm -rf "$APP_DIR" "$ZIP_PATH"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$APP_DIR"

if [[ ! -d "$APP_DIR/Contents/Frameworks/NTEPianoMidiPlayerCore.framework" ]]; then
    echo "Packaging failed: embedded core framework is missing." >&2
    exit 1
fi

if [[ ! -f "$RESOURCES_DIR/AppIcon.icns" ]]; then
    echo "Packaging failed: compiled app icon is missing." >&2
    exit 1
fi

if [[ ! -x "$VIRTUAL_HID_HELPER" ]]; then
    echo "Packaging failed: NTEVirtualHIDBridge is missing from Contents/Helpers." >&2
    exit 1
fi

"$VIRTUAL_HID_HELPER" --self-test
"$VIRTUAL_HID_HELPER" --version
/usr/bin/lipo "$VIRTUAL_HID_HELPER" -verify_arch arm64 x86_64

echo "Creating unsigned ZIP release artifact..."
(
    cd "$DIST_DIR"
    /usr/bin/zip -qry "$ZIP_PATH" "$APP_NAME.app"
)

echo "Built:"
echo "  $APP_DIR"
echo "  $ZIP_PATH"
echo
echo "Note: this app bundle is unsigned and not notarized."
