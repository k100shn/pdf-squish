#!/bin/bash
# ──────────────────────────────────────────────
# PDFSquish — Build Script
# ──────────────────────────────────────────────
# Usage:
#   ./build.sh              Build for current arch, ad-hoc signed (dev)
#   ./build.sh release      Universal binary, Developer ID signed, notarized, ZIP
#   ./build.sh xcodegen     Generate Xcode project
#
# Environment variables (release mode):
#   SIGN_IDENTITY    Developer ID Application certificate name
#                    (default: "Developer ID Application")
#   NOTARY_PROFILE   notarytool keychain profile name
#                    (set up with: xcrun notarytool store-credentials PROFILE_NAME)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="PDFSquish"
BUNDLE="${APP_NAME}.app"
BUILD_DIR="$SCRIPT_DIR/build"
STAGING_DIR="$BUILD_DIR/staging"
SRC_DIR="$SCRIPT_DIR/PDFSquish"
ENTITLEMENTS="$SRC_DIR/PDFSquish.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

SWIFT_FILES=(
    "$SRC_DIR/PDFSquishApp.swift"
    "$SRC_DIR/ContentView.swift"
    "$SRC_DIR/PDFCompressor.swift"
)

FRAMEWORKS=(
    -framework SwiftUI
    -framework AppKit
    -framework Quartz
    -framework UniformTypeIdentifiers
)

SDK=$(xcrun --show-sdk-path --sdk macosx)

# ── XcodeGen mode ──────────────────────────────

if [ "${1:-}" = "xcodegen" ]; then
    echo "Generating Xcode project with XcodeGen..."
    if ! command -v xcodegen &> /dev/null; then
        echo "ERROR: XcodeGen not found. Install it with: brew install xcodegen"
        exit 1
    fi
    xcodegen generate
    echo "PDFSquish.xcodeproj created. Open it in Xcode and press Cmd+R."
    open PDFSquish.xcodeproj
    exit 0
fi

# ── Shared setup ───────────────────────────────

MODE="${1:-dev}"

if command -v qpdf &> /dev/null; then
    echo "qpdf found — lossless compression will be available"
else
    echo "WARNING: qpdf not found — install with: brew install qpdf"
    echo "  (The app will still work but with limited compression)"
fi

echo ""
echo "Building $APP_NAME ($MODE)..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$STAGING_DIR/$BUNDLE/Contents/MacOS"
mkdir -p "$STAGING_DIR/$BUNDLE/Contents/Resources"

# ── Compile ────────────────────────────────────

compile_arch() {
    local arch="$1"
    local target="${arch}-apple-macosx13.0"
    local output="$BUILD_DIR/${APP_NAME}_${arch}"

    echo "  Compiling $arch..."
    swiftc \
        -target "$target" \
        -sdk "$SDK" \
        "${FRAMEWORKS[@]}" \
        -o "$output" \
        "${SWIFT_FILES[@]}"
}

if [ "$MODE" = "release" ]; then
    # Universal binary: both architectures, merged with lipo
    compile_arch arm64
    compile_arch x86_64

    echo "  Creating universal binary..."
    lipo -create \
        "$BUILD_DIR/${APP_NAME}_arm64" \
        "$BUILD_DIR/${APP_NAME}_x86_64" \
        -output "$STAGING_DIR/$BUNDLE/Contents/MacOS/$APP_NAME"

    rm "$BUILD_DIR/${APP_NAME}_arm64" "$BUILD_DIR/${APP_NAME}_x86_64"
else
    # Dev: current architecture only
    ARCH=$(uname -m)
    compile_arch "$ARCH"
    mv "$BUILD_DIR/${APP_NAME}_${ARCH}" "$STAGING_DIR/$BUNDLE/Contents/MacOS/$APP_NAME"
fi

# ── Bundle resources ───────────────────────────

echo "  Copying bundle resources..."
cp "$SRC_DIR/Info.plist" "$STAGING_DIR/$BUNDLE/Contents/"

if [ -f "$SRC_DIR/PrivacyInfo.xcprivacy" ]; then
    cp "$SRC_DIR/PrivacyInfo.xcprivacy" "$STAGING_DIR/$BUNDLE/Contents/Resources/"
fi

if [ -f "$SRC_DIR/AppIcon.icns" ]; then
    cp "$SRC_DIR/AppIcon.icns" "$STAGING_DIR/$BUNDLE/Contents/Resources/"
else
    echo "  WARNING: No AppIcon.icns found — app will use default icon"
fi

