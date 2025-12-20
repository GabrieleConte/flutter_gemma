import 'dart:async';

import 'data_connector.dart';

/// OAuth token for Google authentication
class GoogleOAuthToken {
  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
  final List<String> scopes;

  GoogleOAuthToken({
    required this.accessToken,
    this.refreshToken,
    required this.expiresAt,
    required this.scopes,
  });

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  factory GoogleOAuthToken.fromJson(Map<String, dynamic> json) {
    return GoogleOAuthToken(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (json['expires_in'] as int) * 1000 + DateTime.now().millisecondsSinceEpoch,
      ),
      scopes: (json['scope'] as String?)?.split(' ') ?? [],
    );
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt.millisecondsSinceEpoch,
    'scopes': scopes,
  };
}

/// Google API scopes for various services
class GoogleScopes {
  static const String contactsReadonly = 'https://www.googleapis.com/auth/contacts.readonly';
  static const String calendarReadonly = 'https://www.googleapis.com/auth/calendar.readonly';
  static const String driveReadonly = 'https://www.googleapis.com/auth/drive.readonly';
  static const String gmailReadonly = 'https://www.googleapis.com/auth/gmail.readonly';
  static const String gmailMetadata = 'https://www.googleapis.com/auth/gmail.metadata';
  static const String profile = 'https://www.googleapis.com/auth/userinfo.profile';
  static const String email = 'https://www.googleapis.com/auth/userinfo.email';
}

/// Callback interface for OAuth flow
abstract class GoogleOAuthHandler {
  /// Start OAuth flow and return authorization code
  /// Implementation should open browser/webview for user to authorize
  Future<String> getAuthorizationCode(String authUrl, String redirectUri);
  
  /// Store token securely
  Future<void> storeToken(GoogleOAuthToken token);
  
  /// Retrieve stored token
  Future<GoogleOAuthToken?> getStoredToken();
  
  /// Clear stored token
  Future<void> clearToken();
}

/// Configuration for Google Suite connector
class GoogleSuiteConfig extends ConnectorConfig {
  /// Google OAuth client ID
  final String clientId;
  
  /// Google OAuth client secret (optional for mobile)
  final String? clientSecret;
  
  /// OAuth redirect URI
  final String redirectUri;
  
  /// Requested scopes
  final List<String> scopes;
  
  /// OAuth handler for authentication flow
  final GoogleOAuthHandler oauthHandler;

  GoogleSuiteConfig({
    required this.clientId,
    this.clientSecret,
    required this.redirectUri,
    required this.scopes,
    required this.oauthHandler,
    super.incrementalSync,
    super.refreshInterval,
    super.batchSize,
    super.onProgress,
  });
}

/// Google contact from People API
class GoogleContact {
  final String resourceName;
  final String? etag;
  final String? displayName;
  final String? givenName;
  final String? familyName;
  final List<String> emailAddresses;
  final List<String> phoneNumbers;
  final String? organization;
  final String? jobTitle;
  final String? photo;

  GoogleContact({
    required this.resourceName,
    this.etag,
    this.displayName,
    this.givenName,
    this.familyName,
    this.emailAddresses = const [],
    this.phoneNumbers = const [],
    this.organization,
    this.jobTitle,
    this.photo,
  });

  factory GoogleContact.fromJson(Map<String, dynamic> json) {
    final names = json['names'] as List<dynamic>? ?? [];
    final emails = json['emailAddresses'] as List<dynamic>? ?? [];
    final phones = json['phoneNumbers'] as List<dynamic>? ?? [];
    final orgs = json['organizations'] as List<dynamic>? ?? [];
    final photos = json['photos'] as List<dynamic>? ?? [];

    return GoogleContact(
      resourceName: json['resourceName'] as String,
      etag: json['etag'] as String?,
      displayName: names.isNotEmpty 
          ? names.first['displayName'] as String? 
          : null,
      givenName: names.isNotEmpty 
          ? names.first['givenName'] as String? 
          : null,
      familyName: names.isNotEmpty 
          ? names.first['familyName'] as String? 
          : null,
      emailAddresses: emails
          .map((e) => e['value'] as String)
          .where((v) => v.isNotEmpty)
          .toList(),
      phoneNumbers: phones
          .map((p) => p['value'] as String)
          .where((v) => v.isNotEmpty)
          .toList(),
      organization: orgs.isNotEmpty 
          ? orgs.first['name'] as String? 
          : null,
      jobTitle: orgs.isNotEmpty 
          ? orgs.first['title'] as String? 
          : null,
      photo: photos.isNotEmpty 
          ? photos.first['url'] as String? 
          : null,
    );
  }
}

/// Google calendar event from Calendar API
class GoogleCalendarEvent {
  final String id;
  final String? summary;
  final String? description;
  final String? location;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? calendarId;
  final List<String> attendees;
  final String? hangoutLink;
  final DateTime? created;
  final DateTime? updated;

