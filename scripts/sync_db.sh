#!/usr/bin/env bash
# =============================================================================
# sync_db.sh — Pull or push the graph_rag.db SQLite database from/to the
#              Android emulator for local inspection and editing.
#
# Supports three access methods (tried in order):
#   1. run-as    — works on debug builds
#   2. adb root  — works on non-Google-Play emulator images
#   3. broadcast — works on ANY build (uses a BroadcastReceiver that
#                  copies the DB to/from the external files dir)
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
# Database name used by SQLiteOpenHelper (GraphStore.kt)
DB_NAME="flutter_gemma_graph.db"
# Path relative to the app's data dir (used with run-as / adb root)
REMOTE_DB_REL="databases/$DB_NAME"
# Full internal path (used with adb root)
REMOTE_DB_ABS="/data/user/0/$APP_ID/$REMOTE_DB_REL"
# External files dir staging path (used with broadcast method)
EXT_FILES_DIR="/sdcard/Android/data/$APP_ID/files"
STAGING_NAME="flutter_gemma_graph_sync.db"
STAGING_PATH="$EXT_FILES_DIR/$STAGING_NAME"

LOCAL_DB="$PROJECT_ROOT/knowledge_base/graph_rag.db"

# Broadcast receiver (must match AndroidManifest.xml + DbSyncReceiver.kt)
RECEIVER="$APP_ID/.DbSyncReceiver"
ACTION_EXPORT="$APP_ID.DB_EXPORT"
ACTION_IMPORT="$APP_ID.DB_IMPORT"

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

# ---------- Detect access method ----------
# Method 1: run-as (debug builds only)
# Method 2: adb root (non-Google-Play emulator images)
# Method 3: broadcast + external files dir (any build, requires DbSyncReceiver)
METHOD=""

if adb_cmd shell "run-as $APP_ID ls $REMOTE_DB_REL" &>/dev/null; then
    METHOD="run-as"
    echo "🔑 Access method: run-as (debug build)"
elif adb_cmd root 2>&1 | grep -q "restarting"; then
    # adb root succeeded — wait for device to come back
    sleep 1
    adb_cmd wait-for-device
    METHOD="root"
    echo "🔑 Access method: adb root"
else
    # Check that the app is installed (sanity check for broadcast method)
    if adb_cmd shell "pm path $APP_ID" 2>/dev/null | grep -q "package:"; then
        METHOD="broadcast"
        echo "🔑 Access method: broadcast (release build)"
    else
        echo "ERROR: No access method available."
        echo "  - run-as failed (release build)"
        echo "  - adb root failed (Google-Play emulator image)"
        echo "  - App not installed"
        echo ""
        echo "Options:"
        echo "  1. Use a non-Google-Play emulator image (allows adb root)"
        echo "  2. Run the app in debug mode (flutter run -d <device>)"
        exit 1
    fi
fi

# ---------- Helper: validate pulled file ----------
validate_sqlite() {
    local file="$1"
    if [ ! -s "$file" ]; then
        rm -f "$file"
        echo "ERROR: Failed to pull DB (empty file). Is the app installed and has the DB been created?"
        exit 1
    fi
    local header
    header=$(head -c 16 "$file" | strings | head -1)
    if [[ "$header" != *"SQLite"* ]]; then
        rm -f "$file"
        echo "ERROR: Pulled file is not a valid SQLite database."
        exit 1
    fi
}

# ---------- PULL ----------
do_pull() {
    echo "⬇️  Pulling $DB_NAME → $LOCAL_DB"
    mkdir -p "$(dirname "$LOCAL_DB")"

    case "$METHOD" in
        run-as)
            adb_cmd exec-out "run-as $APP_ID cat $REMOTE_DB_REL" > "$LOCAL_DB" 2>/dev/null
            ;;
        root)
            adb_cmd pull "$REMOTE_DB_ABS" "$LOCAL_DB" > /dev/null
            ;;
        broadcast)
            # Ask the app to copy the DB to the external files dir
            echo "   Requesting DB export via broadcast…"
            # Clear logcat and send explicit broadcast
            adb_cmd logcat -c 2>/dev/null || true
            adb_cmd shell "am broadcast -a $ACTION_EXPORT -n $RECEIVER" > /dev/null 2>&1

            # Wait for the receiver to finish (poll logcat)
            local attempts=0
            local log=""
            while [ $attempts -lt 10 ]; do
                sleep 0.5
                log=$(adb_cmd logcat -d -s DbSyncReceiver 2>/dev/null)
                if echo "$log" | grep -qE "EXPORT_OK|EXPORT_FAIL"; then
                    break
                fi
                attempts=$((attempts + 1))
            done

            if echo "$log" | grep -q "EXPORT_FAIL"; then
                echo "ERROR: App reported export failure:"
                echo "$log" | grep "EXPORT_FAIL" | sed 's/.*EXPORT_FAIL: //'
                exit 1
            fi

            if ! echo "$log" | grep -q "EXPORT_OK"; then
                echo "ERROR: No response from DbSyncReceiver."
                echo "  Make sure the app is running and was built with DbSyncReceiver."
                exit 1
            fi

            adb_cmd pull "$STAGING_PATH" "$LOCAL_DB" > /dev/null
            # Clean up staging file on device
            adb_cmd shell "rm -f $STAGING_PATH" 2>/dev/null || true
            ;;
    esac

    validate_sqlite "$LOCAL_DB"

    local size
    size=$(wc -c < "$LOCAL_DB" | tr -d ' ')
    echo "✅ Pulled successfully ($(( size / 1024 )) KB)"
    echo "   → $LOCAL_DB"
    echo ""
    echo "Inspect with:  sqlite3 '$LOCAL_DB' '.tables'"
}

