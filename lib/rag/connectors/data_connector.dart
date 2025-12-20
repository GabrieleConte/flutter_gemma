import 'dart:async';

import '../../pigeon.g.dart';

/// Permission status for data access
enum DataPermissionStatus {
  /// Permission hasn't been requested yet
  notDetermined,
  /// Permission was denied by user
  denied,
  /// Permission was granted
  granted,
  /// Permission is restricted (e.g., parental controls)
  restricted,
}

/// Permission type for system data
enum DataPermissionType {
  contacts,
  calendar,
}

/// Represents a contact from the system
class Contact {
  final String id;
  final String? givenName;
  final String? familyName;
  final String? organizationName;
  final String? jobTitle;
  final List<String> emailAddresses;
  final List<String> phoneNumbers;
  final DateTime lastModified;

  Contact({
    required this.id,
    this.givenName,
    this.familyName,
    this.organizationName,
    this.jobTitle,
    this.emailAddresses = const [],
    this.phoneNumbers = const [],
    required this.lastModified,
  });

  String get fullName {
    final parts = [givenName, familyName]
        .where((p) => p != null && p.isNotEmpty)
        .toList();
    return parts.join(' ');
  }

  factory Contact.fromContactResult(ContactResult result) {
    return Contact(
      id: result.id,
      givenName: result.givenName,
      familyName: result.familyName,
      organizationName: result.organizationName,
      jobTitle: result.jobTitle,
      // Filter out nulls from nullable list
      emailAddresses: result.emailAddresses.whereType<String>().toList(),
      phoneNumbers: result.phoneNumbers.whereType<String>().toList(),
      lastModified: DateTime.fromMillisecondsSinceEpoch(result.lastModified),
    );
  }

  @override
  String toString() => 'Contact(id: $id, name: $fullName)';
}

/// Represents a calendar event from the system
class CalendarEvent {
  final String id;
  final String title;
  final String? location;
  final String? notes;
  final DateTime startDate;
  final DateTime endDate;
  final List<String> attendees;
  final DateTime lastModified;

  CalendarEvent({
    required this.id,
    required this.title,
    this.location,
    this.notes,
    required this.startDate,
    required this.endDate,
    this.attendees = const [],
    required this.lastModified,
  });

  Duration get duration => endDate.difference(startDate);

  factory CalendarEvent.fromCalendarEventResult(CalendarEventResult result) {
    return CalendarEvent(
      id: result.id,
      title: result.title,
      location: result.location,
      notes: result.notes,
      startDate: DateTime.fromMillisecondsSinceEpoch(result.startDate),
      endDate: DateTime.fromMillisecondsSinceEpoch(result.endDate),
      // Filter out nulls from nullable list
      attendees: result.attendees.whereType<String>().toList(),
      lastModified: DateTime.fromMillisecondsSinceEpoch(result.lastModified),
    );
  }

  @override
  String toString() =>
      'CalendarEvent(id: $id, title: $title, start: $startDate)';
}

/// Configuration for a data connector
class ConnectorConfig {
  /// Whether to enable incremental sync
  final bool incrementalSync;
  
  /// Interval for periodic full refresh (null = no auto refresh)
  final Duration? refreshInterval;
  
  /// Maximum items to fetch per batch
  final int batchSize;
  
  /// Callback for progress updates
  final void Function(double progress, String message)? onProgress;

  ConnectorConfig({
    this.incrementalSync = true,
    this.refreshInterval,
    this.batchSize = 100,
    this.onProgress,
  });
}

/// Abstract interface for data connectors
abstract class DataConnector {
  /// The type of data this connector handles
  String get dataType;

  /// Required permissions for this connector
  List<DataPermissionType> get requiredPermissions;

  /// Configuration for this connector
  ConnectorConfig get config;

  /// Check current permission status
  Future<Map<DataPermissionType, DataPermissionStatus>> checkPermissions();

  /// Request required permissions from user
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions();

  /// Whether all required permissions are granted
  Future<bool> hasRequiredPermissions();

  /// Fetch data from the source
  /// [since] - Only fetch data modified after this timestamp (for incremental sync)
  /// [limit] - Maximum number of items to fetch
  Future<List<dynamic>> fetch({DateTime? since, int? limit});

  /// Get last sync timestamp
  DateTime? get lastSyncTime;
}

/// Native contacts connector
class ContactsConnector implements DataConnector {
  final PlatformService _platform;
  DateTime? _lastSyncTime;

  @override
  final String dataType = 'contacts';

  @override
  final List<DataPermissionType> requiredPermissions = [
    DataPermissionType.contacts
  ];

  @override
  final ConnectorConfig config;

  ContactsConnector(this._platform, {ConnectorConfig? config})
      : config = config ?? ConnectorConfig();

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> checkPermissions() async {
    final status = await _platform.checkPermission(PermissionType.contacts);
    return {
      DataPermissionType.contacts: _mapPermissionStatus(status),
    };
  }

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions() async {
    final status = await _platform.requestPermission(PermissionType.contacts);
    return {
      DataPermissionType.contacts: _mapPermissionStatus(status),
    };
  }

  @override
  Future<bool> hasRequiredPermissions() async {
    final perms = await checkPermissions();
    return perms[DataPermissionType.contacts] == DataPermissionStatus.granted;
  }

  @override
  Future<List<Contact>> fetch({DateTime? since, int? limit}) async {
    final sinceTimestamp = since?.millisecondsSinceEpoch;
    final results = await _platform.fetchContacts(
      sinceTimestamp: sinceTimestamp,
      limit: limit,
    );
    
    _lastSyncTime = DateTime.now();
    config.onProgress?.call(1.0, 'Fetched ${results.length} contacts');
    
    return results.map((r) => Contact.fromContactResult(r)).toList();
  }

