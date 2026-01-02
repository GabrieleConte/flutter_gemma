import Foundation
import Contacts
import EventKit
import Photos
import CallKit

/// iOS System Data Connector for accessing user's contacts, calendar, photos, and call logs
class SystemDataConnector {

    // MARK: - Properties

    private let contactStore = CNContactStore()
    private let eventStore = EKEventStore()

    // MARK: - Permission Methods

    /// Check permission status for a given type
    func checkPermission(type: PermissionType) -> PermissionStatus {
        switch type {
        case .contacts:
            return checkContactsPermission()
        case .calendar:
            return checkCalendarPermission()
        case .photos:
            return checkPhotosPermission()
        case .callLog:
            return checkCallLogPermission()
        case .notifications:
            return .notDetermined // Not implemented yet
        case .files:
            return checkFilesPermission()
        }
    }

    /// Request permission for a given type
    func requestPermission(type: PermissionType, completion: @escaping (PermissionStatus) -> Void) {
        switch type {
        case .contacts:
            requestContactsPermission(completion: completion)
        case .calendar:
            requestCalendarPermission(completion: completion)
        case .photos:
            requestPhotosPermission(completion: completion)
        case .callLog:
            requestCallLogPermission(completion: completion)
        case .notifications:
            completion(.denied) // Not implemented yet
        case .files:
            requestFilesPermission(completion: completion)
        }
    }

    // MARK: - Contacts

    private func checkContactsPermission() -> PermissionStatus {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return mapContactsAuthStatus(status)
    }