  GoogleCalendarEvent({
    required this.id,
    this.summary,
    this.description,
    this.location,
    required this.start,
    required this.end,
    this.isAllDay = false,
    this.calendarId,
    this.attendees = const [],
    this.hangoutLink,
    this.created,
    this.updated,
  });

  factory GoogleCalendarEvent.fromJson(Map<String, dynamic> json) {
    final startJson = json['start'] as Map<String, dynamic>?;
    final endJson = json['end'] as Map<String, dynamic>?;
    final attendeesJson = json['attendees'] as List<dynamic>? ?? [];

    // Handle all-day events (date) vs timed events (dateTime)
    DateTime parseDateTime(Map<String, dynamic>? obj, bool useEnd) {
      if (obj == null) return DateTime.now();
      if (obj.containsKey('dateTime')) {
        return DateTime.parse(obj['dateTime'] as String);
      } else if (obj.containsKey('date')) {
        final date = DateTime.parse(obj['date'] as String);
        // For end date of all-day event, subtract one day since it's exclusive
        return useEnd ? date.subtract(const Duration(days: 1)) : date;
      }
      return DateTime.now();
    }

    return GoogleCalendarEvent(
      id: json['id'] as String,
      summary: json['summary'] as String?,
      description: json['description'] as String?,
      location: json['location'] as String?,
      start: parseDateTime(startJson, false),
      end: parseDateTime(endJson, true),
      isAllDay: startJson?.containsKey('date') ?? false,
      calendarId: json['calendarId'] as String?,
      attendees: attendeesJson
          .map((a) => a['email'] as String? ?? '')
          .where((e) => e.isNotEmpty)
          .toList(),
      hangoutLink: json['hangoutLink'] as String?,
      created: json['created'] != null 
          ? DateTime.parse(json['created'] as String) 
          : null,
      updated: json['updated'] != null 
          ? DateTime.parse(json['updated'] as String) 
          : null,
    );
  }
}

/// Google Drive file metadata
class GoogleDriveFile {
  final String id;
  final String name;
  final String mimeType;
  final int? size;
  final DateTime? createdTime;
  final DateTime? modifiedTime;
  final String? webViewLink;
  final List<String> owners;

  GoogleDriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    this.size,
    this.createdTime,
    this.modifiedTime,
    this.webViewLink,
    this.owners = const [],
  });

  bool get isFolder => mimeType == 'application/vnd.google-apps.folder';
  bool get isDocument => mimeType == 'application/vnd.google-apps.document';
  bool get isSpreadsheet => mimeType == 'application/vnd.google-apps.spreadsheet';

  factory GoogleDriveFile.fromJson(Map<String, dynamic> json) {
    final ownersJson = json['owners'] as List<dynamic>? ?? [];
    
    return GoogleDriveFile(
      id: json['id'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String,
      size: json['size'] != null ? int.tryParse(json['size'].toString()) : null,
      createdTime: json['createdTime'] != null 
          ? DateTime.parse(json['createdTime'] as String) 
          : null,
      modifiedTime: json['modifiedTime'] != null 
          ? DateTime.parse(json['modifiedTime'] as String) 
          : null,
      webViewLink: json['webViewLink'] as String?,
      owners: ownersJson
          .map((o) => o['emailAddress'] as String? ?? '')
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }
}

/// Gmail message metadata
class GmailMessage {
  final String id;
  final String threadId;
  final List<String> labelIds;
  final String? subject;
  final String? from;
  final List<String> to;
  final String? snippet;
  final DateTime? date;
  final bool isUnread;

  GmailMessage({
    required this.id,
    required this.threadId,
    this.labelIds = const [],
    this.subject,
    this.from,
    this.to = const [],
    this.snippet,
    this.date,
    this.isUnread = false,
  });

  factory GmailMessage.fromJson(Map<String, dynamic> json) {
    final payload = json['payload'] as Map<String, dynamic>? ?? {};
    final headers = payload['headers'] as List<dynamic>? ?? [];
    final labelIds = (json['labelIds'] as List<dynamic>? ?? [])
        .map((l) => l.toString())
        .toList();

    String? getHeader(String name) {
      for (final h in headers) {
        if ((h['name'] as String?)?.toLowerCase() == name.toLowerCase()) {
          return h['value'] as String?;
        }
      }
      return null;
    }

    final dateStr = getHeader('Date');
    DateTime? date;
    if (dateStr != null) {
      try {
        // RFC 2822 date parsing (simplified)
        date = DateTime.tryParse(dateStr);
      } catch (_) {}
    }

    final toHeader = getHeader('To') ?? '';
    final toList = toHeader.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    return GmailMessage(
      id: json['id'] as String,
      threadId: json['threadId'] as String,
      labelIds: labelIds,
      subject: getHeader('Subject'),
      from: getHeader('From'),
      to: toList,
      snippet: json['snippet'] as String?,
      date: date,
      isUnread: labelIds.contains('UNREAD'),
    );
  }
}

/// Abstract base for Google API connectors
abstract class GoogleSuiteConnector implements DataConnector {
  final GoogleSuiteConfig googleConfig;
  GoogleOAuthToken? _token;
  DateTime? _lastSyncTime;

  GoogleSuiteConnector(this.googleConfig);

  @override
  ConnectorConfig get config => googleConfig;

  @override
  DateTime? get lastSyncTime => _lastSyncTime;

  @override
  List<DataPermissionType> get requiredPermissions => [];

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> checkPermissions() async {
    // Google connectors use OAuth, not system permissions
    return {};
  }

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions() async {
    // Trigger OAuth flow instead
    await authenticate();
    return {};
  }

  @override
  Future<bool> hasRequiredPermissions() async {
    _token ??= await googleConfig.oauthHandler.getStoredToken();
    return _token != null && !_token!.isExpired;
  }

  /// Start OAuth authentication flow
  Future<void> authenticate() async {
    final authUrl = _buildAuthUrl();
    final code = await googleConfig.oauthHandler.getAuthorizationCode(
      authUrl,
      googleConfig.redirectUri,
    );
    _token = await _exchangeCodeForToken(code);
    await googleConfig.oauthHandler.storeToken(_token!);
  }

  /// Sign out and clear stored credentials
  Future<void> signOut() async {
    _token = null;
    await googleConfig.oauthHandler.clearToken();
  }

  /// Check if authenticated
  bool get isAuthenticated => _token != null && !_token!.isExpired;

  String _buildAuthUrl() {
    final params = {
      'client_id': googleConfig.clientId,
      'redirect_uri': googleConfig.redirectUri,
      'response_type': 'code',
      'scope': googleConfig.scopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
    };
    final queryString = params.entries
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'https://accounts.google.com/o/oauth2/v2/auth?$queryString';
  }

  Future<GoogleOAuthToken> _exchangeCodeForToken(String code) async {
    // This would typically make an HTTP request to Google's token endpoint
    // For now, this is a stub that should be implemented with http package
    throw UnimplementedError(
      'Token exchange not implemented. '
      'Add http package and implement OAuth token exchange.',
    );
  }

  /// Refresh the access token using refresh token
  Future<void> refreshToken() async {
    if (_token?.refreshToken == null) {
      throw StateError('No refresh token available. Re-authenticate.');
    }
    // Implement token refresh with http package
    throw UnimplementedError(
      'Token refresh not implemented. '
      'Add http package and implement OAuth token refresh.',
    );
  }

  /// Get valid access token, refreshing if necessary
  Future<String> getAccessToken() async {
    _token ??= await googleConfig.oauthHandler.getStoredToken();
    
    if (_token == null) {
      throw StateError('Not authenticated. Call authenticate() first.');
    }
    
    if (_token!.isExpired) {
      await refreshToken();
    }
    
    return _token!.accessToken;
  }

  /// Update last sync time after successful fetch
  void markSynced() {
    _lastSyncTime = DateTime.now();
  }
}

/// Google Contacts connector using People API
class GoogleContactsConnector extends GoogleSuiteConnector {
  @override
  final String dataType = 'google_contacts';

  GoogleContactsConnector(super.googleConfig);

  @override
  Future<List<GoogleContact>> fetch({DateTime? since, int? limit}) async {
    // This would make HTTP requests to People API
    // GET https://people.googleapis.com/v1/people/me/connections
    // Headers: Authorization: Bearer <access_token>
    
    // Stub implementation - needs http package
    markSynced();
    return [];
  }
}

/// Google Calendar connector using Calendar API
class GoogleCalendarConnector extends GoogleSuiteConnector {
  @override
  final String dataType = 'google_calendar';

  GoogleCalendarConnector(super.googleConfig);

  @override
  Future<List<GoogleCalendarEvent>> fetch({DateTime? since, int? limit}) async {
    // This would make HTTP requests to Calendar API
    // GET https://www.googleapis.com/calendar/v3/calendars/primary/events
    // Headers: Authorization: Bearer <access_token>
    
    // Stub implementation - needs http package
    markSynced();
    return [];
  }
}

/// Google Drive connector using Drive API
class GoogleDriveConnector extends GoogleSuiteConnector {
  @override
  final String dataType = 'google_drive';

  GoogleDriveConnector(super.googleConfig);

  @override
  Future<List<GoogleDriveFile>> fetch({DateTime? since, int? limit}) async {
    // This would make HTTP requests to Drive API
    // GET https://www.googleapis.com/drive/v3/files
    // Headers: Authorization: Bearer <access_token>
    
    // Stub implementation - needs http package
    markSynced();
    return [];
  }
}

/// Gmail connector using Gmail API
class GmailConnector extends GoogleSuiteConnector {
  @override
  final String dataType = 'gmail';

  GmailConnector(super.googleConfig);

  @override
  Future<List<GmailMessage>> fetch({DateTime? since, int? limit}) async {
    // This would make HTTP requests to Gmail API
    // GET https://www.googleapis.com/gmail/v1/users/me/messages
    // Headers: Authorization: Bearer <access_token>
    
    // Stub implementation - needs http package
    markSynced();
    return [];
  }
}
