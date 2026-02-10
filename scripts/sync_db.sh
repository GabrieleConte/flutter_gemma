#!/usr/bin/env bash
# =============================================================================
# sync_db.sh — Pull or push the graph_rag.db SQLite database from/to the
#              Android emulator for local inspection and editing.
#
# Usage:
#   ./scripts/sync_db.sh pull                     # pull DB to local machine
#   ./scripts/sync_db.sh push                     # push local DB back
#   ./scripts/sync_db.sh pull -s emulator-5554    # specify device
#   ./scripts/sync_db.sh push -s emulator-5554
#
# The local copy is saved to:  ./knowledge_base/graph_rag.db
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_ID="dev.flutterberlin.flutter_gemma_example"
# Relative to the app's home dir (used with run-as)
REMOTE_DB_REL="databases/flutter_gemma_graph.db"
LOCAL_DB="$PROJECT_ROOT/knowledge_base/graph_rag.db"
TMP_DB="/sdcard/flutter_gemma_graph_tmp.db"

# ---------- Parse arguments ----------
if [ $# -lt 1 ]; then
    echo "Usage: $0 <pull|push> [-s <device-serial>]"
    exit 1
fi

ACTION="$1"; shift

ADB_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)
            ADB_ARGS+=("-s" "$2")
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

adb_cmd() {
    adb "${ADB_ARGS[@]}" "$@"
}

# ---------- Pre-flight ----------
if ! command -v adb &>/dev/null; then
    echo "ERROR: adb not found."
    exit 1
fi

adb_cmd wait-for-device
DEVICE=$(adb_cmd get-serialno)
echo "📱 Device: $DEVICE"

# ---------- Actions ----------
case "$ACTION" in
    pull)
        echo "⬇️  Pulling $REMOTE_DB_REL → $LOCAL_DB"

        # Use exec-out + run-as + cat to stream the DB binary directly to local file
        adb_cmd exec-out "run-as $APP_ID cat $REMOTE_DB_REL" > "$LOCAL_DB" 2>/dev/null

        # Verify we got a valid SQLite file
        if [ ! -s "$LOCAL_DB" ]; then
            rm -f "$LOCAL_DB"
            echo "ERROR: Failed to pull DB (empty file). Is the app installed and has the DB been created?"
            exit 1
        fi

        HEADER=$(head -c 16 "$LOCAL_DB" | strings | head -1)
        if [[ "$HEADER" != *"SQLite"* ]]; then
            rm -f "$LOCAL_DB"
            echo "ERROR: Pulled file is not a valid SQLite database."
            exit 1
        fi

        SIZE=$(wc -c < "$LOCAL_DB" | tr -d ' ')
        echo "✅ Pulled successfully ($(( SIZE / 1024 )) KB)"
        echo "   → $LOCAL_DB"
        echo ""
        echo "Inspect with:  sqlite3 '$LOCAL_DB' '.tables'"
        ;;

    push)
        if [ ! -f "$LOCAL_DB" ]; then
            echo "ERROR: Local DB not found at $LOCAL_DB"
            echo "       Run '$0 pull' first."
            exit 1
        fi

        echo "⬆️  Pushing $LOCAL_DB → $REMOTE_DB_REL"

        # Push to /data/local/tmp first, then pipe via cat into run-as
        # (cp inside run-as fails on newer Android due to SELinux restrictions)
        adb_cmd push "$LOCAL_DB" /data/local/tmp/graph_rag_push.db > /dev/null

        adb_cmd shell "run-as $APP_ID sh -c 'mkdir -p \$(dirname $REMOTE_DB_REL)'" 2>/dev/null || true

        adb_cmd shell "cat /data/local/tmp/graph_rag_push.db | run-as $APP_ID sh -c 'cat > $REMOTE_DB_REL'" 2>/dev/null \
            || {
                echo "ERROR: Could not push DB into app storage."
                adb_cmd shell "rm -f /data/local/tmp/graph_rag_push.db" 2>/dev/null || true
                exit 1
            }

        adb_cmd shell "rm -f /data/local/tmp/graph_rag_push.db" 2>/dev/null || true

        SIZE=$(wc -c < "$LOCAL_DB" | tr -d ' ')
        echo "✅ Pushed successfully ($(( SIZE / 1024 )) KB)"
        echo ""
        echo "⚠️  Restart the app for changes to take effect."
        ;;

    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $0 <pull|push> [-s <device-serial>]"
        exit 1
        ;;
esac
