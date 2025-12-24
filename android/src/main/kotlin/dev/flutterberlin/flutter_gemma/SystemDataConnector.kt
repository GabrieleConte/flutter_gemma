package dev.flutterberlin.flutter_gemma

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.util.*

/**
 * Android System Data Connector for accessing user's contacts and calendar
 */
class SystemDataConnector(
    private val context: Context,
    private var activity: Activity? = null
) {
    companion object {
        const val PERMISSION_REQUEST_CONTACTS = 1001
        const val PERMISSION_REQUEST_CALENDAR = 1002
        const val PERMISSION_REQUEST_NOTIFICATIONS = 1003
        const val PERMISSION_REQUEST_PHOTOS = 1004
        const val PERMISSION_REQUEST_CALL_LOG = 1005
        private const val TAG = "SystemDataConnector"
    }

    // Pending permission callbacks
    private var pendingContactsCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingCalendarCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingNotificationsCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingPhotosCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingCallLogCallback: ((PermissionStatus) -> Unit)? = null

    fun setActivity(activity: Activity?) {
        this.activity = activity
    }

    // Handle permission result from Activity
    fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        Log.d(TAG, "onRequestPermissionsResult: requestCode=$requestCode, results=${grantResults.toList()}")
        
        return when (requestCode) {
            PERMISSION_REQUEST_CONTACTS -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Contacts permission result: $status")
                pendingContactsCallback?.invoke(status)
                pendingContactsCallback = null
                true
            }
            PERMISSION_REQUEST_CALENDAR -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Calendar permission result: $status")
                pendingCalendarCallback?.invoke(status)
                pendingCalendarCallback = null
                true
            }
            PERMISSION_REQUEST_NOTIFICATIONS -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Notifications permission result: $status")
                pendingNotificationsCallback?.invoke(status)
                pendingNotificationsCallback = null
                true
            }
            PERMISSION_REQUEST_PHOTOS -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Photos permission result: $status")
                pendingPhotosCallback?.invoke(status)
                pendingPhotosCallback = null
                true
            }
            PERMISSION_REQUEST_CALL_LOG -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Call log permission result: $status")
                pendingCallLogCallback?.invoke(status)
                pendingCallLogCallback = null
                true
            }
            else -> false
        }
    }

    // MARK: - Permission Methods

    fun checkPermission(type: PermissionType): PermissionStatus {
        val status = when (type) {
            PermissionType.CONTACTS -> checkContactsPermission()
            PermissionType.CALENDAR -> checkCalendarPermission()
            PermissionType.NOTIFICATIONS -> checkNotificationsPermission()
            PermissionType.PHOTOS -> checkPhotosPermission()
            PermissionType.CALL_LOG -> checkCallLogPermission()
        }
        Log.d(TAG, "checkPermission($type) = $status")
        return status
    }

    fun requestPermission(type: PermissionType, callback: (PermissionStatus) -> Unit) {
        val activity = this.activity ?: run {
            Log.w(TAG, "requestPermission: No activity attached!")
            callback(PermissionStatus.DENIED)
            return
        }

        when (type) {
            PermissionType.CONTACTS -> requestContactsPermission(activity, callback)
            PermissionType.CALENDAR -> requestCalendarPermission(activity, callback)
            PermissionType.NOTIFICATIONS -> requestNotificationsPermission(activity, callback)
            PermissionType.PHOTOS -> requestPhotosPermission(activity, callback)
            PermissionType.CALL_LOG -> requestCallLogPermission(activity, callback)
        }
    }

    private fun checkContactsPermission(): PermissionStatus {
        return when (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS)) {
            PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
            PackageManager.PERMISSION_DENIED -> {
                // Check if user has previously denied
                if (activity != null && 
                    ActivityCompat.shouldShowRequestPermissionRationale(activity!!, Manifest.permission.READ_CONTACTS)) {
                    PermissionStatus.DENIED
                } else {
                    PermissionStatus.NOT_DETERMINED
                }
            }
            else -> PermissionStatus.NOT_DETERMINED
        }
    }

    private fun checkCalendarPermission(): PermissionStatus {
        return when (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR)) {
            PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
            PackageManager.PERMISSION_DENIED -> {
                if (activity != null &&
                    ActivityCompat.shouldShowRequestPermissionRationale(activity!!, Manifest.permission.READ_CALENDAR)) {
                    PermissionStatus.DENIED
                } else {
                    PermissionStatus.NOT_DETERMINED
                }
            }
            else -> PermissionStatus.NOT_DETERMINED
        }
    }

    private fun requestContactsPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        Log.d(TAG, "requestContactsPermission called")
        
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) 
            == PackageManager.PERMISSION_GRANTED) {
            Log.d(TAG, "Contacts permission already granted")
            callback(PermissionStatus.GRANTED)
            return
        }

        // Store callback for when permission result arrives
        pendingContactsCallback = callback
        
        Log.d(TAG, "Requesting contacts permission from system")
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.READ_CONTACTS),
            PERMISSION_REQUEST_CONTACTS
        )
        // Don't call callback here - wait for onRequestPermissionsResult
    }

    private fun requestCalendarPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        Log.d(TAG, "requestCalendarPermission called")
        
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) 
            == PackageManager.PERMISSION_GRANTED) {
            Log.d(TAG, "Calendar permission already granted")
            callback(PermissionStatus.GRANTED)
            return
        }

        // Store callback for when permission result arrives
        pendingCalendarCallback = callback
        
        Log.d(TAG, "Requesting calendar permission from system")
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.READ_CALENDAR),
            PERMISSION_REQUEST_CALENDAR
        )
        // Don't call callback here - wait for onRequestPermissionsResult
    }

    private fun checkNotificationsPermission(): PermissionStatus {
        // For Android 13+ (API 33+), POST_NOTIFICATIONS permission is required
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            when (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)) {
                PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
                PackageManager.PERMISSION_DENIED -> {
                    if (activity != null &&
                        ActivityCompat.shouldShowRequestPermissionRationale(activity!!, Manifest.permission.POST_NOTIFICATIONS)) {
                        PermissionStatus.DENIED
                    } else {
                        PermissionStatus.NOT_DETERMINED
                    }
                }
                else -> PermissionStatus.NOT_DETERMINED
            }
        } else {
            // Below Android 13, notifications are always allowed
            PermissionStatus.GRANTED
        }
    }

    private fun requestNotificationsPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        Log.d(TAG, "requestNotificationsPermission called")
        
        // For Android 13+ (API 33+), request POST_NOTIFICATIONS permission
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) 
                == PackageManager.PERMISSION_GRANTED) {
                Log.d(TAG, "Notifications permission already granted")
                callback(PermissionStatus.GRANTED)
                return
            }

            // Store callback for when permission result arrives
            pendingNotificationsCallback = callback
            
            Log.d(TAG, "Requesting notifications permission from system")
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                PERMISSION_REQUEST_NOTIFICATIONS
            )
        } else {
            // Below Android 13, notifications are always allowed
            callback(PermissionStatus.GRANTED)
        }
    }

    // MARK: - Contacts

    fun fetchContacts(sinceTimestamp: Long?, limit: Long?): List<ContactResult> {
        Log.d(TAG, "fetchContacts called, sinceTimestamp=$sinceTimestamp, limit=$limit")
        
        val permStatus = checkContactsPermission()
        if (permStatus != PermissionStatus.GRANTED) {
            Log.e(TAG, "fetchContacts: Permission not granted (status=$permStatus)")
            throw SecurityException("Contacts permission not granted")
        }

        val contentResolver: ContentResolver = context.contentResolver
        val results = mutableListOf<ContactResult>()
        var count = 0
        val maxCount = limit?.toInt() ?: Int.MAX_VALUE

        val projection = arrayOf(
            ContactsContract.Contacts._ID,
            ContactsContract.Contacts.DISPLAY_NAME_PRIMARY,
            ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP
        )

        val selection = if (sinceTimestamp != null) {
            "${ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP} > ?"
        } else null

        val selectionArgs = if (sinceTimestamp != null) {
            arrayOf(sinceTimestamp.toString())
        } else null

        Log.d(TAG, "Querying contacts, selection=$selection")
        
        val cursor: Cursor? = contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} ASC"
        )

        Log.d(TAG, "Cursor returned: ${cursor?.count ?: 0} contacts")

        cursor?.use {
            val idIndex = it.getColumnIndex(ContactsContract.Contacts._ID)
            val nameIndex = it.getColumnIndex(ContactsContract.Contacts.DISPLAY_NAME_PRIMARY)
            val lastUpdatedIndex = it.getColumnIndex(ContactsContract.Contacts.CONTACT_LAST_UPDATED_TIMESTAMP)

            while (it.moveToNext() && count < maxCount) {
                val contactId = it.getString(idIndex)
                val displayName = it.getString(nameIndex) ?: ""
                val lastUpdated = it.getLong(lastUpdatedIndex)
                
                Log.d(TAG, "Found contact: $displayName (id=$contactId)")

                // Parse display name into given/family
                val nameParts = displayName.split(" ", limit = 2)
                val givenName = nameParts.firstOrNull()
                val familyName = if (nameParts.size > 1) nameParts[1] else null

                // Get organization info
                val (organizationName, jobTitle) = getOrganizationInfo(contentResolver, contactId)

                // Get email addresses
                val emailAddresses = getEmailAddresses(contentResolver, contactId)

                // Get phone numbers
                val phoneNumbers = getPhoneNumbers(contentResolver, contactId)

                results.add(ContactResult(
                    id = contactId,
                    givenName = givenName,
                    familyName = familyName,
                    organizationName = organizationName,
                    jobTitle = jobTitle,
                    emailAddresses = emailAddresses,
                    phoneNumbers = phoneNumbers,
                    lastModified = lastUpdated
                ))

                count++
            }
        }

        Log.d(TAG, "fetchContacts completed, returning ${results.size} contacts")
        return results
    }

    private fun getOrganizationInfo(contentResolver: ContentResolver, contactId: String): Pair<String?, String?> {
        var organizationName: String? = null
        var jobTitle: String? = null

        val cursor: Cursor? = contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(
                ContactsContract.CommonDataKinds.Organization.COMPANY,
                ContactsContract.CommonDataKinds.Organization.TITLE
            ),
            "${ContactsContract.Data.CONTACT_ID} = ? AND ${ContactsContract.Data.MIMETYPE} = ?",
            arrayOf(contactId, ContactsContract.CommonDataKinds.Organization.CONTENT_ITEM_TYPE),
            null
        )

        cursor?.use {
            if (it.moveToFirst()) {
                organizationName = it.getString(0)
                jobTitle = it.getString(1)
            }
        }

        return Pair(organizationName, jobTitle)
    }

    private fun getEmailAddresses(contentResolver: ContentResolver, contactId: String): List<String?> {
        val emails = mutableListOf<String?>()

        val cursor: Cursor? = contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
            arrayOf(contactId),
            null
        )

        cursor?.use {
            while (it.moveToNext()) {
                emails.add(it.getString(0))
            }
        }

        return emails
    }

    private fun getPhoneNumbers(contentResolver: ContentResolver, contactId: String): List<String?> {
        val phones = mutableListOf<String?>()

        val cursor: Cursor? = contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(contactId),
            null
        )

        cursor?.use {
            while (it.moveToNext()) {
                phones.add(it.getString(0))
            }
        }

        return phones
    }

    // MARK: - Calendar

    fun fetchCalendarEvents(
        sinceTimestamp: Long?,
        startDate: Long?,
        endDate: Long?,
        limit: Long?
    ): List<CalendarEventResult> {
        if (checkCalendarPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Calendar permission not granted")
        }

        val contentResolver: ContentResolver = context.contentResolver
        val results = mutableListOf<CalendarEventResult>()
        var count = 0
        val maxCount = limit?.toInt() ?: Int.MAX_VALUE

        // Determine date range
        val calendar = Calendar.getInstance()
        val startMillis = when {
            startDate != null -> startDate * 1000
            sinceTimestamp != null -> sinceTimestamp * 1000
            else -> {
                calendar.add(Calendar.YEAR, -1)
                calendar.timeInMillis
            }
        }

        val endMillis = if (endDate != null) {
            endDate * 1000
        } else {
            Calendar.getInstance().apply { add(Calendar.YEAR, 1) }.timeInMillis
        }

        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DESCRIPTION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.LAST_DATE
        )

        val selection = "${CalendarContract.Events.DTSTART} >= ? AND ${CalendarContract.Events.DTSTART} <= ?"
        val selectionArgs = arrayOf(startMillis.toString(), endMillis.toString())

        val cursor: Cursor? = contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            "${CalendarContract.Events.DTSTART} ASC"
        )

        cursor?.use {
            val idIndex = it.getColumnIndex(CalendarContract.Events._ID)
            val titleIndex = it.getColumnIndex(CalendarContract.Events.TITLE)
            val locationIndex = it.getColumnIndex(CalendarContract.Events.EVENT_LOCATION)
            val descriptionIndex = it.getColumnIndex(CalendarContract.Events.DESCRIPTION)
            val startIndex = it.getColumnIndex(CalendarContract.Events.DTSTART)
            val endIndex = it.getColumnIndex(CalendarContract.Events.DTEND)
            val lastDateIndex = it.getColumnIndex(CalendarContract.Events.LAST_DATE)

            while (it.moveToNext() && count < maxCount) {
                val eventId = it.getString(idIndex)
                val title = it.getString(titleIndex) ?: "Untitled Event"
                val location = it.getString(locationIndex)
                val description = it.getString(descriptionIndex)
                val eventStart = it.getLong(startIndex) / 1000  // Convert to seconds
                val eventEnd = (it.getLong(endIndex) / 1000).let { end ->
                    if (end == 0L) eventStart + 3600 else end  // Default 1 hour duration
                }
                val lastDate = it.getLong(lastDateIndex) / 1000

                // Get attendees for this event
                val attendees = getEventAttendees(contentResolver, eventId)

                results.add(CalendarEventResult(
                    id = eventId,
                    title = title,
                    location = location,
                    notes = description,
                    startDate = eventStart,
                    endDate = eventEnd,
                    attendees = attendees,
                    lastModified = if (lastDate > 0) lastDate else eventStart
                ))

                count++
            }
        }

        return results
    }

    private fun getEventAttendees(contentResolver: ContentResolver, eventId: String): List<String?> {
        val attendees = mutableListOf<String?>()

        val cursor: Cursor? = contentResolver.query(
            CalendarContract.Attendees.CONTENT_URI,
            arrayOf(
                CalendarContract.Attendees.ATTENDEE_NAME,
                CalendarContract.Attendees.ATTENDEE_EMAIL
            ),
            "${CalendarContract.Attendees.EVENT_ID} = ?",
            arrayOf(eventId),
            null
        )

        cursor?.use {
            while (it.moveToNext()) {
                val name = it.getString(0)
                val email = it.getString(1)
                attendees.add(name ?: email)
            }
        }

        return attendees
    }

    // MARK: - Photos Permission

    private fun checkPhotosPermission(): PermissionStatus {
        // Android 13+ uses READ_MEDIA_IMAGES, older versions use READ_EXTERNAL_STORAGE
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        
        return when (ContextCompat.checkSelfPermission(context, permission)) {
            PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
            PackageManager.PERMISSION_DENIED -> {
                if (activity != null && ActivityCompat.shouldShowRequestPermissionRationale(activity!!, permission)) {
                    PermissionStatus.DENIED
                } else {
                    PermissionStatus.NOT_DETERMINED
                }
            }
            else -> PermissionStatus.NOT_DETERMINED
        }
    }

    private fun requestPhotosPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            callback(PermissionStatus.GRANTED)
            return
        }
        
        pendingPhotosCallback = callback
        ActivityCompat.requestPermissions(activity, arrayOf(permission), PERMISSION_REQUEST_PHOTOS)
    }

    // MARK: - Call Log Permission

    private fun checkCallLogPermission(): PermissionStatus {
        return when (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG)) {
            PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
            PackageManager.PERMISSION_DENIED -> {
                if (activity != null && 
                    ActivityCompat.shouldShowRequestPermissionRationale(activity!!, Manifest.permission.READ_CALL_LOG)) {
                    PermissionStatus.DENIED
                } else {
                    PermissionStatus.NOT_DETERMINED
                }
            }
            else -> PermissionStatus.NOT_DETERMINED
        }
    }

    private fun requestCallLogPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) 
            == PackageManager.PERMISSION_GRANTED) {
            callback(PermissionStatus.GRANTED)
            return
        }
        
        pendingCallLogCallback = callback
        ActivityCompat.requestPermissions(
            activity, 
            arrayOf(Manifest.permission.READ_CALL_LOG), 
            PERMISSION_REQUEST_CALL_LOG
        )
    }

    // MARK: - Photos

    fun fetchPhotos(sinceTimestamp: Long?, limit: Long?, includeLocation: Boolean?): List<PhotoResult> {
        Log.d(TAG, "fetchPhotos called, sinceTimestamp=$sinceTimestamp, limit=$limit")
        
        if (checkPhotosPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Photos permission not granted")
        }

        val contentResolver: ContentResolver = context.contentResolver
        val results = mutableListOf<PhotoResult>()
        var count = 0
        val maxCount = limit?.toInt() ?: 500 // Default limit to prevent OOM

        val projection = mutableListOf(
            android.provider.MediaStore.Images.Media._ID,
            android.provider.MediaStore.Images.Media.DISPLAY_NAME,
            android.provider.MediaStore.Images.Media.WIDTH,
            android.provider.MediaStore.Images.Media.HEIGHT,
            android.provider.MediaStore.Images.Media.DATE_ADDED,
            android.provider.MediaStore.Images.Media.DATE_MODIFIED,
            android.provider.MediaStore.Images.Media.MIME_TYPE,
            android.provider.MediaStore.Images.Media.SIZE
        )
        
        // Add location columns if requested and available (API 29+)
        val hasLocationAccess = includeLocation == true && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
        if (hasLocationAccess) {
            // Note: Need ACCESS_MEDIA_LOCATION permission for actual lat/lng on API 29+
        }

        val selection = if (sinceTimestamp != null) {
            "${android.provider.MediaStore.Images.Media.DATE_ADDED} > ?"
        } else null

        val selectionArgs = if (sinceTimestamp != null) {
            arrayOf((sinceTimestamp / 1000).toString()) // MediaStore uses seconds
        } else null

        val cursor: Cursor? = contentResolver.query(
            android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection.toTypedArray(),
            selection,
            selectionArgs,
            "${android.provider.MediaStore.Images.Media.DATE_ADDED} DESC"
        )

        Log.d(TAG, "Photos cursor returned: ${cursor?.count ?: 0} photos")

        cursor?.use {
            val idIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media._ID)
            val nameIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.DISPLAY_NAME)
            val widthIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.WIDTH)
            val heightIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.HEIGHT)
            val dateAddedIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.DATE_ADDED)
            val dateModifiedIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.DATE_MODIFIED)
            val mimeTypeIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.MIME_TYPE)
            val sizeIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Images.Media.SIZE)

            while (it.moveToNext() && count < maxCount) {
                try {
                    val photoId = it.getLong(idIndex)
                    val filename = it.getString(nameIndex)
                    val width = it.getInt(widthIndex)
                    val height = it.getInt(heightIndex)
                    val dateAdded = it.getLong(dateAddedIndex) * 1000 // Convert to milliseconds
                    val dateModified = it.getLong(dateModifiedIndex) * 1000
                    val mimeType = it.getString(mimeTypeIndex)
                    val fileSize = it.getLong(sizeIndex)

                    // Try to get location from EXIF (requires additional processing)
                    var latitude: Double? = null
                    var longitude: Double? = null
                    
                    if (hasLocationAccess) {
                        try {
                            val photoUri = android.content.ContentUris.withAppendedId(
                                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                photoId
                            )
                            // Location extraction would require ExifInterface or MediaStore API
                            // This is simplified - full implementation needs ACCESS_MEDIA_LOCATION
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to get location for photo $photoId: ${e.message}")
                        }
                    }

                    results.add(PhotoResult(
                        id = photoId.toString(),
                        filename = filename,
                        width = width.toLong(),
                        height = height.toLong(),
                        creationDate = dateAdded,
                        modificationDate = dateModified,
                        latitude = latitude,
                        longitude = longitude,
                        locationName = null,
                        duration = null, // Only for videos
                        mediaType = "image",
                        mimeType = mimeType,
                        fileSize = fileSize,
                        thumbnailBytes = null // Can be loaded on demand
                    ))

                    count++
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing photo: ${e.message}")
                }
            }
        }

        Log.d(TAG, "fetchPhotos completed, returning ${results.size} photos")
        return results
    }

    // MARK: - Call Log

    fun fetchCallLog(sinceTimestamp: Long?, limit: Long?): List<CallLogResult> {
        Log.d(TAG, "fetchCallLog called, sinceTimestamp=$sinceTimestamp, limit=$limit")
        
        if (checkCallLogPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Call log permission not granted")
        }

        val contentResolver: ContentResolver = context.contentResolver
        val results = mutableListOf<CallLogResult>()
        var count = 0
        val maxCount = limit?.toInt() ?: 500

        val projection = arrayOf(
            android.provider.CallLog.Calls._ID,
            android.provider.CallLog.Calls.CACHED_NAME,
            android.provider.CallLog.Calls.NUMBER,
            android.provider.CallLog.Calls.TYPE,
            android.provider.CallLog.Calls.DATE,
            android.provider.CallLog.Calls.DURATION,
            android.provider.CallLog.Calls.IS_READ,
            android.provider.CallLog.Calls.GEOCODED_LOCATION
        )

        val selection = if (sinceTimestamp != null) {
            "${android.provider.CallLog.Calls.DATE} > ?"
        } else null

        val selectionArgs = if (sinceTimestamp != null) {
            arrayOf(sinceTimestamp.toString())
        } else null

        val cursor: Cursor? = contentResolver.query(
            android.provider.CallLog.Calls.CONTENT_URI,
            projection,
            selection,
            selectionArgs,
            "${android.provider.CallLog.Calls.DATE} DESC"
        )

        Log.d(TAG, "Call log cursor returned: ${cursor?.count ?: 0} calls")

        cursor?.use {
            val idIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls._ID)
            val nameIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.CACHED_NAME)
            val numberIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.NUMBER)
            val typeIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.TYPE)
            val dateIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.DATE)
            val durationIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.DURATION)
            val isReadIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.IS_READ)
            val locationIndex = it.getColumnIndexOrThrow(android.provider.CallLog.Calls.GEOCODED_LOCATION)

            while (it.moveToNext() && count < maxCount) {
                try {
                    val callId = it.getLong(idIndex)
                    val name = it.getString(nameIndex)
                    val number = it.getString(numberIndex) ?: ""
                    val type = it.getInt(typeIndex)
                    val date = it.getLong(dateIndex)
                    val duration = it.getLong(durationIndex)
                    val isRead = it.getInt(isReadIndex) == 1
                    val location = it.getString(locationIndex)

                    val callType = when (type) {
                        android.provider.CallLog.Calls.INCOMING_TYPE -> CallType.INCOMING
                        android.provider.CallLog.Calls.OUTGOING_TYPE -> CallType.OUTGOING
                        android.provider.CallLog.Calls.MISSED_TYPE -> CallType.MISSED
                        android.provider.CallLog.Calls.REJECTED_TYPE -> CallType.REJECTED
                        android.provider.CallLog.Calls.BLOCKED_TYPE -> CallType.BLOCKED
                        android.provider.CallLog.Calls.VOICEMAIL_TYPE -> CallType.VOICEMAIL
                        else -> CallType.UNKNOWN
                    }

                    results.add(CallLogResult(
                        id = callId.toString(),
                        name = name,
                        phoneNumber = number,
                        callType = callType,
                        timestamp = date,
                        duration = duration,
                        isRead = isRead,
                        geocodedLocation = location
                    ))

                    count++
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing call: ${e.message}")
                }
            }
        }

        Log.d(TAG, "fetchCallLog completed, returning ${results.size} calls")
        return results
    }
}
