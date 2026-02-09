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
#   4. Inserts calendar events from epistwin_jsontxt/event_*.txt
#   5. Inserts recurrent events from epistwin_jsontxt/recurrentEvent_*.txt
#   6. Inserts contacts from epistwin_jsontxt/contact_*.txt
#   7. Inserts phone call log entries from epistwin_jsontxt/phoneCall_*.txt
#
# Requirements:
#   - adb in PATH
#   - A running emulator (or connected device)
#   - python3 (for JSON parsing)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KB_IMAGES="$PROJECT_ROOT/knowledge_base/epistwin_images"
KB_DOCS="$PROJECT_ROOT/knowledge_base/epistwin_docs"
KB_JSON="$PROJECT_ROOT/knowledge_base/epistwin_jsontxt"

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

# ==========================================================================
#  PART 2 — Insert structured data via Android content providers
# ==========================================================================

# We need python3 for reliable JSON parsing
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required for JSON parsing. Install it and re-run."
    exit 1
fi

# Helper: extract a JSON field using python3 (handles nested .metadata.field)
json_field() {
    local file="$1" field="$2"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    txt = f.read()
    # fix missing closing braces (some files are malformed)
    open_braces = txt.count('{')
    close_braces = txt.count('}')
    txt += '}' * (open_braces - close_braces)
    d = json.loads(txt)
keys = sys.argv[2].split('.')
v = d
for k in keys:
    v = v[k]
print(v)
" "$file" "$field"
}

# Helper: convert "dd-Mon-yyyy HH:MM" to epoch millis
# Input: date="23-Jul-2025"  time="09:00"
to_epoch_ms() {
    local date_str="$1" time_str="$2"
    python3 -c "
from datetime import datetime
dt = datetime.strptime('$date_str $time_str', '%d-%b-%Y %H:%M')
print(int(dt.timestamp() * 1000))
"
}

# Helper: convert "dd-Mon-yyyy HH:MM:SS" to epoch millis (for call log)
to_epoch_ms_sec() {
    local date_str="$1" time_str="$2"
    python3 -c "
from datetime import datetime
dt = datetime.strptime('$date_str $time_str', '%d-%b-%Y %H:%M:%S')
print(int(dt.timestamp() * 1000))
"
}

# Helper: parse duration string "Xh, Ymin, Zsec" to seconds
duration_to_seconds() {
    local dur="$1"
    python3 -c "
import re
m = re.match(r'(\d+)h,\s*(\d+)min,\s*(\d+)sec', '$dur')
print(int(m.group(1))*3600 + int(m.group(2))*60 + int(m.group(3)))
"
}

# Helper: map day names to RFC 5545 BYDAY codes
days_to_byday() {
    local days_str="$1"
    python3 -c "
mapping = {
    'Monday': 'MO', 'Tuesday': 'TU', 'Wednesday': 'WE',
    'Thursday': 'TH', 'Friday': 'FR', 'Saturday': 'SA', 'Sunday': 'SU'
}
days = [d.strip() for d in '$days_str'.split(',')]
print(','.join(mapping[d] for d in days))
"
}

# ---------- Ensure a local calendar exists ----------
echo ""
echo "📅 Ensuring a local calendar account exists..."

# Check if a local calendar already exists
CAL_ID=$(adb_cmd shell "content query --uri content://com.android.calendar/calendars --projection _id --where \"account_type='LOCAL'\" 2>/dev/null" \
    | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 || true)

if [ -z "$CAL_ID" ]; then
    echo "   Creating local calendar..."
    adb_cmd shell "content insert --uri content://com.android.calendar/calendars \
        --bind account_name:s:EpisTwin \
        --bind account_type:s:LOCAL \
        --bind name:s:EpisTwin \
        --bind calendar_displayName:s:EpisTwin \
        --bind calendar_color:i:-14069085 \
        --bind calendar_access_level:i:700 \
        --bind ownerAccount:s:EpisTwin \
        --bind visible:i:1 \
        --bind sync_events:i:1 \
        --bind calendar_timezone:s:Europe/Rome" > /dev/null

    CAL_ID=$(adb_cmd shell "content query --uri content://com.android.calendar/calendars --projection _id --where \"account_type='LOCAL'\"" \
        | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2)
fi
echo "   ✅ Calendar ID: $CAL_ID"

