package dev.flutterberlin.flutter_gemma_example

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.CalendarContract
import android.provider.CallLog
import android.provider.ContactsContract
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*

/**
 * Provides two test-data operations accessible from the Flutter Settings tab:
 *
 * 1. **resetTestGraph** — replaces the running GraphRAG SQLite database with a
 *    pre-built snapshot bundled as a Flutter asset (`assets/test_data/graph_rag.db`).
 *
 * 2. **uploadTestData** — populates Android content providers (Calendar, Contacts,
 *    CallLog) and shared-storage directories (Pictures/RUVA, Documents/RUVA) with
 *    the knowledge-base files bundled as Flutter assets.
 */
class TestDataService(
    private val context: Context,
    flutterEngine: FlutterEngine
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "TestDataService"
        private const val CHANNEL = "test_data_channel"
        private const val GRAPH_DB_NAME = "flutter_gemma_graph.db"
        private const val TIMEZONE = "Europe/Rome"
        private const val REF_DATE = "02-Jun-2025" // anchor for recurrent events
    }

    private val channel: MethodChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger,
        CHANNEL
    )

    private val flutterLoader = FlutterInjector.instance().flutterLoader()

    // Cached photo metadata for MediaStore date fixing
    private data class PhotoMeta(val filename: String, val epochSeconds: Long)
    private val photoMetas = mutableListOf<PhotoMeta>()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "resetTestGraph" -> {
                Thread {
                    try {
                        resetTestGraph()
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.success(null)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "resetTestGraph failed", e)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.error("RESET_FAILED", e.message, null)
                        }
                    }
                }.start()
            }
            "uploadTestData" -> {
                Thread {
                    try {
                        val counts = uploadTestData()
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.success(counts)
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "uploadTestData failed", e)
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.error("UPLOAD_FAILED", e.message, null)
                        }
                    }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    // =========================================================================
    // 1. Reset Test Graph
    // =========================================================================

    private fun resetTestGraph() {
        val assetKey = flutterLoader.getLookupKeyForAsset("assets/test_data/graph_rag.db")
        val dbFile = context.getDatabasePath(GRAPH_DB_NAME)

        // Ensure parent directory exists
        dbFile.parentFile?.mkdirs()

        context.assets.open(assetKey).use { input ->
            FileOutputStream(dbFile).use { output ->
                input.copyTo(output)
            }
        }

        Log.i(TAG, "Graph database reset successfully (${dbFile.length()} bytes)")
    }

    // =========================================================================
    // 2. Upload Test Data
    // =========================================================================

    private fun uploadTestData(): Map<String, Int> {
        photoMetas.clear()

        // Log permission status for debugging
        logPermissionStatus()

        // Discover asset files
        val jsonDir = flutterLoader.getLookupKeyForAsset("assets/test_data/jsontxt")
        val jsonFiles = context.assets.list(jsonDir) ?: emptyArray()

        val imageDir = flutterLoader.getLookupKeyForAsset("assets/test_data/images")
        val imageFiles = context.assets.list(imageDir) ?: emptyArray()

        val docDir = flutterLoader.getLookupKeyForAsset("assets/test_data/docs")
        val docFiles = context.assets.list(docDir) ?: emptyArray()

        Log.i(TAG, "Found ${jsonFiles.size} JSON, ${imageFiles.size} images, ${docFiles.size} docs")

        // 1. Clean old RUVA data
        cleanOldData(jsonDir, jsonFiles)

        // 2. Copy images (with metadata dates via MediaStore)
        val imageCount = pushImages(imageDir, imageFiles, jsonDir, jsonFiles)

        // 3. Copy documents
        val docCount = pushDocuments(docDir, docFiles)

        // 4. Trigger media scan and wait
        triggerMediaScan(imageDir, imageFiles, docDir, docFiles)
        Thread.sleep(2000)

        // 5. Fix photo dates in MediaStore (second pass for files indexed by scanner)
        fixPhotoDatesInMediaStore()

        // 6. Create/find RUVA calendar
        val calId = ensureRuvaCalendar()

        // 7. Insert events
        val eventCount = insertEvents(jsonDir, jsonFiles, calId)

        // 8. Insert recurrent events
        val recurCount = insertRecurrentEvents(jsonDir, jsonFiles, calId)

        // 9. Insert contacts (and build lookup map)
        val contactMap = mutableMapOf<String, Pair<String, String>>() // id -> (phone, name)
        val contactCount = insertContacts(jsonDir, jsonFiles, contactMap)

        // 10. Insert call log
        val callCount = insertCallLog(jsonDir, jsonFiles, contactMap)

        Log.i(TAG, "Upload complete: $imageCount images, $docCount docs, " +
                "$eventCount events, $recurCount recurrent, " +
                "$contactCount contacts, $callCount calls")

        return mapOf(
            "images" to imageCount,
            "documents" to docCount,
            "events" to eventCount,
            "recurrentEvents" to recurCount,
            "contacts" to contactCount,
            "calls" to callCount
        )
    }

    // -------------------------------------------------------------------------
    // Cleanup
    // -------------------------------------------------------------------------

    private fun cleanOldData(jsonDir: String, jsonFiles: Array<String>) {
        Log.i(TAG, "Cleaning old RUVA data...")

        // Delete MediaStore entries for RUVA images
        try {
            val destImages = "${Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_PICTURES)}/RUVA"
            context.contentResolver.delete(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                "${MediaStore.Images.Media.DATA} LIKE ?",
                arrayOf("$destImages/%")
            )
            // Also delete the actual files
            File(destImages).listFiles()?.forEach { it.delete() }
        } catch (e: Exception) { Log.w(TAG, "Clean images: $e") }

        // Delete MediaStore entries for RUVA documents
        try {
            val destDocs = "${Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOCUMENTS)}/RUVA"
            context.contentResolver.delete(
                MediaStore.Files.getContentUri("external"),
                "${MediaStore.Files.FileColumns.DATA} LIKE ?",
                arrayOf("$destDocs/%")
            )
            File(destDocs).listFiles()?.forEach { it.delete() }
        } catch (e: Exception) { Log.w(TAG, "Clean docs: $e") }

        // Delete RUVA calendar events
        try {
            val calId = findRuvaCalendarId()
            if (calId != null) {
                context.contentResolver.delete(
                    CalendarContract.Events.CONTENT_URI,
                    "${CalendarContract.Events.CALENDAR_ID} = ?",
                    arrayOf(calId.toString())
                )
            }
        } catch (e: Exception) { Log.w(TAG, "Clean calendar: $e") }

        // Delete RUVA contacts
        try {
            val rawContactIds = findRuvaRawContactIds()
            for (id in rawContactIds) {
                context.contentResolver.delete(
                    ContentUris.withAppendedId(ContactsContract.RawContacts.CONTENT_URI, id),
                    null, null
                )
            }
        } catch (e: Exception) { Log.w(TAG, "Clean contacts: $e") }

        // Delete call log entries for known RUVA contacts
        try {
            for (filename in jsonFiles) {
                if (!filename.startsWith("contact_")) continue
                val json = readJsonAsset("$jsonDir/$filename")
                val phone = json.optJSONObject("metadata")?.optString("telephone_number") ?: continue
                if (phone.isNotEmpty()) {
                    context.contentResolver.delete(
                        CallLog.Calls.CONTENT_URI,
                        "${CallLog.Calls.NUMBER} = ?",
                        arrayOf(phone)
                    )
                }
            }
        } catch (e: Exception) { Log.w(TAG, "Clean call log: $e") }

        Log.i(TAG, "Cleanup complete")
    }

    // -------------------------------------------------------------------------
    // Push Images
    // -------------------------------------------------------------------------

    private fun pushImages(
        imageDir: String,
        imageFiles: Array<String>,
        jsonDir: String,
        jsonFiles: Array<String>
    ): Int {
        var count = 0
        for (filename in imageFiles) {
            val mimeType = when {
                filename.endsWith(".JPG", true) || filename.endsWith(".jpeg", true)
                    || filename.endsWith(".jpg", true) -> "image/jpeg"
                filename.endsWith(".png", true) -> "image/png"
                else -> continue
            }

            // Look up creation date from photo metadata JSON
            val jsonName = findPhotoJsonName(filename)
            var epochSeconds = 0L
            if (jsonFiles.contains(jsonName)) {
                try {
                    val json = readJsonAsset("$jsonDir/$jsonName")
                    val meta = json.optJSONObject("metadata")
                    if (meta != null) {
                        val creationDate = meta.optString("creation_date", "")
                        val creationTime = meta.optString("creation_time", "")
                        if (creationDate.isNotEmpty() && creationTime.isNotEmpty()) {
                            epochSeconds = parseDateToEpochSeconds(creationDate, creationTime)
                        }
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to read photo metadata for $filename: $e")
                }
            }

            // Insert via MediaStore
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, filename)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/RUVA")
                } else {
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_PICTURES), "RUVA")
                    dir.mkdirs()
                    put(MediaStore.Images.Media.DATA, File(dir, filename).absolutePath)
                }
                if (epochSeconds > 0) {
                    put(MediaStore.Images.Media.DATE_ADDED, epochSeconds)
                    put(MediaStore.Images.Media.DATE_MODIFIED, epochSeconds)
                }
            }

            val uri = context.contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
            if (uri != null) {
                context.contentResolver.openOutputStream(uri)?.use { output ->
                    context.assets.open("$imageDir/$filename").use { input ->
                        input.copyTo(output)
                    }
                }
                count++
                if (epochSeconds > 0) {
                    photoMetas.add(PhotoMeta(filename, epochSeconds))
                }
                Log.d(TAG, "Pushed image: $filename" +
                        if (epochSeconds > 0) " (date=$epochSeconds)" else "")
            }
        }
        return count
    }

    // -------------------------------------------------------------------------
    // Push Documents
    // -------------------------------------------------------------------------

    private fun pushDocuments(docDir: String, docFiles: Array<String>): Int {
        var count = 0
        for (filename in docFiles) {
            val mimeType = when {
                filename.endsWith(".pdf", true) -> "application/pdf"
                filename.endsWith(".txt", true) -> "text/plain"
                filename.endsWith(".docx", true) ->
                    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                else -> continue
            }

            val values = ContentValues().apply {
                put(MediaStore.Files.FileColumns.DISPLAY_NAME, filename)
                put(MediaStore.Files.FileColumns.MIME_TYPE, mimeType)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Files.FileColumns.RELATIVE_PATH, "Documents/RUVA")
                } else {
                    val dir = File(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOCUMENTS), "RUVA")
                    dir.mkdirs()
                    put(MediaStore.Files.FileColumns.DATA, File(dir, filename).absolutePath)
                }
            }

            val uri = context.contentResolver.insert(
                MediaStore.Files.getContentUri("external"), values)
            if (uri != null) {
                context.contentResolver.openOutputStream(uri)?.use { output ->
                    context.assets.open("$docDir/$filename").use { input ->
                        input.copyTo(output)
                    }
                }
                count++
                Log.d(TAG, "Pushed document: $filename")
            }
        }
        return count
    }

    // -------------------------------------------------------------------------
    // Media Scan
    // -------------------------------------------------------------------------

    private fun triggerMediaScan(
        imageDir: String, imageFiles: Array<String>,
        docDir: String, docFiles: Array<String>
    ) {
        val paths = mutableListOf<String>()
        val destImages = "${Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_PICTURES)}/RUVA"
        val destDocs = "${Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOCUMENTS)}/RUVA"

        for (f in imageFiles) {
            paths.add("$destImages/$f")
        }
        for (f in docFiles) {
            paths.add("$destDocs/$f")
        }

        if (paths.isNotEmpty()) {
            MediaScannerConnection.scanFile(context, paths.toTypedArray(), null, null)
        }
        Log.i(TAG, "Media scan triggered for ${paths.size} files")
    }

    // -------------------------------------------------------------------------
    // Fix Photo Dates in MediaStore
    // -------------------------------------------------------------------------

    private fun fixPhotoDatesInMediaStore() {
        var fixed = 0
        for (meta in photoMetas) {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DATE_ADDED, meta.epochSeconds)
                    put(MediaStore.Images.Media.DATE_MODIFIED, meta.epochSeconds)
                }
                val updated = context.contentResolver.update(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values,
                    "${MediaStore.Images.Media.DISPLAY_NAME} = ?",
                    arrayOf(meta.filename)
                )
                if (updated > 0) fixed++
            } catch (e: Exception) {
                Log.w(TAG, "Failed to fix date for ${meta.filename}: $e")
            }
        }
        Log.i(TAG, "Fixed $fixed/${photoMetas.size} photo dates in MediaStore")
    }

    // -------------------------------------------------------------------------
    // Calendar
    // -------------------------------------------------------------------------

    private fun findRuvaCalendarId(): Long? {
        val cursor = context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            arrayOf(CalendarContract.Calendars._ID),
            "${CalendarContract.Calendars.ACCOUNT_TYPE} = ? AND ${CalendarContract.Calendars.ACCOUNT_NAME} = ?",
            arrayOf("LOCAL", "RUVA"),
            null
        )
        cursor?.use {
            if (it.moveToFirst()) return it.getLong(0)
        }
        return null
    }

    private fun ensureRuvaCalendar(): Long {
        findRuvaCalendarId()?.let { return it }

        // Create a new local calendar
        val calUri = CalendarContract.Calendars.CONTENT_URI.buildUpon()
            .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_NAME, "RUVA")
            .appendQueryParameter(CalendarContract.Calendars.ACCOUNT_TYPE, "LOCAL")
            .build()

        val values = ContentValues().apply {
            put(CalendarContract.Calendars.ACCOUNT_NAME, "RUVA")
            put(CalendarContract.Calendars.ACCOUNT_TYPE, "LOCAL")
            put(CalendarContract.Calendars.NAME, "RUVA")
            put(CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, "RUVA")
            put(CalendarContract.Calendars.CALENDAR_COLOR, -14069085)
            put(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                CalendarContract.Calendars.CAL_ACCESS_OWNER)
            put(CalendarContract.Calendars.OWNER_ACCOUNT, "RUVA")
            put(CalendarContract.Calendars.VISIBLE, 1)
            put(CalendarContract.Calendars.SYNC_EVENTS, 1)
            put(CalendarContract.Calendars.CALENDAR_TIME_ZONE, TIMEZONE)
        }

        val result = context.contentResolver.insert(calUri, values)
        val newId = result?.let { ContentUris.parseId(it) }
            ?: throw RuntimeException("Failed to create RUVA calendar")

        Log.i(TAG, "Created RUVA calendar with ID: $newId")
        return newId
    }

    // -------------------------------------------------------------------------
    // Insert Single Events
    // -------------------------------------------------------------------------

    private fun insertEvents(jsonDir: String, jsonFiles: Array<String>, calId: Long): Int {
        var count = 0
        for (filename in jsonFiles.sorted()) {
            if (!filename.startsWith("event_") || filename.startsWith("recurrentEvent_")) continue

            try {
                val json = readJsonAsset("$jsonDir/$filename")
                val meta = json.getJSONObject("metadata")
                val label = meta.getString("label")
                val date = meta.getString("date")
                val startTime = meta.getString("start_time")
                val endTime = meta.getString("end_time")

                val startMs = parseDateToEpochMs(date, startTime)
                val endMs = parseDateToEpochMs(date, endTime)

                val values = ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, calId)
                    put(CalendarContract.Events.TITLE, label)
                    put(CalendarContract.Events.DTSTART, startMs)
                    put(CalendarContract.Events.DTEND, endMs)
                    put(CalendarContract.Events.EVENT_TIMEZONE, TIMEZONE)
                    put(CalendarContract.Events.HAS_ALARM, 0)
                }

                context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                count++
                Log.d(TAG, "Inserted event: $label ($date $startTime-$endTime)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to insert event from $filename: $e")
            }
        }
        return count
    }

    // -------------------------------------------------------------------------
    // Insert Recurrent Events
    // -------------------------------------------------------------------------

    private fun insertRecurrentEvents(jsonDir: String, jsonFiles: Array<String>, calId: Long): Int {
        var count = 0
        for (filename in jsonFiles.sorted()) {
            if (!filename.startsWith("recurrentEvent_")) continue

            try {
                val json = readJsonAsset("$jsonDir/$filename")
                val meta = json.getJSONObject("metadata")
                val label = meta.getString("label")
                val startTime = meta.getString("start_time")
                val endTime = meta.getString("end_time")
                val frequency = meta.getString("repeat_frequency")
                val on = meta.getString("on")

                // Use reference date as anchor
                val startMs = parseDateToEpochMs(REF_DATE, startTime)

                // Calculate RFC 5545 duration
                val durationRfc = calculateDurationRfc(startTime, endTime)

                // Build RRULE
                val rrule = buildRRule(frequency, on)

                val values = ContentValues().apply {
                    put(CalendarContract.Events.CALENDAR_ID, calId)
                    put(CalendarContract.Events.TITLE, label)
                    put(CalendarContract.Events.DTSTART, startMs)
                    put(CalendarContract.Events.DURATION, durationRfc)
                    put(CalendarContract.Events.RRULE, rrule)
                    put(CalendarContract.Events.EVENT_TIMEZONE, TIMEZONE)
                    put(CalendarContract.Events.HAS_ALARM, 0)
                }

                context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                count++
                Log.d(TAG, "Inserted recurrent event: $label ($rrule, $startTime-$endTime)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to insert recurrent event from $filename: $e")
            }
        }
        return count
    }

    // -------------------------------------------------------------------------
    // Insert Contacts
    // -------------------------------------------------------------------------

    private fun insertContacts(
        jsonDir: String,
        jsonFiles: Array<String>,
        contactMap: MutableMap<String, Pair<String, String>>
    ): Int {
        var count = 0
        for (filename in jsonFiles.sorted()) {
            if (!filename.startsWith("contact_")) continue

            try {
                val json = readJsonAsset("$jsonDir/$filename")
                val contactId = json.getString("contact")
                val meta = json.getJSONObject("metadata")
                val name = meta.getString("name")
                val phone = meta.getString("telephone_number")

                // Store in lookup map for call log resolution
                contactMap[contactId] = Pair(phone, name)

                // Step 1: Insert raw contact
                val rawContactValues = ContentValues().apply {
                    put(ContactsContract.RawContacts.ACCOUNT_TYPE, "LOCAL")
                    put(ContactsContract.RawContacts.ACCOUNT_NAME, "RUVA")
                }
                val rawContactUri = context.contentResolver.insert(
                    ContactsContract.RawContacts.CONTENT_URI, rawContactValues)
                val rawContactId = rawContactUri?.let { ContentUris.parseId(it) } ?: continue

                // Step 2: Insert display name
                val nameValues = ContentValues().apply {
                    put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                    put(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE)
                    put(ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME, name)
                }
                context.contentResolver.insert(ContactsContract.Data.CONTENT_URI, nameValues)

                // Step 3: Insert phone number
                val phoneValues = ContentValues().apply {
                    put(ContactsContract.Data.RAW_CONTACT_ID, rawContactId)
                    put(ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)
                    put(ContactsContract.CommonDataKinds.Phone.NUMBER, phone)
                    put(ContactsContract.CommonDataKinds.Phone.TYPE,
                        ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE)
                }
                context.contentResolver.insert(ContactsContract.Data.CONTENT_URI, phoneValues)

                count++
                Log.d(TAG, "Inserted contact: $name ($phone)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to insert contact from $filename: $e")
            }
        }
        return count
    }

    // -------------------------------------------------------------------------
    // Insert Call Log
    // -------------------------------------------------------------------------

    private fun insertCallLog(
        jsonDir: String,
        jsonFiles: Array<String>,
        contactMap: Map<String, Pair<String, String>>
    ): Int {
        var count = 0
        for (filename in jsonFiles.sorted()) {
            if (!filename.startsWith("phoneCall_")) continue

            try {
                val json = readJsonAsset("$jsonDir/$filename")
                val meta = json.getJSONObject("metadata")
                val date = meta.getString("date")
                val startTime = meta.getString("start_time")
                val durationStr = meta.getString("duration")
                val direction = meta.getString("call_direction")
                val withContact = meta.getString("with_contact")

                val startMs = parseDateWithSecondsToEpochMs(date, startTime)
                val durationSec = parseDuration(durationStr)

                // Map direction to Android CallLog type
                val callType = when (direction) {
                    "incoming" -> CallLog.Calls.INCOMING_TYPE
                    "outgoing" -> CallLog.Calls.OUTGOING_TYPE
                    else -> CallLog.Calls.MISSED_TYPE
                }

                // Resolve contact
                val contact = contactMap[withContact]
                val phone = contact?.first ?: "unknown"
                val contactName = contact?.second ?: withContact

                val values = ContentValues().apply {
                    put(CallLog.Calls.NUMBER, phone)
                    put(CallLog.Calls.DATE, startMs)
                    put(CallLog.Calls.DURATION, durationSec.toLong())
                    put(CallLog.Calls.TYPE, callType)
                    put(CallLog.Calls.CACHED_NAME, contactName)
                    put(CallLog.Calls.NEW, 0)
                }

                context.contentResolver.insert(CallLog.Calls.CONTENT_URI, values)
                count++
                Log.d(TAG, "Inserted $direction call with $contactName ($date $startTime, ${durationSec}s)")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to insert call from $filename: $e")
            }
        }
        return count
    }

    // =========================================================================
    // Helper Methods
    // =========================================================================

    private fun logPermissionStatus() {
        val perms = mapOf(
            "WRITE_CALENDAR" to Manifest.permission.WRITE_CALENDAR,
            "WRITE_CONTACTS" to Manifest.permission.WRITE_CONTACTS,
            "WRITE_CALL_LOG" to Manifest.permission.WRITE_CALL_LOG,
            "READ_CALENDAR" to Manifest.permission.READ_CALENDAR,
            "READ_CONTACTS" to Manifest.permission.READ_CONTACTS,
            "READ_CALL_LOG" to Manifest.permission.READ_CALL_LOG,
        )
        for ((name, perm) in perms) {
            val granted = ContextCompat.checkSelfPermission(context, perm) ==
                    PackageManager.PERMISSION_GRANTED
            Log.i(TAG, "Permission $name: ${if (granted) "GRANTED" else "DENIED"}")
        }
    }

    private fun findRuvaRawContactIds(): List<Long> {
        val ids = mutableListOf<Long>()
        val cursor = context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(ContactsContract.RawContacts._ID),
            "${ContactsContract.RawContacts.ACCOUNT_NAME} = ? AND ${ContactsContract.RawContacts.ACCOUNT_TYPE} = ?",
            arrayOf("RUVA", "LOCAL"),
            null
        )
        cursor?.use {
            while (it.moveToNext()) {
                ids.add(it.getLong(0))
            }
        }
        return ids
    }

    /**
     * Map an image filename to its corresponding photo metadata JSON filename.
     * e.g. "photo_20250601.JPG" -> "photo_20250601.txt"
     *      "photo_photo_20250615(2).JPG" -> "photo_20250615(2).txt"
     */
    private fun findPhotoJsonName(imageFilename: String): String {
        var stem = imageFilename.substringBeforeLast(".")
        if (stem.startsWith("photo_photo_")) {
            stem = "photo_" + stem.removePrefix("photo_photo_")
        }
        return "$stem.txt"
    }

    private fun readJsonAsset(assetPath: String): JSONObject {
        var text = context.assets.open(assetPath).bufferedReader().use { it.readText() }

        // 1. Replace Unicode smart quotes with standard ASCII quotes
        text = text
            .replace('\u201c', '"').replace('\u201d', '"')
            .replace('\u2018', '\'').replace('\u2019', '\'')

        // 2. Fix unquoted values (e.g. "location": Florida Street , Rome , Italy)
        //    Matches key-value lines where the value is not properly quoted.
        val unquotedValueRegex = Regex(
            """^(\s*"[^"]+"\s*:\s*)([^"{}'\[\]0-9tfn\s][^\n]*)$""",
            RegexOption.MULTILINE
        )
        text = unquotedValueRegex.replace(text) { match ->
            val prefix = match.groupValues[1]
            var rawValue = match.groupValues[2].trimEnd()
            val hasComma = rawValue.endsWith(",")
            if (hasComma) rawValue = rawValue.dropLast(1).trimEnd()
            // Escape embedded double quotes
            rawValue = rawValue.replace("\"", "\\\"")
            "$prefix\"$rawValue\"${if (hasComma) "," else ""}"
        }

        // 3. Fix missing closing braces (some files are malformed)
        val openBraces = text.count { it == '{' }
        val closeBraces = text.count { it == '}' }
        if (openBraces > closeBraces) {
            text += "}".repeat(openBraces - closeBraces)
        }

        return JSONObject(text)
    }

    /**
     * Parse "dd-MMM-yyyy" + "HH:mm" to epoch milliseconds.
     * e.g. "14-Jun-2025" + "12:00" -> epoch millis
     */
    private fun parseDateToEpochMs(dateStr: String, timeStr: String): Long {
        val sdf = SimpleDateFormat("dd-MMM-yyyy HH:mm", Locale.ENGLISH)
        sdf.timeZone = TimeZone.getTimeZone(TIMEZONE)
        return sdf.parse("$dateStr $timeStr")?.time ?: 0L
    }

    /**
     * Parse "dd-MMM-yyyy" + "HH:mm" to epoch seconds.
     */
    private fun parseDateToEpochSeconds(dateStr: String, timeStr: String): Long {
        return parseDateToEpochMs(dateStr, timeStr) / 1000
    }

    /**
     * Parse "dd-MMM-yyyy" + "HH:mm:ss" to epoch milliseconds (for call log).
     */
    private fun parseDateWithSecondsToEpochMs(dateStr: String, timeStr: String): Long {
        val sdf = SimpleDateFormat("dd-MMM-yyyy HH:mm:ss", Locale.ENGLISH)
        sdf.timeZone = TimeZone.getTimeZone(TIMEZONE)
        return sdf.parse("$dateStr $timeStr")?.time ?: 0L
    }

    /**
     * Parse duration "Xh, Ymin, Zsec" to seconds.
     */
    private fun parseDuration(durationStr: String): Int {
        val regex = Regex("""(\d+)h,\s*(\d+)min,\s*(\d+)sec""")
        val match = regex.find(durationStr) ?: return 0
        return match.groupValues[1].toInt() * 3600 +
                match.groupValues[2].toInt() * 60 +
                match.groupValues[3].toInt()
    }

    /**
     * Calculate RFC 5545 duration between two HH:mm times.
     * Handles times crossing midnight.
     */
    private fun calculateDurationRfc(startTime: String, endTime: String): String {
        val (startH, startM) = startTime.split(":").map { it.toInt() }
        val (endH, endM) = endTime.split(":").map { it.toInt() }
        val startMins = startH * 60 + startM
        val endMins = endH * 60 + endM
        val durationMins = if (endMins <= startMins) {
            (1440 - startMins) + endMins // crosses midnight
        } else {
            endMins - startMins
        }
        return "PT${durationMins / 60}H${durationMins % 60}M"
    }

    /**
     * Build an RFC 5545 RRULE from frequency and "on" field.
     */
    private fun buildRRule(frequency: String, on: String): String {
        val freqUpper = frequency.uppercase()
        return when (freqUpper) {
            "WEEKLY" -> {
                val dayMapping = mapOf(
                    "Monday" to "MO", "Tuesday" to "TU", "Wednesday" to "WE",
                    "Thursday" to "TH", "Friday" to "FR", "Saturday" to "SA", "Sunday" to "SU"
                )
                val byDay = on.split(",").map { it.trim() }
                    .mapNotNull { dayMapping[it] }
                    .joinToString(",")
                "FREQ=WEEKLY;BYDAY=$byDay"
            }
            "YEARLY" -> {
                // "on": "11-Sep" -> BYMONTH=9;BYMONTHDAY=11
                try {
                    val sdf = SimpleDateFormat("dd-MMM", Locale.ENGLISH)
                    val cal = Calendar.getInstance()
                    cal.time = sdf.parse(on) ?: return "FREQ=YEARLY"
                    "FREQ=YEARLY;BYMONTH=${cal.get(Calendar.MONTH) + 1};BYMONTHDAY=${cal.get(Calendar.DAY_OF_MONTH)}"
                } catch (e: Exception) {
                    "FREQ=YEARLY"
                }
            }
            else -> "FREQ=$freqUpper"
        }
    }
}