# ── Code signing ───────────────────────────────
# Rules: macOS Developer ID — Code Signing & Notarization
#   - Never use --deep for signing (only for verification)
#   - Always pass --entitlements explicitly
#   - Always use --options runtime (Hardened Runtime)
#   - Use ditto --norsrc to strip xattrs before signing

echo ""
echo "Signing..."

# Stage to clean temp directory (strips xattrs including com.apple.provenance)
SIGN_DIR=$(mktemp -d)
trap 'rm -rf "$SIGN_DIR"' EXIT

ditto --norsrc "$STAGING_DIR/$BUNDLE" "$SIGN_DIR/$BUNDLE"
xattr -cr "$SIGN_DIR/$BUNDLE" 2>/dev/null || true

if [ "$MODE" = "release" ]; then
    echo "  Identity: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$SIGN_DIR/$BUNDLE"
else
    echo "  Identity: ad-hoc (dev build)"
    codesign --force --sign - \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        "$SIGN_DIR/$BUNDLE"
fi

# ── Verify signature ──────────────────────────

echo "  Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$SIGN_DIR/$BUNDLE"

# Verify entitlements were embedded
ENT_OUTPUT=$(codesign -d --entitlements - "$SIGN_DIR/$BUNDLE" 2>&1 || true)
if echo "$ENT_OUTPUT" | grep -q "com.apple.security"; then
    echo "  Entitlements: embedded"
else
    echo "  WARNING: Entitlements may not be embedded. Verify with:"
    echo "    codesign -d --entitlements - \"$BUILD_DIR/$BUNDLE\""
fi

# ── Copy signed bundle back ───────────────────

ditto --norsrc "$SIGN_DIR/$BUNDLE" "$BUILD_DIR/$BUNDLE"

# ── Notarize + ZIP (release only) ─────────────

if [ "$MODE" = "release" ]; then
    echo ""
    echo "Creating ZIP for distribution..."

    # Create ZIP from the clean signed bundle (--norsrc strips AppleDouble detritus)
    ZIP_PATH="$BUILD_DIR/${APP_NAME}.zip"
    ditto -c -k --norsrc --keepParent "$SIGN_DIR/$BUNDLE" "$ZIP_PATH"

    # Verify ZIP has no AppleDouble ._* files.
    # grep exits 1 when there are zero matches (the clean case); `|| true` keeps
    # `set -e`/`pipefail` from aborting the build on a clean ZIP.
    DETRITUS=$(zipinfo "$ZIP_PATH" 2>/dev/null | grep -c '\._' || true)
    if [ "$DETRITUS" != "0" ]; then
        echo "ERROR: ZIP contains $DETRITUS AppleDouble (._*) files — notarization will fail!"
        exit 1
    fi
    echo "  ZIP clean (0 AppleDouble files)"

    # Verify signature survives unzip extraction (not just ditto)
    VERIFY_DIR=$(mktemp -d)
    (cd "$VERIFY_DIR" && unzip -qo "$ZIP_PATH")
    if codesign --verify --deep --strict "$VERIFY_DIR/$BUNDLE" 2>/dev/null; then
        echo "  Signature valid after unzip extraction"
    else
        echo "ERROR: Signature invalid after unzip extraction!"
        rm -rf "$VERIFY_DIR"
        exit 1
    fi
    rm -rf "$VERIFY_DIR"

    if [ -n "$NOTARY_PROFILE" ]; then
        echo ""
        echo "Submitting to Apple for notarization..."
        xcrun notarytool submit "$ZIP_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait

        echo "Stapling notarization ticket..."
        xcrun stapler staple "$BUILD_DIR/$BUNDLE"

        # Re-create ZIP with stapled bundle
        rm "$ZIP_PATH"
        ditto -c -k --norsrc --keepParent "$BUILD_DIR/$BUNDLE" "$ZIP_PATH"
        echo "  Stapled ZIP: $ZIP_PATH"
    else
        echo ""
        echo "To notarize, set NOTARY_PROFILE:"
        echo "  NOTARY_PROFILE=your-profile ./build.sh release"
        echo ""
        echo "Set up credentials first:"
        echo "  xcrun notarytool store-credentials your-profile \\"
        echo "      --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
    fi
fi

# ── Done ───────────────────────────────────────

# Clean up staging
rm -rf "$STAGING_DIR"

echo ""
echo "Built successfully!"
echo "  App: $BUILD_DIR/$BUNDLE"
if [ "$MODE" = "release" ] && [ -f "$BUILD_DIR/${APP_NAME}.zip" ]; then
    echo "  ZIP: $BUILD_DIR/${APP_NAME}.zip"
fi
echo ""
echo "To run:"
echo "  open \"$BUILD_DIR/$BUNDLE\""
