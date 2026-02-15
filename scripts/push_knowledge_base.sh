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
#   1. Pushes epistwin_images/*.{JPG,jpeg} → /sdcard/Pictures/RUVA/
#   2. Pushes epistwin_docs/*.pdf          → /sdcard/Documents/RUVA/
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
DEST_IMAGES="/sdcard/Pictures/RUVA"
DEST_DOCS="/sdcard/Documents/RUVA"

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

# We need python3 for reliable JSON parsing
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required for JSON parsing. Install it and re-run."
    exit 1
fi

# Helper: extract a JSON field using python3 (handles nested .metadata.field)
json_field() {
    local file="$1" field="$2"
    python3 - "$file" "$field" <<'PYEOF'
import json, sys, re
with open(sys.argv[1]) as f:
    txt = f.read()

# Replace Unicode smart quotes with standard ASCII quotes
txt = txt.replace('\u201c', '"').replace('\u201d', '"')
txt = txt.replace('\u2018', "'").replace('\u2019', "'")

# Fix unquoted values: lines like   "location": La Rambla, 91, ...
# Process line-by-line to fix values that are not properly quoted
lines = txt.split('\n')
fixed = []
for line in lines:
    # Match key-value lines where value isn't quoted/numeric/bool/null/brace
    m = re.match(r'^(\s*"[^"]+"\s*:\s*)([^"{}\'\[\]0-9tfn\s][^\n]*)$', line)
    if m:
        prefix = m.group(1)
        raw_val = m.group(2).rstrip()
        # Strip trailing comma
        has_comma = raw_val.endswith(',')
        if has_comma:
            raw_val = raw_val[:-1].rstrip()
        # Escape any embedded double quotes inside the value
        raw_val = raw_val.replace('"', '\\"')
        line = prefix + '"' + raw_val + '"' + (',' if has_comma else '')
    fixed.append(line)
txt = '\n'.join(fixed)

# Fix missing closing braces (some files are malformed)
open_braces = txt.count('{')
close_braces = txt.count('}')
txt += '}' * (open_braces - close_braces)

d = json.loads(txt)
keys = sys.argv[2].split('.')
v = d
for k in keys:
    v = v[k]
print(v)
PYEOF
}

# ---------- Clean up previous data ----------
echo ""
echo "🧹 Cleaning up previous RUVA data on device..."

# 1. Remove old images & documents
adb_cmd shell "rm -rf '$DEST_IMAGES'/*" 2>/dev/null || true
adb_cmd shell "rm -rf '$DEST_DOCS'/*" 2>/dev/null || true
echo "   ✅ Old files removed from device."

# 2. Delete MediaStore entries for the old files so stale records don't linger
adb_cmd shell "content delete --uri content://media/external/images/media \
    --where \"_data LIKE '$DEST_IMAGES/%'\"" > /dev/null 2>&1 || true
adb_cmd shell "content delete --uri content://media/external/file \
    --where \"_data LIKE '$DEST_DOCS/%'\"" > /dev/null 2>&1 || true
echo "   ✅ Old MediaStore entries removed."

# 3. Delete all events from the RUVA local calendar (if it exists)
OLD_CAL_ID=$(adb_cmd shell "content query --uri content://com.android.calendar/calendars --projection _id --where \"account_type='LOCAL' AND account_name='RUVA'\" 2>/dev/null" \
    | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 || true)
if [ -n "$OLD_CAL_ID" ]; then
    adb_cmd shell "content delete --uri content://com.android.calendar/events \
        --where \"calendar_id=$OLD_CAL_ID\"" > /dev/null 2>&1 || true
    echo "   ✅ Old calendar events deleted (calendar $OLD_CAL_ID)."
fi

# 4. Delete all RUVA contacts
OLD_RAW_IDS=$(adb_cmd shell "content query --uri content://com.android.contacts/raw_contacts --projection _id --where \"account_name='RUVA' AND account_type='LOCAL'\"" \
    | grep -oE '_id=[0-9]+' | cut -d= -f2 || true)
