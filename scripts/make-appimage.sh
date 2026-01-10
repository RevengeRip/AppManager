#!/bin/bash
#
# Build AppImage for AppManager using appimagetool
#
# Usage: ./scripts/make-appimage.sh [build_dir]
#
# Requirements:
#   - Compiled build in the build directory
#   - appimagetool (will be downloaded if not found)
#   - desktop-file-utils (for validation)
#   - chrpath (optional, for removing rpath)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${1:-$PROJECT_DIR/build}"

# App info
APP_NAME="AppManager"
APP_ID="com.github.AppManager"
BINARY_NAME="app-manager"

# Get version from meson introspect or fallback to meson.build
if command -v jq &>/dev/null && [ -f "$BUILD_DIR/meson-info/intro-projectinfo.json" ]; then
    VERSION=$(jq -r '.version' "$BUILD_DIR/meson-info/intro-projectinfo.json")
else
    VERSION=$(grep -oP "version:\s*'\K[^']+" "$PROJECT_DIR/meson.build" | head -1)
fi
ARCH=$(uname -m)

# Output
PACKAGE_DIR="$PROJECT_DIR"
APPIMAGE_NAME="$BINARY_NAME-${VERSION}-${ARCH}.AppImage"

echo "=== Building AppImage for $APP_NAME v$VERSION ==="
echo "Build directory: $BUILD_DIR"
echo "Output: $PACKAGE_DIR/$APPIMAGE_NAME"

# Verify build exists
if [ ! -f "$BUILD_DIR/src/$BINARY_NAME" ]; then
    echo "Error: Binary not found at $BUILD_DIR/src/$BINARY_NAME"
    echo "Please run 'meson compile -C build' first."
    exit 1
fi

# Check/download appimagetool
APPIMAGETOOL=""
if command -v appimagetool &>/dev/null; then
    APPIMAGETOOL="appimagetool"
elif [ -f "$PROJECT_DIR/appimagetool" ]; then
    APPIMAGETOOL="$PROJECT_DIR/appimagetool"
else
    echo "Downloading appimagetool..."
    curl -Lo "$PROJECT_DIR/appimagetool" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$PROJECT_DIR/appimagetool"
    APPIMAGETOOL="$PROJECT_DIR/appimagetool"
fi

# Create temporary install tree using meson install
DESTDIR=$(mktemp -d)
APPDIR=$(mktemp -d)
trap "rm -rf '$DESTDIR' '$APPDIR'" EXIT

# Get the prefix from the build configuration
PREFIX=$(meson introspect "$BUILD_DIR" --buildoptions | jq -r '.[] | select(.name == "prefix") | .value')
echo "Build prefix: $PREFIX"

echo "Installing to staging directory..."
meson install -C "$BUILD_DIR" --destdir "$DESTDIR" --quiet 2>/dev/null || \
    meson install -C "$BUILD_DIR" --destdir "$DESTDIR"

# Installed files are at DESTDIR + PREFIX, we need them under APPDIR/usr
INSTALL_ROOT="$DESTDIR$PREFIX"

if [ ! -d "$INSTALL_ROOT" ]; then
    echo "Error: Install root not found at $INSTALL_ROOT"
    echo "Contents of DESTDIR:"
    find "$DESTDIR" -type d | head -20
    exit 1
fi

echo "Creating AppDir structure..."

# Copy installed files to AppDir/usr
mkdir -p "$APPDIR/usr"
cp -a "$INSTALL_ROOT"/* "$APPDIR/usr/"

# Move dwarfs tools to bin for easier discovery in AppImage (if present)
find "$APPDIR/usr/lib" -name dwarfsextract -exec mv {} "$APPDIR/usr/bin/" \; 2>/dev/null || true
find "$APPDIR/usr/lib" -name dwarfsck -exec mv {} "$APPDIR/usr/bin/" \; 2>/dev/null || true

# Create AppRun script that sets up environment for GSettings schemas
cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "$0")")"
export APPDIR="$HERE"
export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas:${GSETTINGS_SCHEMA_DIR:-}"
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export PATH="$HERE/usr/bin:$PATH"
exec "$HERE/usr/bin/app-manager" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# Desktop and icon at AppDir root
install -Dm644 "$APPDIR/usr/share/applications/$APP_ID.desktop" "$APPDIR/$APP_ID.desktop"
install -Dm644 "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg" "$APPDIR/$APP_ID.svg"

# Add X-AppImage-Version to desktop file (used by AppManager to detect version during install)
if ! grep -q "^X-AppImage-Version=" "$APPDIR/$APP_ID.desktop"; then
    # Ensure file ends with newline before appending
    sed -i -e '$a\' "$APPDIR/$APP_ID.desktop"
    echo "X-AppImage-Version=$VERSION" >> "$APPDIR/$APP_ID.desktop"
fi

# Validate desktop file
if command -v desktop-file-validate &>/dev/null; then
    desktop-file-validate "$APPDIR/$APP_ID.desktop" || true
fi

# Remove rpath if present
if command -v chrpath &>/dev/null; then
    chrpath -d "$APPDIR/usr/bin/$BINARY_NAME" 2>/dev/null || true
fi

echo "AppDir contents:"
find "$APPDIR" -type f | head -20

# Build AppImage
echo "Creating AppImage..."
ARCH=$ARCH "$APPIMAGETOOL" "$APPDIR" "$PACKAGE_DIR/$APPIMAGE_NAME"

# Get file size
SIZE=$(du -h "$PACKAGE_DIR/$APPIMAGE_NAME" | cut -f1)

echo ""
echo "=== AppImage created successfully ==="
echo "Output: $PACKAGE_DIR/$APPIMAGE_NAME"
echo "Size: $SIZE"
echo ""
echo "To run: ./$APPIMAGE_NAME"