  @override
  DateTime? get lastSyncTime => _lastSyncTime;
}

/// Native calendar connector
class CalendarConnector implements DataConnector {
  final PlatformService _platform;
  DateTime? _lastSyncTime;

  @override
  final String dataType = 'calendar';

  @override
  final List<DataPermissionType> requiredPermissions = [
    DataPermissionType.calendar
  ];

  @override
  final ConnectorConfig config;

  /// Date range for fetching events
  final DateTime? startDate;
  final DateTime? endDate;

  CalendarConnector(
    this._platform, {
    ConnectorConfig? config,
    this.startDate,
    this.endDate,
  }) : config = config ?? ConnectorConfig();

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> checkPermissions() async {
    final status = await _platform.checkPermission(PermissionType.calendar);
    return {
      DataPermissionType.calendar: _mapPermissionStatus(status),
    };
  }

  @override
  Future<Map<DataPermissionType, DataPermissionStatus>> requestPermissions() async {
    final status = await _platform.requestPermission(PermissionType.calendar);
    return {
      DataPermissionType.calendar: _mapPermissionStatus(status),
    };
  }

  @override
  Future<bool> hasRequiredPermissions() async {
    final perms = await checkPermissions();
    return perms[DataPermissionType.calendar] == DataPermissionStatus.granted;
  }

  @override
  Future<List<CalendarEvent>> fetch({DateTime? since, int? limit}) async {
    final sinceTimestamp = since?.millisecondsSinceEpoch;
    final results = await _platform.fetchCalendarEvents(
      sinceTimestamp: sinceTimestamp,
      startDate: startDate?.millisecondsSinceEpoch,
      endDate: endDate?.millisecondsSinceEpoch,
      limit: limit,
    );
    
    _lastSyncTime = DateTime.now();
    config.onProgress?.call(1.0, 'Fetched ${results.length} calendar events');
    
    return results.map((r) => CalendarEvent.fromCalendarEventResult(r)).toList();
  }

  @override
  DateTime? get lastSyncTime => _lastSyncTime;
}

/// Manager for multiple data connectors
class ConnectorManager {
  final Map<String, DataConnector> _connectors = {};
  final Map<String, DateTime?> _lastSyncTimes = {};

  /// Register a data connector
  void registerConnector(DataConnector connector) {
    _connectors[connector.dataType] = connector;
  }

  /// Get a registered connector by type
  DataConnector? getConnector(String dataType) => _connectors[dataType];

  /// Get all registered connectors
  List<DataConnector> get connectors => _connectors.values.toList();

  /// Check permissions for all connectors
  Future<Map<String, Map<DataPermissionType, DataPermissionStatus>>> 
      checkAllPermissions() async {
    final results = <String, Map<DataPermissionType, DataPermissionStatus>>{};
    for (final entry in _connectors.entries) {
      results[entry.key] = await entry.value.checkPermissions();
    }
    return results;
  }

  /// Request permissions for a specific connector
  Future<Map<DataPermissionType, DataPermissionStatus>> 
      requestPermissions(String dataType) async {
    final connector = _connectors[dataType];
    if (connector == null) {
      throw ArgumentError('Unknown connector type: $dataType');
    }
    return await connector.requestPermissions();
  }

  /// Fetch data from a specific connector
  /// Returns list of items or throws if permissions not granted
  Future<List<dynamic>> fetchData(
    String dataType, {
    bool incrementalSync = true,
    int? limit,
  }) async {
    final connector = _connectors[dataType];
    if (connector == null) {
      throw ArgumentError('Unknown connector type: $dataType');
    }

    if (!await connector.hasRequiredPermissions()) {
      throw PermissionDeniedException(
        'Missing required permissions for $dataType connector',
        connector.requiredPermissions,
      );
    }

    final since = incrementalSync ? _lastSyncTimes[dataType] : null;
    final data = await connector.fetch(
      since: since,
      limit: limit ?? connector.config.batchSize,
    );
    
    _lastSyncTimes[dataType] = DateTime.now();
    return data;
  }

  /// Fetch data from all connectors with required permissions
  Future<Map<String, List<dynamic>>> fetchAllAvailable({
    bool incrementalSync = true,
  }) async {
    final results = <String, List<dynamic>>{};
    
    for (final connector in _connectors.values) {
      try {
        if (await connector.hasRequiredPermissions()) {
          final data = await fetchData(
            connector.dataType,
            incrementalSync: incrementalSync,
          );
          results[connector.dataType] = data;
        }
      } catch (e) {
        // Skip connectors that fail
        results[connector.dataType] = [];
      }
    }
    
    return results;
  }

  /// Get last sync time for a connector
  DateTime? getLastSyncTime(String dataType) => _lastSyncTimes[dataType];

  /// Reset sync state for incremental sync
  void resetSyncState([String? dataType]) {
    if (dataType != null) {
      _lastSyncTimes.remove(dataType);
    } else {
      _lastSyncTimes.clear();
    }
  }
}

/// Exception thrown when required permissions are not granted
class PermissionDeniedException implements Exception {
  final String message;
  final List<DataPermissionType> missingPermissions;

  PermissionDeniedException(this.message, this.missingPermissions);

  @override
  String toString() => 'PermissionDeniedException: $message';
}

// Helper to map Pigeon permission status to Dart enum
DataPermissionStatus _mapPermissionStatus(PermissionStatus status) {
  switch (status) {
    case PermissionStatus.notDetermined:
      return DataPermissionStatus.notDetermined;
    case PermissionStatus.denied:
      return DataPermissionStatus.denied;
    case PermissionStatus.granted:
      return DataPermissionStatus.granted;
    case PermissionStatus.restricted:
      return DataPermissionStatus.restricted;
  }
}
