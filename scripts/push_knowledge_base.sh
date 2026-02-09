#!/usr/bin/env bash
# =============================================================================
# push_knowledge_base.sh
#
# Pushes files from knowledge_base/ into the Android emulator so the app can
# discover them through its device connectors (photo gallery, document picker).
#
# Usage:
#   ./scripts/push_knowledge_base.sh              # use default emulator
#   ./scripts/push_knowledge_base.sh -s emulator-5554   # specific device
#
# What it does:
#   1. Pushes epistwin_images/*.{JPG,jpeg} → /sdcard/Pictures/EpisTwin/
#   2. Pushes epistwin_docs/*.pdf          → /sdcard/Documents/EpisTwin/
#   3. Triggers MediaScanner so files appear immediately in the gallery
#      and document pickers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KB_IMAGES="$PROJECT_ROOT/knowledge_base/epistwin_images"
KB_DOCS="$PROJECT_ROOT/knowledge_base/epistwin_docs"

# Destination paths on the emulator (shared storage)
DEST_IMAGES="/sdcard/Pictures/EpisTwin"
DEST_DOCS="/sdcard/Documents/EpisTwin"

# ---------- Parse optional -s <serial> argument ----------
ADB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)
            ADB_ARGS+=("-s" "$2")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [-s <device-serial>]"
            exit 1
            ;;
    esac
done

adb_cmd() {
    adb "${ADB_ARGS[@]}" "$@"
}

# ---------- Pre-flight checks ----------
if ! command -v adb &>/dev/null; then
    echo "ERROR: adb not found. Install Android SDK platform-tools."
    exit 1
fi

# Wait for device to be ready
echo "⏳ Waiting for device..."
adb_cmd wait-for-device

DEVICE=$(adb_cmd get-serialno)
echo "📱 Connected to: $DEVICE"

# ---------- Create destination directories ----------
echo ""
echo "📁 Creating directories on device..."
adb_cmd shell mkdir -p "$DEST_IMAGES"
adb_cmd shell mkdir -p "$DEST_DOCS"

# ---------- Push images ----------
shopt -s nullglob
echo ""
echo "🖼️  Pushing images to $DEST_IMAGES ..."
IMAGE_COUNT=0
for img in "$KB_IMAGES"/*.JPG "$KB_IMAGES"/*.jpeg "$KB_IMAGES"/*.jpg "$KB_IMAGES"/*.png; do
    [ -f "$img" ] || continue
    BASENAME="$(basename "$img")"
    echo "   -> $BASENAME"
    adb_cmd push "$img" "$DEST_IMAGES/$BASENAME" > /dev/null
    IMAGE_COUNT=$((IMAGE_COUNT + 1))
done
echo "   ✅ $IMAGE_COUNT image(s) pushed."

# ---------- Push documents ----------
echo ""
echo "📄 Pushing documents to $DEST_DOCS ..."
DOC_COUNT=0
for doc in "$KB_DOCS"/*.pdf "$KB_DOCS"/*.PDF "$KB_DOCS"/*.txt "$KB_DOCS"/*.docx; do
    [ -f "$doc" ] || continue
    BASENAME="$(basename "$doc")"
    echo "   -> $BASENAME"
    adb_cmd push "$doc" "$DEST_DOCS/$BASENAME" > /dev/null
    DOC_COUNT=$((DOC_COUNT + 1))
done
echo "   ✅ $DOC_COUNT document(s) pushed."

# ---------- Trigger media scan ----------
echo ""
echo "🔄 Triggering media scan..."

# Scan the image directory
adb_cmd shell am broadcast \
    -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file://$DEST_IMAGES" \
    > /dev/null 2>&1 || true

# Scan each image individually (more reliable on some API levels)
for img in "$KB_IMAGES"/*.JPG "$KB_IMAGES"/*.jpeg "$KB_IMAGES"/*.jpg "$KB_IMAGES"/*.png; do
    [ -f "$img" ] || continue
    BASENAME="$(basename "$img")"
    adb_cmd shell am broadcast \
        -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file://$DEST_IMAGES/$BASENAME" \
        > /dev/null 2>&1 || true
done

# Scan the documents directory
adb_cmd shell am broadcast \
    -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
    -d "file://$DEST_DOCS" \
    > /dev/null 2>&1 || true

for doc in "$KB_DOCS"/*.pdf "$KB_DOCS"/*.PDF "$KB_DOCS"/*.txt "$KB_DOCS"/*.docx; do
    [ -f "$doc" ] || continue
    BASENAME="$(basename "$doc")"
    adb_cmd shell am broadcast \
        -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file://$DEST_DOCS/$BASENAME" \
        > /dev/null 2>&1 || true
done

# Also run the full media scanner as a fallback (works on API 29+)
adb_cmd shell "content call --uri content://media/none/media_scanner --method scan_volume --arg external_primary" \
    > /dev/null 2>&1 || true

echo "   ✅ Media scan triggered."

# ---------- Summary ----------
echo ""
echo "============================================"
echo " Done! Pushed to emulator ($DEVICE):"
echo "   🖼️  $IMAGE_COUNT images  → $DEST_IMAGES"
echo "   📄 $DOC_COUNT documents → $DEST_DOCS"
echo ""
echo " The files should now be visible in:"
echo "   - Gallery / Photos app (images)"
echo "   - Files / Document picker (documents)"
echo "============================================"