# ---------- PUSH ----------
do_push() {
    if [ ! -f "$LOCAL_DB" ]; then
        echo "ERROR: Local DB not found at $LOCAL_DB"
        echo "       Run '$0 pull' first."
        exit 1
    fi

    echo "⬆️  Pushing $LOCAL_DB → $DB_NAME"

    case "$METHOD" in
        run-as)
            adb_cmd push "$LOCAL_DB" /data/local/tmp/graph_rag_push.db > /dev/null

            adb_cmd shell "run-as $APP_ID sh -c 'mkdir -p \$(dirname $REMOTE_DB_REL)'" 2>/dev/null || true

            adb_cmd shell "cat /data/local/tmp/graph_rag_push.db | run-as $APP_ID sh -c 'cat > $REMOTE_DB_REL'" 2>/dev/null \
                || {
                    echo "ERROR: Could not push DB into app storage."
                    adb_cmd shell "rm -f /data/local/tmp/graph_rag_push.db" 2>/dev/null || true
                    exit 1
                }
            adb_cmd shell "rm -f /data/local/tmp/graph_rag_push.db" 2>/dev/null || true
            ;;
        root)
            adb_cmd push "$LOCAL_DB" "$REMOTE_DB_ABS" > /dev/null
            # Fix ownership so the app can read it
            local app_uid
            app_uid=$(adb_cmd shell "stat -c '%u' /data/user/0/$APP_ID/" 2>/dev/null | tr -d '\r')
            if [ -n "$app_uid" ]; then
                adb_cmd shell "chown $app_uid:$app_uid $REMOTE_DB_ABS" 2>/dev/null || true
                adb_cmd shell "chmod 660 $REMOTE_DB_ABS" 2>/dev/null || true
            fi
            ;;
        broadcast)
            # Push the local DB to the external files dir, then ask the app to import it
            # Create the external dir if it doesn't exist
            adb_cmd shell "mkdir -p $EXT_FILES_DIR" 2>/dev/null || true
            adb_cmd push "$LOCAL_DB" "$STAGING_PATH" > /dev/null

            echo "   Requesting DB import via broadcast…"
            # Clear logcat and send explicit broadcast
            adb_cmd logcat -c 2>/dev/null || true
            adb_cmd shell "am broadcast -a $ACTION_IMPORT -n $RECEIVER" > /dev/null 2>&1

            # Wait for the receiver to finish (poll logcat)
            local attempts=0
            local log=""
            while [ $attempts -lt 10 ]; do
                sleep 0.5
                log=$(adb_cmd logcat -d -s DbSyncReceiver 2>/dev/null)
                if echo "$log" | grep -qE "IMPORT_OK|IMPORT_FAIL"; then
                    break
                fi
                attempts=$((attempts + 1))
            done

            if echo "$log" | grep -q "IMPORT_FAIL"; then
                # Clean up staging file
                adb_cmd shell "rm -f $STAGING_PATH" 2>/dev/null || true
                echo "ERROR: App reported import failure:"
                echo "$log" | grep "IMPORT_FAIL" | sed 's/.*IMPORT_FAIL: //'
                exit 1
            fi

            if echo "$log" | grep -q "IMPORT_OK"; then
                echo "   Import confirmed by app."
            else
                echo "   ⚠️  Could not confirm import from logcat. Check manually."
            fi
            ;;
    esac

    local size
    size=$(wc -c < "$LOCAL_DB" | tr -d ' ')
    echo "✅ Pushed successfully ($(( size / 1024 )) KB)"
    echo ""
    echo "⚠️  Restart the app for changes to take effect."
}

# ---------- Main ----------
case "$ACTION" in
    pull) do_pull ;;
    push) do_push ;;
    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $0 <pull|push> [-s <device-serial>]"
        exit 1
        ;;
esac