# ---------- Insert single-occurrence events ----------
echo ""
echo "📅 Inserting calendar events..."
EVENT_COUNT=0
for f in "$KB_JSON"/event_*.txt; do
    [ -f "$f" ] || continue
    LABEL=$(json_field "$f" "metadata.label")
    DATE=$(json_field "$f" "metadata.date")
    START_TIME=$(json_field "$f" "metadata.start_time")
    END_TIME=$(json_field "$f" "metadata.end_time")

    START_MS=$(to_epoch_ms "$DATE" "$START_TIME")
    END_MS=$(to_epoch_ms "$DATE" "$END_TIME")

    echo "   -> $LABEL ($DATE $START_TIME-$END_TIME)"
    adb_cmd shell "content insert --uri content://com.android.calendar/events \
        --bind calendar_id:i:$CAL_ID \
        --bind title:s:'$LABEL' \
        --bind dtstart:l:$START_MS \
        --bind dtend:l:$END_MS \
        --bind eventTimezone:s:Europe/Rome \
        --bind hasAlarm:i:0" > /dev/null
    EVENT_COUNT=$((EVENT_COUNT + 1))
done
echo "   ✅ $EVENT_COUNT event(s) inserted."

# ---------- Insert recurrent events ----------
echo ""
echo "🔁 Inserting recurrent events..."
RECUR_COUNT=0
for f in "$KB_JSON"/recurrentEvent_*.txt; do
    [ -f "$f" ] || continue
    LABEL=$(json_field "$f" "metadata.label")
    START_TIME=$(json_field "$f" "metadata.start_time")
    END_TIME=$(json_field "$f" "metadata.end_time")
    FREQ=$(json_field "$f" "metadata.repeat_frequency")
    ON=$(json_field "$f" "metadata.on")

    FREQ_UPPER=$(echo "$FREQ" | tr '[:lower:]' '[:upper:]')

    # We need a dtstart — use a reference Monday (2025-06-02) as anchor
    REF_DATE="02-Jun-2025"
    START_MS=$(to_epoch_ms "$REF_DATE" "$START_TIME")

    # Calculate duration in RFC 5545 format for events spanning midnight
    START_H=${START_TIME%%:*}
    START_M=${START_TIME##*:}
    END_H=${END_TIME%%:*}
    END_M=${END_TIME##*:}
    START_MINS=$((10#$START_H * 60 + 10#$START_M))
    END_MINS=$((10#$END_H * 60 + 10#$END_M))
    if [ "$END_MINS" -le "$START_MINS" ]; then
        # Crosses midnight
        DURATION_MINS=$(( (1440 - START_MINS) + END_MINS ))
    else
        DURATION_MINS=$(( END_MINS - START_MINS ))
    fi
    DUR_H=$((DURATION_MINS / 60))
    DUR_M=$((DURATION_MINS % 60))
    DURATION_RFC="PT${DUR_H}H${DUR_M}M"

    if [ "$FREQ_UPPER" = "WEEKLY" ]; then
        BYDAY=$(days_to_byday "$ON")
        RRULE="FREQ=WEEKLY;BYDAY=$BYDAY"
    elif [ "$FREQ_UPPER" = "YEARLY" ]; then
        # "on": "11-Sep" → BYMONTH=9;BYMONTHDAY=11
        MON_DAY="$ON"
        MONTH_NUM=$(python3 -c "from datetime import datetime; print(datetime.strptime('$MON_DAY-2025','%d-%b-%Y').month)")
        DAY_NUM=$(python3 -c "from datetime import datetime; print(datetime.strptime('$MON_DAY-2025','%d-%b-%Y').day)")
        RRULE="FREQ=YEARLY;BYMONTH=$MONTH_NUM;BYMONTHDAY=$DAY_NUM"
    else
        RRULE="FREQ=$FREQ_UPPER"
    fi

    echo "   -> $LABEL ($RRULE, $START_TIME-$END_TIME)"
    adb_cmd shell "content insert --uri content://com.android.calendar/events \
        --bind calendar_id:i:$CAL_ID \
        --bind title:s:'$LABEL' \
        --bind dtstart:l:$START_MS \
        --bind duration:s:$DURATION_RFC \
        --bind rrule:s:'$RRULE' \
        --bind eventTimezone:s:Europe/Rome \
        --bind hasAlarm:i:0" > /dev/null
    RECUR_COUNT=$((RECUR_COUNT + 1))
done
echo "   ✅ $RECUR_COUNT recurrent event(s) inserted."

# ---------- Insert contacts ----------
echo ""
echo "👤 Inserting contacts..."
CONTACT_COUNT=0

# Build a lookup map: contact_id -> phone number
declare -A CONTACT_PHONES
declare -A CONTACT_NAMES

for f in "$KB_JSON"/contact_*.txt; do
    [ -f "$f" ] || continue
    CONTACT_ID=$(json_field "$f" "contact")
    NAME=$(json_field "$f" "metadata.name")
    PHONE=$(json_field "$f" "metadata.telephone_number")

    CONTACT_PHONES["$CONTACT_ID"]="$PHONE"
    CONTACT_NAMES["$CONTACT_ID"]="$NAME"

    echo "   -> $NAME ($PHONE)"

    # Step 1: Insert raw contact
    adb_cmd shell "content insert --uri content://com.android.contacts/raw_contacts \
        --bind account_type:s:LOCAL \
        --bind account_name:s:EpisTwin" > /dev/null

    # Get the raw_contact_id we just created
    RAW_ID=$(adb_cmd shell "content query --uri content://com.android.contacts/raw_contacts \
        --projection _id --sort '_id DESC LIMIT 1'" \
        | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2)

    # Step 2: Insert display name
    adb_cmd shell "content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:i:$RAW_ID \
        --bind mimetype:s:vnd.android.cursor.item/name \
        --bind data1:s:'$NAME'" > /dev/null

    # Step 3: Insert phone number
    adb_cmd shell "content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:i:$RAW_ID \
        --bind mimetype:s:vnd.android.cursor.item/phone_v2 \
        --bind data1:s:'$PHONE' \
        --bind data2:i:1" > /dev/null

    CONTACT_COUNT=$((CONTACT_COUNT + 1))
done
echo "   ✅ $CONTACT_COUNT contact(s) inserted."

# ---------- Insert phone call log entries ----------
echo ""
echo "📞 Inserting call log entries..."
CALL_COUNT=0
for f in "$KB_JSON"/phoneCall_*.txt; do
    [ -f "$f" ] || continue
    DATE=$(json_field "$f" "metadata.date")
    START_TIME=$(json_field "$f" "metadata.start_time")
    DURATION_STR=$(json_field "$f" "metadata.duration")
    DIRECTION=$(json_field "$f" "metadata.call_direction")
    WITH_CONTACT=$(json_field "$f" "metadata.with_contact")

    START_MS=$(to_epoch_ms_sec "$DATE" "$START_TIME")
    DURATION_SEC=$(duration_to_seconds "$DURATION_STR")

    # Map direction to Android CallLog.Calls type
    # 1 = incoming, 2 = outgoing, 3 = missed
    if [ "$DIRECTION" = "incoming" ]; then
        CALL_TYPE=1
    elif [ "$DIRECTION" = "outgoing" ]; then
        CALL_TYPE=2
    else
        CALL_TYPE=3
    fi

    # Resolve contact phone number
    PHONE="${CONTACT_PHONES[$WITH_CONTACT]:-unknown}"
    CNAME="${CONTACT_NAMES[$WITH_CONTACT]:-$WITH_CONTACT}"

    echo "   -> $DIRECTION call with $CNAME ($DATE $START_TIME, ${DURATION_SEC}s)"
    adb_cmd shell "content insert --uri content://call_log/calls \
        --bind number:s:'$PHONE' \
        --bind date:l:$START_MS \
        --bind duration:l:$DURATION_SEC \
        --bind type:i:$CALL_TYPE \
        --bind name:s:'$CNAME' \
        --bind new:i:0" > /dev/null
    CALL_COUNT=$((CALL_COUNT + 1))
done
echo "   ✅ $CALL_COUNT call log entry(ies) inserted."

# ---------- Summary ----------
echo ""
echo "============================================"
echo " Done! Pushed to emulator ($DEVICE):"
echo "   🖼️  $IMAGE_COUNT images  → $DEST_IMAGES"
echo "   📄 $DOC_COUNT documents → $DEST_DOCS"
echo "   📅 $EVENT_COUNT calendar events"
echo "   🔁 $RECUR_COUNT recurrent events"
echo "   👤 $CONTACT_COUNT contacts"
echo "   📞 $CALL_COUNT call log entries"
echo ""
echo " The files should now be visible in:"
echo "   - Gallery / Photos app (images)"
echo "   - Files / Document picker (documents)"
echo "   - Calendar app (events)"
echo "   - Contacts app (contacts)"
echo "   - Phone app / Call log (calls)"
echo "============================================"
