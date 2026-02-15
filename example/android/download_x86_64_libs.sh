#!/usr/bin/env bash
# Downloads x86_64 native libraries for running on x86_64 emulators (e.g., redroid).
# These libraries are only shipped for arm64-v8a in the upstream AARs.
#
# Usage: ./download_x86_64_libs.sh
#
# Source: https://storage.googleapis.com/mediapipe-assets/rag_pipeline/x86_64/

set -euo pipefail

BASE_URL="https://storage.googleapis.com/mediapipe-assets/rag_pipeline/x86_64"
OUT_DIR="$(dirname "$0")/app/src/main/jniLibs/x86_64"

LIBS=(
  "libgemma_embedding_model_jni.so"
  "libgecko_embedding_model_jni.so"
  "libsqlite_vector_store_jni.so"
  "libtext_chunker_jni.so"
)

mkdir -p "$OUT_DIR"

echo "Downloading x86_64 native libraries to $OUT_DIR ..."

for lib in "${LIBS[@]}"; do
  if [[ -f "$OUT_DIR/$lib" ]]; then
    echo "  ✓ $lib (already exists, skipping)"
  else
    echo "  ↓ $lib ..."
    curl -fSL -o "$OUT_DIR/$lib" "$BASE_URL/$lib"
    echo "    done ($(du -h "$OUT_DIR/$lib" | cut -f1))"
  fi
done

echo ""
echo "All x86_64 libraries ready."
echo "Rebuild APK with: flutter build apk --target-platform android-arm64,android-x64 --debug"