if [ -n "$OLD_RAW_IDS" ]; then
    for rid in $OLD_RAW_IDS; do
        adb_cmd shell "content delete --uri content://com.android.contacts/raw_contacts/$rid" > /dev/null 2>&1 || true
    done
    echo "   ✅ Old contacts deleted."
fi

# 5. Delete RUVA call log entries (by matching known contact numbers)
#    We read the phone numbers from the knowledge base so we know what to clean
for f in "$KB_JSON"/contact_*.txt; do
    [ -f "$f" ] || continue
    # Quick extraction — json_field is not defined yet at this point in some
    # code paths, but we moved it earlier, so it is available.
    OLD_PHONE=$(json_field "$f" "metadata.telephone_number" 2>/dev/null || true)
    if [ -n "$OLD_PHONE" ]; then
        adb_cmd shell "content delete --uri content://call_log/calls \
            --where \"number='$OLD_PHONE'\"" > /dev/null 2>&1 || true
    fi
done
echo "   ✅ Old call log entries deleted."

echo "   🧹 Cleanup complete."

# We need python3 for reliable JSON parsing
if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required for JSON parsing. Install it and re-run."
    exit 1
fi

# Helper: extract a JSON field using python3 (handles nested .metadata.field)
json_field() {
    local file="$1" field="$2"
    python3 - "$file" "$field" <<'PYEOF'
import json, sys, re
with open(sys.argv[1]) as f:
    txt = f.read()

# Replace Unicode smart quotes with standard ASCII quotes
txt = txt.replace('\u201c', '"').replace('\u201d', '"')
txt = txt.replace('\u2018', "'").replace('\u2019', "'")

# Fix unquoted values: lines like   "location": La Rambla, 91, ...
# Process line-by-line to fix values that are not properly quoted
lines = txt.split('\n')
fixed = []
for line in lines:
    # Match key-value lines where value isn't quoted/numeric/bool/null/brace
    m = re.match(r'^(\s*"[^"]+"\s*:\s*)([^"{}\[\]0-9tfn\s][^\n]*)$', line)
    if m:
        prefix = m.group(1)
        raw_val = m.group(2).rstrip()
        # Strip trailing comma
        has_comma = raw_val.endswith(',')
        if has_comma:
            raw_val = raw_val[:-1].rstrip()
        # Escape any embedded double quotes inside the value
        raw_val = raw_val.replace('"', '\\"')
        line = prefix + '"' + raw_val + '"' + (',' if has_comma else '')
    fixed.append(line)
txt = '\n'.join(fixed)

# Fix missing closing braces (some files are malformed)
open_braces = txt.count('{')
close_braces = txt.count('}')
txt += '}' * (open_braces - close_braces)

d = json.loads(txt)
keys = sys.argv[2].split('.')
v = d
for k in keys:
    v = v[k]
print(v)
PYEOF
}

# Helper: find the photo JSON metadata file matching an image filename.
# e.g.  photo_20250615.JPG  →  photo_20250615.txt
#        photo_20250615(2).JPG → photo_20250615(2).txt
#        photo_photo_20250615(2).JPG → photo_20250615(2).txt  (strip extra prefix)
find_photo_json() {
    local img_basename="$1"
    # Strip extension
    local stem="${img_basename%.*}"
    # Strip a spurious leading "photo_" duplicate (photo_photo_… → photo_…)
    stem="${stem/#photo_photo_/photo_}"
    local candidate="$KB_JSON/${stem}.txt"
    if [ -f "$candidate" ]; then
        echo "$candidate"
    fi
}

# Helper: convert "dd-Mon-yyyy HH:MM" → "YYYYMMDDhhmm.ss" for touch -t
to_touch_ts() {
    local date_str="$1" time_str="$2"
    python3 -c "
from datetime import datetime
dt = datetime.strptime('$date_str $time_str', '%d-%b-%Y %H:%M')
print(dt.strftime('%Y%m%d%H%M.%S'))
"
}