    private func requestContactsPermission(completion: @escaping (PermissionStatus) -> Void) {
        contactStore.requestAccess(for: .contacts) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    completion(.granted)
                } else {
                    completion(.denied)
                }
            }
        }
    }

    private func mapContactsAuthStatus(_ status: CNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        case .limited:
            return .granted  // Limited access is still granted
        @unknown default:
            return .notDetermined
        }
    }

    /// Fetch contacts from the system
    func fetchContacts(sinceTimestamp: Int?, limit: Int?) throws -> [ContactResult] {
        // Check permission first
        guard checkContactsPermission() == .granted else {
            throw SystemDataError.permissionDenied("Contacts permission not granted")
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .givenName

        var contacts: [ContactResult] = []
        var count = 0
        let maxCount = limit ?? Int.max

        try contactStore.enumerateContacts(with: request) { contact, stop in
            // Check limit
            if count >= maxCount {
                stop.pointee = true
                return
            }

            // Get modification date if available (approximation using dates)
            var lastModified = Int(Date().timeIntervalSince1970)

            // Check if we should filter by timestamp
            if let since = sinceTimestamp {
                // CNContact doesn't expose modification date directly
                // We'll include all contacts when sinceTimestamp is provided
                // The actual filtering should happen at application level
                // based on stored sync state
                _ = since  // Acknowledge parameter
            }

            // Extract email addresses
            let emails = contact.emailAddresses.map { $0.value as String? }

            // Extract phone numbers
            let phones = contact.phoneNumbers.map { $0.value.stringValue as String? }

            let result = ContactResult(
                id: contact.identifier,
                givenName: contact.givenName.isEmpty ? nil : contact.givenName,
                familyName: contact.familyName.isEmpty ? nil : contact.familyName,
                organizationName: contact.organizationName.isEmpty ? nil : contact.organizationName,
                jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
                emailAddresses: emails,
                phoneNumbers: phones,
                lastModified: Int64(lastModified)
            )

            contacts.append(result)
            count += 1
        }

        return contacts
    }

    // MARK: - Calendar

    private func checkCalendarPermission() -> PermissionStatus {
        if #available(iOS 17.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            return mapCalendarAuthStatus(status)
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            return mapCalendarAuthStatus(status)
        }
    }

    private func requestCalendarPermission(completion: @escaping (PermissionStatus) -> Void) {
        if #available(iOS 17.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                DispatchQueue.main.async {
                    if granted {
                        completion(.granted)
                    } else {
                        completion(.denied)
                    }
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async {
                    if granted {
                        completion(.granted)
                    } else {
                        completion(.denied)
                    }
                }
            }
        }
    }

    private func mapCalendarAuthStatus(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Fetch calendar events from the system
    func fetchCalendarEvents(
        sinceTimestamp: Int?,
        startDate: Int?,
        endDate: Int?,
        limit: Int?
    ) throws -> [CalendarEventResult] {
        // Check permission first
        guard checkCalendarPermission() == .granted else {
            throw SystemDataError.permissionDenied("Calendar permission not granted")
        }

        // Determine date range
        let start: Date
        let end: Date

        if let startTimestamp = startDate {
            start = Date(timeIntervalSince1970: Double(startTimestamp))
        } else if let sinceTimestamp = sinceTimestamp {
            start = Date(timeIntervalSince1970: Double(sinceTimestamp))
        } else {
            // Default: 1 year ago
            start = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        }

        if let endTimestamp = endDate {
            end = Date(timeIntervalSince1970: Double(endTimestamp))
        } else {
            // Default: 1 year from now
            end = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
        }

        // Create predicate for events
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)

        // Fetch events
        var events = eventStore.events(matching: predicate)

        // Sort by start date
        events.sort { $0.startDate < $1.startDate }

        // Apply limit
        if let maxCount = limit {
            events = Array(events.prefix(maxCount))
        }

        // Convert to results
        return events.map { event in
            // Get attendees
            let attendees: [String?] = event.attendees?.compactMap { attendee in
                attendee.name ?? attendee.url?.absoluteString
            } ?? []

            // Get last modification date
            let lastModified = Int(event.lastModifiedDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970)

            return CalendarEventResult(
                id: event.eventIdentifier,
                title: event.title ?? "Untitled Event",
                location: event.location,
                notes: event.notes,
                startDate: Int64(event.startDate.timeIntervalSince1970),
                endDate: Int64(event.endDate.timeIntervalSince1970),
                attendees: attendees,
                lastModified: Int64(lastModified)
            )
        }
    }

    // MARK: - Photos Permission

    private func checkPhotosPermission() -> PermissionStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return mapPhotosAuthStatus(status)
    }

    private func requestPhotosPermission(completion: @escaping (PermissionStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(self.mapPhotosAuthStatus(status))
            }
        }
    }

    private func mapPhotosAuthStatus(_ status: PHAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:
            return .granted
        case .limited:
            return .granted // Limited access is still usable
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Fetch photos from the photo library
    func fetchPhotos(sinceTimestamp: Int?, limit: Int?, includeLocation: Bool?) throws -> [PhotoResult] {
        // Check permission first
        guard checkPhotosPermission() == .granted else {
            throw SystemDataError.permissionDenied("Photos permission not granted")
        }

        var results: [PhotoResult] = []
        let maxCount = limit ?? 500 // Default limit to prevent memory issues

        // Create fetch options
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        // Filter by date if sinceTimestamp provided
        if let timestamp = sinceTimestamp {
            let sinceDate = Date(timeIntervalSince1970: Double(timestamp))
            fetchOptions.predicate = NSPredicate(format: "creationDate > %@", sinceDate as NSDate)
        }

        fetchOptions.fetchLimit = maxCount

        // Fetch assets
        let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)

        // Process assets
        assets.enumerateObjects { (asset, index, stop) in
            if results.count >= maxCount {
                stop.pointee = true
                return
            }

            // Get location if requested
            var latitude: Double?
            var longitude: Double?
            var locationName: String?

            if includeLocation == true, let location = asset.location {
                latitude = location.coordinate.latitude
                longitude = location.coordinate.longitude
                // Note: Reverse geocoding would need to be done asynchronously
            }

            let result = PhotoResult(
                id: asset.localIdentifier,
                filename: asset.value(forKey: "filename") as? String,
                width: Int64(asset.pixelWidth),
                height: Int64(asset.pixelHeight),
                creationDate: Int64(asset.creationDate?.timeIntervalSince1970 ?? 0),
                modificationDate: Int64(asset.modificationDate?.timeIntervalSince1970 ?? 0),
                latitude: latitude,
                longitude: longitude,
                locationName: locationName,
                duration: asset.mediaType == .video ? Int64(asset.duration * 1000) : nil,
                mediaType: asset.mediaType == .image ? "image" : "video",
                mimeType: self.getMimeType(for: asset),
                fileSize: nil, // Requires async resource request
                thumbnailBytes: nil // Can be loaded on demand
            )

            results.append(result)
        }

        return results
    }

    private func getMimeType(for asset: PHAsset) -> String? {
        guard let resource = PHAssetResource.assetResources(for: asset).first else {
            return nil
        }
        return resource.uniformTypeIdentifier
    }

    // MARK: - Call Log Permission
    
    /// iOS has very limited call log access - only via CallKit for VoIP apps
    /// Regular call history is not accessible on iOS for privacy reasons
    
    private func checkCallLogPermission() -> PermissionStatus {
        // iOS doesn't provide access to the system call log
        // CallKit only works for VoIP apps
        // Return restricted to indicate this is a platform limitation
        return .restricted
    }

    private func requestCallLogPermission(completion: @escaping (PermissionStatus) -> Void) {
        // iOS doesn't allow access to call history
        // This is a platform limitation, not a permission issue
        completion(.restricted)
    }

    /// Fetch call log - iOS does not provide access to system call history
    /// This returns an empty array and logs a warning
    func fetchCallLog(sinceTimestamp: Int?, limit: Int?) throws -> [CallLogResult] {
        // iOS does not provide API access to the system call log
        // Only CallKit-enabled VoIP apps can track their own calls
        // Regular telephony call history is not accessible for privacy reasons
        print("⚠️ Call log is not accessible on iOS due to platform restrictions")
        return []
    }

    // MARK: - Files Permission

    private func checkFilesPermission() -> PermissionStatus {
        // iOS uses sandboxed file access - apps can access their own container
        // For accessing iCloud/Files app, additional entitlements are needed
        // For now, we return granted since we can access app sandbox
        return .granted
    }

    private func requestFilesPermission(completion: @escaping (PermissionStatus) -> Void) {
        // iOS sandboxed file access doesn't require explicit permission
        completion(.granted)
    }

    // MARK: - Documents

    /// Fetch documents from the app's sandbox
    /// Note: iOS apps can only access their own sandbox unless using document picker
    func fetchDocuments(sinceTimestamp: Int?, limit: Int?, allowedExtensions: [String]?) throws -> [DocumentResult] {
        print("📄 Fetching documents from app sandbox")
        
        var results: [DocumentResult] = []
        let maxCount = limit ?? 100
        
        // Get the documents directory
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return []
        }
        
        let extensions = allowedExtensions ?? ["txt", "md", "pdf", "rtf", "html"]
        
        // Get all files in documents directory
        if let enumerator = fileManager.enumerator(at: documentsURL, includingPropertiesForKeys: [
            .isRegularFileKey,
            .nameKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey
        ]) {
            var count = 0
            while let fileURL = enumerator.nextObject() as? URL, count < maxCount {
                do {
                    let resourceValues = try fileURL.resourceValues(forKeys: [
                        .isRegularFileKey,
                        .nameKey,
                        .fileSizeKey,
                        .creationDateKey,
                        .contentModificationDateKey
                    ])
                    
                    guard resourceValues.isRegularFile == true else { continue }
                    
                    let ext = fileURL.pathExtension.lowercased()
                    guard extensions.contains(ext) else { continue }
                    
                    let name = resourceValues.name ?? fileURL.lastPathComponent
                    let size = Int64(resourceValues.fileSize ?? 0)
                    let createdDate = resourceValues.creationDate ?? Date()
                    let modifiedDate = resourceValues.contentModificationDate ?? Date()
                    
                    // Check sinceTimestamp
                    if let since = sinceTimestamp {
                        let sinceDate = Date(timeIntervalSince1970: TimeInterval(since) / 1000.0)
                        if modifiedDate < sinceDate { continue }
                    }
                    
                    let docType: DocumentType
                    switch ext {
                    case "txt":
                        docType = .plainText
                    case "md", "markdown":
                        docType = .markdown
                    case "pdf":
                        docType = .pdf
                    case "rtf":
                        docType = .rtf
                    case "html", "htm":
                        docType = .html
                    default:
                        docType = .other
                    }
                    
                    // Get text preview for text-based files
                    var textPreview: String? = nil
                    if docType == .plainText || docType == .markdown || docType == .html {
                        if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                            textPreview = String(content.prefix(500))
                        }
                    }
                    
                    let result = DocumentResult(
                        id: fileURL.absoluteString,
                        name: name,
                        path: fileURL.path,
                        documentType: docType,
                        mimeType: mimeType(for: ext),
                        fileSize: size,
                        createdDate: Int64(createdDate.timeIntervalSince1970 * 1000),
                        modifiedDate: Int64(modifiedDate.timeIntervalSince1970 * 1000),
                        textPreview: textPreview
                    )
                    
                    results.append(result)
                    count += 1
                } catch {
                    print("Error reading file attributes: \(error)")
                }
            }
        }
        
        print("📄 Found \(results.count) documents")
        return results
    }

    /// Read document content
    func readDocumentContent(documentId: String, maxLength: Int?) throws -> String? {
        guard let fileURL = URL(string: documentId) else {
            return nil
        }
        
        let ext = fileURL.pathExtension.lowercased()
        
        // For PDF files, we would need PDFKit - return nil for now
        if ext == "pdf" {
            print("⚠️ PDF content extraction requires PDFKit integration")
            return nil
        }
        
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        
        if let max = maxLength, content.count > max {
            return String(content.prefix(max))
        }
        
        return content
    }

    /// Get MIME type for file extension
    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "txt":
            return "text/plain"
        case "md", "markdown":
            return "text/markdown"
        case "pdf":
            return "application/pdf"
        case "rtf":
            return "application/rtf"
        case "html", "htm":
            return "text/html"
        default:
            return "application/octet-stream"
        }
    }

    // MARK: - Photo Thumbnail

    /// Get a thumbnail for a photo
    func getPhotoThumbnail(photoId: String, maxWidth: Int, maxHeight: Int) throws -> Data? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SystemDataError.permissionDenied("Photos permission not granted")
        }

        // Parse the photo ID
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoId], options: nil).firstObject else {
            return nil
        }

        var resultData: Data? = nil
        let semaphore = DispatchSemaphore(value: 0)

        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact

        let targetSize = CGSize(width: maxWidth, height: maxHeight)

        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            if let image = image, let data = image.jpegData(compressionQuality: 0.85) {
                resultData = data
            }
            semaphore.signal()
        }

        semaphore.wait()
        return resultData
    }
}

// MARK: - Error Types

enum SystemDataError: Error, LocalizedError {
    case permissionDenied(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let message):
            return "Permission denied: \(message)"
        case .fetchFailed(let message):
            return "Fetch failed: \(message)"
        }
    }
}
