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
        const val PERMISSION_REQUEST_FILES = 1006
        private const val TAG = "SystemDataConnector"
    }

    // Pending permission callbacks
    private var pendingContactsCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingCalendarCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingNotificationsCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingPhotosCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingCallLogCallback: ((PermissionStatus) -> Unit)? = null
    private var pendingFilesCallback: ((PermissionStatus) -> Unit)? = null

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
            PERMISSION_REQUEST_FILES -> {
                val status = if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                    PermissionStatus.GRANTED
                } else {
                    PermissionStatus.DENIED
                }
                Log.d(TAG, "Files permission result: $status")
                pendingFilesCallback?.invoke(status)
                pendingFilesCallback = null
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
            PermissionType.FILES -> checkFilesPermission()
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
            PermissionType.FILES -> requestFilesPermission(activity, callback)
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

    // MARK: - Files Permission

    private fun checkFilesPermission(): PermissionStatus {
        // On Android 13+ (API 33), READ_EXTERNAL_STORAGE no longer grants access to most files
        // Instead, we use scoped storage which grants access to app-specific directories automatically
        // For user documents, we'll scan app's external files directory
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // On Android 13+, we use scoped storage - no permission needed for app directories
            // Grant access automatically since we'll only access app-specific or Downloads directory
            PermissionStatus.GRANTED
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Android 11-12: Scoped storage with limited MediaStore access
            PermissionStatus.GRANTED
        } else {
            // Android 10 and below: Need READ_EXTERNAL_STORAGE
            when (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE)) {
                PackageManager.PERMISSION_GRANTED -> PermissionStatus.GRANTED
                PackageManager.PERMISSION_DENIED -> {
                    if (activity != null && 
                        ActivityCompat.shouldShowRequestPermissionRationale(activity!!, Manifest.permission.READ_EXTERNAL_STORAGE)) {
                        PermissionStatus.DENIED
                    } else {
                        PermissionStatus.NOT_DETERMINED
                    }
                }
                else -> PermissionStatus.NOT_DETERMINED
            }
        }
    }

    private fun requestFilesPermission(activity: Activity, callback: (PermissionStatus) -> Unit) {
        // On Android 13+, we don't need runtime permission for scoped storage
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Log.d(TAG, "Android 13+: Using scoped storage, no permission needed")
            callback(PermissionStatus.GRANTED)
            return
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Log.d(TAG, "Android 11-12: Using scoped storage, no permission needed")
            callback(PermissionStatus.GRANTED)
            return
        }
        
        // Android 10 and below
        val permission = Manifest.permission.READ_EXTERNAL_STORAGE
        
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            callback(PermissionStatus.GRANTED)
            return
        }
        
        pendingFilesCallback = callback
        ActivityCompat.requestPermissions(
            activity, 
            arrayOf(permission), 
            PERMISSION_REQUEST_FILES
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

    // MARK: - Documents

    fun fetchDocuments(sinceTimestamp: Long?, limit: Long?, allowedExtensions: List<String>?): List<DocumentResult> {
        Log.d(TAG, "fetchDocuments called, sinceTimestamp=$sinceTimestamp, limit=$limit")
        
        if (checkFilesPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Files permission not granted")
        }

        val results = mutableListOf<DocumentResult>()
        var count = 0
        val maxCount = limit?.toInt() ?: 100
        val extensions = allowedExtensions ?: listOf("txt", "md", "pdf", "rtf", "html")
        
        // On Android 11+ (API 30), use MediaStore to query Downloads and Documents
        // Direct file access to shared storage is not allowed in scoped storage
        Log.d(TAG, "Using MediaStore approach for shared storage access")
        
        // Always use MediaStore for shared storage (Downloads, Documents)
        fetchDocumentsViaMediaStore(sinceTimestamp, maxCount, extensions, results)
        
        // Also scan app's private external files directory (always accessible)
        val externalFilesDir = context.getExternalFilesDir(null)
        if (externalFilesDir != null && externalFilesDir.exists()) {
            Log.d(TAG, "Also scanning app's external files dir: ${externalFilesDir.absolutePath}")
            scanDirectoryForDocuments(externalFilesDir, extensions, sinceTimestamp, maxCount, results)
        }

        Log.d(TAG, "fetchDocuments completed, returning ${results.size} documents")
        return results.take(maxCount)
    }
    
    private fun scanDirectoryForDocuments(
        directory: java.io.File,
        extensions: List<String>,
        sinceTimestamp: Long?,
        maxCount: Int,
        results: MutableList<DocumentResult>
    ) {
        if (!directory.exists() || !directory.canRead()) {
            Log.d(TAG, "Cannot read directory: ${directory.absolutePath}")
            return
        }
        
        Log.d(TAG, "Scanning directory: ${directory.absolutePath}")
        
        try {
            val files = directory.listFiles() ?: return
            
            for (file in files) {
                if (results.size >= maxCount) break
                
                if (file.isDirectory) {
                    // Recursively scan subdirectories (limit depth to prevent infinite loops)
                    scanDirectoryForDocuments(file, extensions, sinceTimestamp, maxCount, results)
                } else if (file.isFile && file.canRead()) {
                    val extension = file.extension.lowercase()
                    if (extensions.any { it.lowercase() == extension }) {
                        val lastModified = file.lastModified()
                        
                        // Check timestamp filter
                        if (sinceTimestamp != null && lastModified < sinceTimestamp) {
                            continue
                        }
                        
                        val docType = when (extension) {
                            "txt" -> DocumentType.PLAIN_TEXT
                            "md", "markdown" -> DocumentType.MARKDOWN
                            "pdf" -> DocumentType.PDF
                            "rtf" -> DocumentType.RTF
                            "html", "htm" -> DocumentType.HTML
                            else -> DocumentType.OTHER
                        }
                        
                        val mimeType = when (extension) {
                            "txt" -> "text/plain"
                            "md", "markdown" -> "text/markdown"
                            "pdf" -> "application/pdf"
                            "rtf" -> "application/rtf"
                            "html", "htm" -> "text/html"
                            else -> "application/octet-stream"
                        }
                        
                        // Get text preview for text-based files
                        var textPreview: String? = null
                        if (docType == DocumentType.PLAIN_TEXT || docType == DocumentType.MARKDOWN || docType == DocumentType.HTML) {
                            try {
                                textPreview = file.readText().take(500)
                            } catch (e: Exception) {
                                Log.w(TAG, "Could not read preview for ${file.name}: ${e.message}")
                            }
                        }
                        
                        results.add(DocumentResult(
                            id = file.absolutePath.hashCode().toString(),
                            name = file.name,
                            path = file.absolutePath,
                            documentType = docType,
                            mimeType = mimeType,
                            fileSize = file.length(),
                            createdDate = lastModified, // File systems don't always track creation time
                            modifiedDate = lastModified,
                            textPreview = textPreview
                        ))
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error scanning directory ${directory.absolutePath}: ${e.message}")
        }
    }
    
    private fun fetchDocumentsViaMediaStore(
        sinceTimestamp: Long?,
        maxCount: Int,
        extensions: List<String>,
        results: MutableList<DocumentResult>
    ) {
        val contentResolver: ContentResolver = context.contentResolver
        var count = 0
        
        val projection = arrayOf(
            android.provider.MediaStore.Files.FileColumns._ID,
            android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME,
            android.provider.MediaStore.Files.FileColumns.DATA,
            android.provider.MediaStore.Files.FileColumns.MIME_TYPE,
            android.provider.MediaStore.Files.FileColumns.SIZE,
            android.provider.MediaStore.Files.FileColumns.DATE_ADDED,
            android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED
        )

        // Build selection for allowed extensions - use both MIME types AND filename patterns
        // Some files like .md may not have proper MIME types registered
        val mimeTypes = extensions.mapNotNull { ext ->
            when (ext.lowercase()) {
                "txt" -> "text/plain"
                "md", "markdown" -> "text/markdown"
                "pdf" -> "application/pdf"
                "rtf" -> "application/rtf"
                "html", "htm" -> "text/html"
                else -> null
            }
        }
        
        // Also build filename extension patterns
        val filenamePatterns = extensions.map { ext -> "%.${ext.lowercase()}" }
        
        val selectionBuilder = StringBuilder()
        val selectionArgsList = mutableListOf<String>()
        
        // Query by MIME type OR filename extension
        selectionBuilder.append("(")
        
        // MIME type conditions
        if (mimeTypes.isNotEmpty()) {
            selectionBuilder.append("(")
            mimeTypes.forEachIndexed { index, mimeType ->
                if (index > 0) selectionBuilder.append(" OR ")
                selectionBuilder.append("${android.provider.MediaStore.Files.FileColumns.MIME_TYPE} = ?")
                selectionArgsList.add(mimeType)
            }
            selectionBuilder.append(")")
        }
        
        // Filename extension conditions (catches .md files without proper MIME type)
        if (filenamePatterns.isNotEmpty()) {
            if (mimeTypes.isNotEmpty()) selectionBuilder.append(" OR ")
            selectionBuilder.append("(")
            filenamePatterns.forEachIndexed { index, pattern ->
                if (index > 0) selectionBuilder.append(" OR ")
                selectionBuilder.append("${android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME} LIKE ?")
                selectionArgsList.add(pattern)
            }
            selectionBuilder.append(")")
        }
        
        selectionBuilder.append(")")
        
        if (sinceTimestamp != null) {
            selectionBuilder.append(" AND ${android.provider.MediaStore.Files.FileColumns.DATE_ADDED} > ?")
            selectionArgsList.add((sinceTimestamp / 1000).toString())
        }

        Log.d(TAG, "MediaStore query selection: $selectionBuilder")
        Log.d(TAG, "MediaStore query args: $selectionArgsList")

        // Query Downloads collection specifically on Android 10+
        val contentUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI
        } else {
            android.provider.MediaStore.Files.getContentUri("external")
        }
        
        Log.d(TAG, "Querying content URI: $contentUri")

        val cursor: Cursor? = contentResolver.query(
            contentUri,
            projection,
            selectionBuilder.toString(),
            selectionArgsList.toTypedArray(),
            "${android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED} DESC"
        )

        Log.d(TAG, "Documents cursor returned: ${cursor?.count ?: 0} documents")

        cursor?.use {
            val idIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns._ID)
            val nameIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DISPLAY_NAME)
            val pathIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATA)
            val mimeTypeIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.MIME_TYPE)
            val sizeIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.SIZE)
            val dateAddedIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATE_ADDED)
            val dateModifiedIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATE_MODIFIED)

            while (it.moveToNext() && count < maxCount) {
                try {
                    val docId = it.getLong(idIndex)
                    val name = it.getString(nameIndex) ?: "Unknown"
                    val path = it.getString(pathIndex) ?: ""
                    val mimeType = it.getString(mimeTypeIndex)
                    val size = it.getLong(sizeIndex)
                    val dateAdded = it.getLong(dateAddedIndex) * 1000 // Convert to milliseconds
                    val dateModified = it.getLong(dateModifiedIndex) * 1000

                    val docType = when {
                        mimeType?.contains("text/plain") == true -> DocumentType.PLAIN_TEXT
                        mimeType?.contains("text/markdown") == true -> DocumentType.MARKDOWN
                        mimeType?.contains("pdf") == true -> DocumentType.PDF
                        mimeType?.contains("rtf") == true -> DocumentType.RTF
                        mimeType?.contains("html") == true -> DocumentType.HTML
                        name.endsWith(".txt") -> DocumentType.PLAIN_TEXT
                        name.endsWith(".md") -> DocumentType.MARKDOWN
                        name.endsWith(".pdf") -> DocumentType.PDF
                        name.endsWith(".rtf") -> DocumentType.RTF
                        name.endsWith(".html") || name.endsWith(".htm") -> DocumentType.HTML
                        else -> DocumentType.OTHER
                    }

                    // Get text preview for text files
                    var textPreview: String? = null
                    if (docType == DocumentType.PLAIN_TEXT || docType == DocumentType.MARKDOWN || docType == DocumentType.HTML) {
                        try {
                            val file = java.io.File(path)
                            if (file.exists() && file.canRead()) {
                                textPreview = file.readText().take(500)
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Could not read preview for $path: ${e.message}")
                        }
                    }

                    results.add(DocumentResult(
                        id = docId.toString(),
                        name = name,
                        path = path,
                        documentType = docType,
                        mimeType = mimeType,
                        fileSize = size,
                        createdDate = dateAdded,
                        modifiedDate = dateModified,
                        textPreview = textPreview
                    ))

                    count++
                } catch (e: Exception) {
                    Log.e(TAG, "Error processing document: ${e.message}")
                }
            }
        }

        Log.d(TAG, "MediaStore scan completed, found ${results.size} documents")
    }

    fun readDocumentContent(documentId: String, maxLength: Long?): String? {
        Log.d(TAG, "readDocumentContent called for id=$documentId, maxLength=$maxLength")
        
        if (checkFilesPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Files permission not granted")
        }

        val max = maxLength?.toInt() ?: Int.MAX_VALUE
        
        // On Android 11+, document IDs from scoped storage scan are path hashes
        // Try to find the file by scanning known directories
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Search for the file in accessible directories
            val searchDirs = listOfNotNull(
                context.getExternalFilesDir(null),
                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOCUMENTS),
                android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS)
            )
            
            for (dir in searchDirs) {
                val file = findFileByIdHash(dir, documentId)
                if (file != null) {
                    return readFileContent(file, max)
                }
            }
        }
        
        // Fall back to MediaStore lookup (for older Android or MediaStore-based IDs)
        val contentResolver: ContentResolver = context.contentResolver
        
        // Try to parse as numeric ID for MediaStore
        val numericId = documentId.toLongOrNull()
        if (numericId != null) {
            val projection = arrayOf(
                android.provider.MediaStore.Files.FileColumns.DATA,
                android.provider.MediaStore.Files.FileColumns.MIME_TYPE
            )

            val cursor: Cursor? = contentResolver.query(
                android.provider.MediaStore.Files.getContentUri("external"),
                projection,
                "${android.provider.MediaStore.Files.FileColumns._ID} = ?",
                arrayOf(documentId),
                null
            )

            cursor?.use {
                if (it.moveToFirst()) {
                    val pathIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.DATA)
                    val mimeTypeIndex = it.getColumnIndexOrThrow(android.provider.MediaStore.Files.FileColumns.MIME_TYPE)
                    
                    val path = it.getString(pathIndex)
                    val mimeType = it.getString(mimeTypeIndex)
                    
                    if (path != null) {
                        val file = java.io.File(path)
                        if (mimeType?.contains("pdf") == true) {
                            Log.w(TAG, "PDF content extraction not supported on Android")
                            return null
                        }
                        return readFileContent(file, max)
                    }
                }
            }
        }

        Log.w(TAG, "Could not find document with id: $documentId")
        return null
    }
    
    private fun findFileByIdHash(directory: java.io.File, idHash: String): java.io.File? {
        if (!directory.exists() || !directory.canRead()) return null
        
        val files = directory.listFiles() ?: return null
        
        for (file in files) {
            if (file.isDirectory) {
                val found = findFileByIdHash(file, idHash)
                if (found != null) return found
            } else if (file.absolutePath.hashCode().toString() == idHash) {
                return file
            }
        }
        return null
    }
    
    private fun readFileContent(file: java.io.File, maxLength: Int): String? {
        try {
            if (file.exists() && file.canRead()) {
                // Check if it's a PDF
                if (file.extension.lowercase() == "pdf") {
                    Log.w(TAG, "PDF content extraction not supported on Android")
                    return null
                }
                
                val content = file.readText()
                return if (content.length > maxLength) content.take(maxLength) else content
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error reading file content: ${e.message}")
        }
        return null
    }

    // MARK: - Photo Thumbnail

    fun getPhotoThumbnail(photoId: String, maxWidth: Long?, maxHeight: Long?): ByteArray? {
        Log.d(TAG, "getPhotoThumbnail called for id=$photoId")
        
        if (checkPhotosPermission() != PermissionStatus.GRANTED) {
            throw SecurityException("Photos permission not granted")
        }

        val contentResolver: ContentResolver = context.contentResolver
        
        try {
            val uri = android.content.ContentUris.withAppendedId(
                android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                photoId.toLong()
            )
            
            val width = maxWidth?.toInt() ?: 512
            val height = maxHeight?.toInt() ?: 512
            
            val thumbnail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                contentResolver.loadThumbnail(uri, android.util.Size(width, height), null)
            } else {
                @Suppress("DEPRECATION")
                android.provider.MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver,
                    photoId.toLong(),
                    android.provider.MediaStore.Images.Thumbnails.MINI_KIND,
                    null
                )
            }
            
            if (thumbnail != null) {
                val stream = java.io.ByteArrayOutputStream()
                thumbnail.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, stream)
                return stream.toByteArray()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error getting photo thumbnail: ${e.message}")
        }

        return null
    }
}