# Helper: convert "dd-Mon-yyyy HH:MM" → epoch seconds
to_epoch_sec() {
    local date_str="$1" time_str="$2"
    python3 -c "
from datetime import datetime
dt = datetime.strptime('$date_str $time_str', '%d-%b-%Y %H:%M')
print(int(dt.timestamp()))
"
}

# ---------- Push images ----------
shopt -s nullglob
echo ""
echo "🖼️  Pushing images to $DEST_IMAGES ..."
IMAGE_COUNT=0
# Collect image basenames and their correct epoch timestamps for MediaStore update
declare -a IMAGE_BASENAMES=()
declare -a IMAGE_EPOCHS=()

for img in "$KB_IMAGES"/*.JPG "$KB_IMAGES"/*.jpeg "$KB_IMAGES"/*.jpg "$KB_IMAGES"/*.png; do
    [ -f "$img" ] || continue
    BASENAME="$(basename "$img")"
    echo "   -> $BASENAME"
    adb_cmd push "$img" "$DEST_IMAGES/$BASENAME" > /dev/null

    # Look up the creation date from the corresponding JSON metadata file
    JSON_FILE=$(find_photo_json "$BASENAME")
    if [ -n "$JSON_FILE" ]; then
        CREATION_DATE=$(json_field "$JSON_FILE" "metadata.creation_date")
        CREATION_TIME=$(json_field "$JSON_FILE" "metadata.creation_time")
        TOUCH_TS=$(to_touch_ts "$CREATION_DATE" "$CREATION_TIME")
        EPOCH_SEC=$(to_epoch_sec "$CREATION_DATE" "$CREATION_TIME")

        # Set the file modification time on the device so MediaScanner picks it up
        adb_cmd shell "touch -t $TOUCH_TS '$DEST_IMAGES/$BASENAME'" 2>/dev/null || true

        IMAGE_BASENAMES+=("$BASENAME")
        IMAGE_EPOCHS+=("$EPOCH_SEC")
        echo "      📅 date set to $CREATION_DATE $CREATION_TIME"
    else
        echo "      ⚠️  no metadata file found, keeping push timestamp"
    fi

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

# ---------- Fix photo dates in MediaStore ----------
echo ""
echo "📅 Updating photo dates in MediaStore..."
# Wait a moment for the media scanner to finish indexing
sleep 2

FIXED_COUNT=0
for i in "${!IMAGE_BASENAMES[@]}"; do
    BNAME="${IMAGE_BASENAMES[$i]}"
    EPOCH="${IMAGE_EPOCHS[$i]}"

    # Escape parentheses in display name for the SQL where clause
    BNAME_ESC="${BNAME//\(/\\(}"
    BNAME_ESC="${BNAME_ESC//\)/\\)}"

    # Update date_added and date_modified in MediaStore (values in seconds)
    adb_cmd shell "content update --uri content://media/external/images/media \
        --bind date_added:i:$EPOCH \
        --bind date_modified:i:$EPOCH \
        --where \"_display_name='$BNAME_ESC'\"" > /dev/null 2>&1 || true

    echo "   -> $BNAME → epoch $EPOCH"
    FIXED_COUNT=$((FIXED_COUNT + 1))
done
echo "   ✅ $FIXED_COUNT photo date(s) fixed in MediaStore."

# ==========================================================================
#  PART 2 — Insert structured data via Android content providers
# ==========================================================================

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
CAL_ID=$(adb_cmd shell "content query --uri content://com.android.calendar/calendars --projection _id --where \"account_type='LOCAL' AND account_name='RUVA'\" 2>/dev/null" \
    | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2 || true)

if [ -z "$CAL_ID" ]; then
    echo "   Creating local calendar..."
    adb_cmd shell "content insert --uri 'content://com.android.calendar/calendars?caller_is_syncadapter=true&account_name=RUVA&account_type=LOCAL' \
        --bind account_name:s:RUVA \
        --bind account_type:s:LOCAL \
        --bind name:s:RUVA \
        --bind calendar_displayName:s:RUVA \
        --bind calendar_color:i:-14069085 \
        --bind calendar_access_level:i:700 \
        --bind ownerAccount:s:RUVA \
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

    # Escape double quotes in label for adb shell
    LABEL_ESC=$(printf '%s' "$LABEL" | sed 's/"/\\"/g')

    echo "   -> $LABEL ($DATE $START_TIME-$END_TIME)"
    adb_cmd shell "content insert --uri content://com.android.calendar/events \
        --bind calendar_id:i:$CAL_ID \
        --bind title:s:\"$LABEL_ESC\" \
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

    # Escape double quotes in label for adb shell
    LABEL_ESC=$(printf '%s' "$LABEL" | sed 's/"/\\"/g')

    echo "   -> $LABEL ($RRULE, $START_TIME-$END_TIME)"
    adb_cmd shell "content insert --uri content://com.android.calendar/events \
        --bind calendar_id:i:$CAL_ID \
        --bind title:s:\"$LABEL_ESC\" \
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

# Build a lookup map: contact_id -> phone number / name (using temp file for bash 3 compat)
CONTACT_MAP_FILE=$(mktemp)
trap "rm -f $CONTACT_MAP_FILE" EXIT

for f in "$KB_JSON"/contact_*.txt; do
    [ -f "$f" ] || continue
    CONTACT_ID=$(json_field "$f" "contact")
    NAME=$(json_field "$f" "metadata.name")
    PHONE=$(json_field "$f" "metadata.telephone_number")

    # Store in lookup file: CONTACT_ID|PHONE|NAME
    echo "${CONTACT_ID}|${PHONE}|${NAME}" >> "$CONTACT_MAP_FILE"

    echo "   -> $NAME ($PHONE)"

    # Step 1: Insert raw contact
    adb_cmd shell "content insert --uri content://com.android.contacts/raw_contacts \
        --bind account_type:s:LOCAL \
        --bind account_name:s:RUVA" > /dev/null

    # Get the raw_contact_id we just created
    RAW_ID=$(adb_cmd shell "content query --uri content://com.android.contacts/raw_contacts \
        --projection _id --sort '_id DESC LIMIT 1'" \
        | grep -oE '_id=[0-9]+' | head -1 | cut -d= -f2)

    # Escape double quotes in name for adb shell
    NAME_ESC=$(printf '%s' "$NAME" | sed 's/"/\\"/g')

    # Step 2: Insert display name
    adb_cmd shell "content insert --uri content://com.android.contacts/data \
        --bind raw_contact_id:i:$RAW_ID \
        --bind mimetype:s:vnd.android.cursor.item/name \
        --bind data1:s:\"$NAME_ESC\"" > /dev/null

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

    # Resolve contact phone number and name from lookup file
    CONTACT_LINE=$(grep "^${WITH_CONTACT}|" "$CONTACT_MAP_FILE" 2>/dev/null | head -1)
    if [ -n "$CONTACT_LINE" ]; then
        PHONE=$(echo "$CONTACT_LINE" | cut -d'|' -f2)
        CNAME=$(echo "$CONTACT_LINE" | cut -d'|' -f3)
    else
        PHONE="unknown"
        CNAME="$WITH_CONTACT"
    fi

    echo "   -> $DIRECTION call with $CNAME ($DATE $START_TIME, ${DURATION_SEC}s)"
    CNAME_ESC=$(printf '%s' "$CNAME" | sed 's/"/\\"/g')
    adb_cmd shell "content insert --uri content://call_log/calls \
        --bind number:s:'$PHONE' \
        --bind date:l:$START_MS \
        --bind duration:l:$DURATION_SEC \
        --bind type:i:$CALL_TYPE \
        --bind name:s:\"$CNAME_ESC\" \
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
