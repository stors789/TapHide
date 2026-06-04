#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCES_DIR="$PROJECT_DIR/Sources"
RESOURCES_DIR="$PROJECT_DIR/Resources"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="DockToggle"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$BUILD_DIR/$APP_NAME"

NATIVE_ARCH="$(uname -m)"
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || echo "")"

# Build universal binary if we can cross-compile to the other arch.
# On Apple Silicon we cross-compile for x86_64; on Intel we cross-compile for arm64.
# Falls back to native-only if cross-compilation isn't available.
if [ "$NATIVE_ARCH" = "arm64" ]; then
    TARGETS=("arm64-apple-macos14.0" "x86_64-apple-macos14.0")
elif [ "$NATIVE_ARCH" = "x86_64" ]; then
    TARGETS=("x86_64-apple-macos14.0" "arm64-apple-macos14.0")
else
    TARGETS=("$NATIVE_ARCH-apple-macos14.0")
fi

if [ -n "$SDK_PATH" ]; then
    SDK_FLAGS="-sdk $SDK_PATH"
else
    SDK_FLAGS=""
fi

COMMON_FLAGS="$SDK_FLAGS \
    -framework SwiftUI \
    -framework AppKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    -framework CoreGraphics"

echo "=== Cleaning previous build ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

SWIFT_FILES=$(find "$SOURCES_DIR" -name "*.swift" | sort)

echo "=== Compiling DockToggle ==="
echo "Native arch: $NATIVE_ARCH"
echo "SDK: $SDK_PATH"
echo "Targets: ${TARGETS[*]}"

declare -a ARCH_BINS=()

for TARGET in "${TARGETS[@]}"; do
    ARCH_NAME="${TARGET%%-*}"
    ARCH_BIN="$BUILD_DIR/$APP_NAME.$ARCH_NAME"
    ARCH_BINS+=("$ARCH_BIN")

    echo "  → Compiling for $ARCH_NAME ..."
    swiftc \
        -o "$ARCH_BIN" \
        -target "$TARGET" \
        $COMMON_FLAGS \
        $SWIFT_FILES 2>&1 || {
            echo "  ✗ Cross-compilation for $ARCH_NAME failed, falling back to native-only"
            rm -f "$ARCH_BIN"
            continue
        }
done

if [ ${#ARCH_BINS[@]} -ge 2 ] && [ -f "${ARCH_BINS[0]}" ] && [ -f "${ARCH_BINS[1]}" ]; then
    echo "  → Combining into universal binary ..."
    lipo -create "${ARCH_BINS[@]}" -output "$EXECUTABLE"
    lipo "$EXECUTABLE" -info
elif [ ${#ARCH_BINS[@]} -eq 1 ] && [ -f "${ARCH_BINS[0]}" ]; then
    echo "  → Using native binary ..."
    mv "${ARCH_BINS[0]}" "$EXECUTABLE"
else
    echo "ERROR: No binaries were compiled successfully"
    exit 1
fi

echo "=== Creating app bundle ==="
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$RESOURCES_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$RESOURCES_DIR/DockToggle.icns" "$APP_BUNDLE/Contents/Resources/DockToggle.icns"

echo -n 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "=== Code signing (ad-hoc) ==="
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 || true

echo ""
echo "=== Build complete ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To run: open '$APP_BUNDLE'"
echo ""
echo "Note: First launch will request Accessibility and Input Monitoring permissions."
echo "You may need to grant them in System Preferences > Privacy & Security."
