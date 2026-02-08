/// Dart payload models mirroring the Python payloads.py definitions.
///
/// These models normalize data from both native platform APIs and server-synced
/// sources into a common format for entity extraction and graph storage.
library;

/// Field name normalization utilities for Python ↔ Dart interop.
class PayloadFieldNormalizer {
  /// Normalize a map from Python snake_case keys to Dart camelCase conventions,
  /// and unify field name variants (e.g. `telephone_number` → `phoneNumbers`).
  static Map<String, dynamic> normalize(
    Map<String, dynamic> data,
    String dataType,
  ) {
    final result = Map<String, dynamic>.from(data);

    // Universal: snake_case → camelCase for common fields
    _renameKey(result, 'source_app', 'sourceApp');
    _renameKey(result, 'date_created', 'dateCreated');
    _renameKey(result, 'date_modified', 'dateModified');
    _renameKey(result, 'creation_date', 'creationDate');
    _renameKey(result, 'modified_date', 'modifiedDate');
    _renameKey(result, 'creation_time', 'creationTime');
    _renameKey(result, 'modified_time', 'modifiedTime');

    switch (dataType.toUpperCase()) {
      case 'CONTACT':
      case 'CONTACTS':
        _renameKey(result, 'telephone_number', 'telephoneNumber');
        // Wrap single telephone_number into phoneNumbers list if needed
        if (result['telephoneNumber'] != null &&
            result['phoneNumbers'] == null) {
          result['phoneNumbers'] = [result['telephoneNumber']];
        }
        break;

      case 'PHONE_CALL':
      case 'CALL':
        _renameKey(result, 'call_direction', 'callDirection');
        _renameKey(result, 'with_contact', 'contactName');
        _renameKey(result, 'start_time', 'startTime');
        _renameKey(result, 'end_time', 'endTime');
        // Map callDirection values to callType for existing code
        if (result['callDirection'] != null && result['callType'] == null) {
          result['callType'] = result['callDirection'];
        }
        break;

      case 'CALENDAR':
      case 'CALENDAR_EVENT':
      case 'EVENT':
        _renameKey(result, 'recurrence_info', 'recurrenceInfo');
        _renameKey(result, 'repeat_frequency', 'repeatFrequency');
        _renameKey(result, 'start_time', 'startTime');
        _renameKey(result, 'end_time', 'endTime');
        // Flatten Python nested metadata into top-level if present
        if (result['metadata'] is Map<String, dynamic>) {
          final meta = result['metadata'] as Map<String, dynamic>;
          result['label'] ??= meta['label'];
          result['date'] ??= meta['date'];
          result['startTime'] ??= meta['start_time'] ?? meta['startTime'];
          result['endTime'] ??= meta['end_time'] ?? meta['endTime'];
          result['repeatFrequency'] ??=
              meta['repeat_frequency'] ?? meta['repeatFrequency'];
          result['on'] ??= meta['on'];
        }
        break;

      case 'PHOTO':
      case 'PHOTOS':
        // Python uses 'path', Dart uses 'filename'
        if (result['path'] != null && result['filename'] == null) {
          // Extract filename from path
          final path = result['path'].toString();
          final filename =
              path.contains('/') ? path.split('/').last : path;
          result['filename'] = filename;
          result['filePath'] = path;
        }
        break;

      case 'NOTE':
      case 'NOTES':
        _renameKey(result, 'date_created', 'dateCreated');
        _renameKey(result, 'date_modified', 'dateModified');
        break;

      case 'ALARM':
      case 'ALARMS':
        _renameKey(result, 'recurrence_type', 'recurrenceType');
        _renameKey(result, 'repeat_frequency', 'repeatFrequency');
        // Flatten nested metadata
        if (result['metadata'] is Map<String, dynamic>) {
          final meta = result['metadata'] as Map<String, dynamic>;
          result['label'] ??= meta['label'];
          result['date'] ??= meta['date'];
          result['time'] ??= meta['time'];
          result['repeatFrequency'] ??=
              meta['repeat_frequency'] ?? meta['repeatFrequency'];
          result['on'] ??= meta['on'];
        }
        break;
    }

    return result;
  }

  static void _renameKey(
    Map<String, dynamic> map,
    String oldKey,
    String newKey,
  ) {
    if (map.containsKey(oldKey) && !map.containsKey(newKey)) {
      map[newKey] = map[oldKey];
    }
  }
}

// ---------------------------------------------------------------------------
// Note Payload
// ---------------------------------------------------------------------------

/// Metadata for a note, separating date and time components.
class NoteMetadata {
  final String? creationDate;
  final String? modifiedDate;
  final String? creationTime;
  final String? modifiedTime;
  final String? title;

  const NoteMetadata({
    this.creationDate,
    this.modifiedDate,
    this.creationTime,
    this.modifiedTime,
    this.title,
  });

  factory NoteMetadata.fromMap(Map<String, dynamic> map) {
    return NoteMetadata(
      creationDate: map['creationDate'] ?? map['creation_date'],
      modifiedDate: map['modifiedDate'] ?? map['modified_date'],
      creationTime: map['creationTime'] ?? map['creation_time'],
      modifiedTime: map['modifiedTime'] ?? map['modified_time'],
      title: map['title'],
    );
  }

  Map<String, dynamic> toMap() => {
        if (creationDate != null) 'creationDate': creationDate,
        if (modifiedDate != null) 'modifiedDate': modifiedDate,
        if (creationTime != null) 'creationTime': creationTime,
        if (modifiedTime != null) 'modifiedTime': modifiedTime,
        if (title != null) 'title': title,
      };
}

/// Normalized note payload for entity extraction.
class NotePayload {
  final String note; // ID
  final String? title;
  final String text;
  final String? dateCreated;
  final String? dateModified;
  final String? sourceApp;

  const NotePayload({
    required this.note,
    this.title,
    required this.text,
    this.dateCreated,
    this.dateModified,
    this.sourceApp,
  });

  factory NotePayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'NOTE');
    return NotePayload(
      note: normalized['note'] ?? normalized['id'] ?? '',
      title: normalized['title'],
      text: normalized['text'] ?? normalized['content'] ?? '',
      dateCreated: normalized['dateCreated'],
      dateModified: normalized['dateModified'],
      sourceApp: normalized['sourceApp'],
    );
  }

  /// Create from the example app's note creation flow.
  factory NotePayload.fromUserInput({
    required String title,
    required String content,
    String? sourceApp,
  }) {
    final now = DateTime.now();
    return NotePayload(
      note: '${title.hashCode}_${now.millisecondsSinceEpoch}',
      title: title,
      text: content,
      dateCreated: now.toIso8601String(),
      dateModified: now.toIso8601String(),
      sourceApp: sourceApp ?? 'user_input',
    );
  }

  NoteMetadata toMetadata() {
    String? creationDate;
    String? creationTime;
    String? modifiedDate;
    String? modifiedTime;

    if (dateCreated != null) {
      final parts = dateCreated!.split('T');
      creationDate = parts[0];
      if (parts.length > 1) creationTime = parts[1];
    }
    if (dateModified != null) {
      final parts = dateModified!.split('T');
      modifiedDate = parts[0];
      if (parts.length > 1) modifiedTime = parts[1];
    }

    return NoteMetadata(
      creationDate: creationDate,
      modifiedDate: modifiedDate,
      creationTime: creationTime,
      modifiedTime: modifiedTime,
      title: title,
    );
  }

  Map<String, dynamic> toMap() => {
        'note': note,
        'id': note,
        if (title != null) 'title': title,
        'text': text,
        'content': text,
        if (dateCreated != null) 'dateCreated': dateCreated,
        if (dateModified != null) 'dateModified': dateModified,
        if (sourceApp != null) 'sourceApp': sourceApp,
      };
}

// ---------------------------------------------------------------------------
// Alarm Payload
// ---------------------------------------------------------------------------

/// Metadata for a single-occurrence alarm.
class SingleAlarmMetadata {
  final String label;
  final String date;
  final String time;

  const SingleAlarmMetadata({
    required this.label,
    required this.date,
    required this.time,
  });

  factory SingleAlarmMetadata.fromMap(Map<String, dynamic> map) {
    return SingleAlarmMetadata(
      label: map['label'] ?? '',
      date: map['date'] ?? '',
      time: map['time'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'date': date,
        'time': time,
      };
}

/// Metadata for a recurrent alarm.
class RecurrentAlarmMetadata {
  final String label;
  final String time;
  final String repeatFrequency;
  final String on;

  const RecurrentAlarmMetadata({
    required this.label,
    required this.time,
    required this.repeatFrequency,
    required this.on,
  });

  factory RecurrentAlarmMetadata.fromMap(Map<String, dynamic> map) {
    return RecurrentAlarmMetadata(
      label: map['label'] ?? '',
      time: map['time'] ?? '',
      repeatFrequency: map['repeatFrequency'] ?? map['repeat_frequency'] ?? '',
      on: map['on'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'time': time,
        'repeatFrequency': repeatFrequency,
        'on': on,
      };
}

/// Canonical alarm payload (single or recurrent).
class AlarmPayload {
  final String alarm; // ID
  final String sourceApp;
  final String recurrenceType; // 'single-occurrence' | 'recurrent'
  final String label;
  final String time;
  final String? date; // Only for single-occurrence
  final String? repeatFrequency; // Only for recurrent
  final String? on; // Only for recurrent

  const AlarmPayload({
    required this.alarm,
    this.sourceApp = 'alarm',
    required this.recurrenceType,
    required this.label,
    required this.time,
    this.date,
    this.repeatFrequency,
    this.on,
  });

  bool get isRecurrent => recurrenceType == 'recurrent';

  factory AlarmPayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'ALARM');
    return AlarmPayload(
      alarm: normalized['alarm'] ?? normalized['id'] ?? '',
      sourceApp: normalized['sourceApp'] ?? 'alarm',
      recurrenceType:
          normalized['recurrenceType'] ?? 'single-occurrence',
      label: normalized['label'] ?? '',
      time: normalized['time'] ?? '',
      date: normalized['date'],
      repeatFrequency: normalized['repeatFrequency'],
      on: normalized['on'],
    );
  }

  /// Create from the example app's alarm creation dialog.
  factory AlarmPayload.fromUserInput({
    required String label,
    required String time,
    String? date,
    String? repeatFrequency,
    String? on,
  }) {
    final isRecurrent =
        repeatFrequency != null && repeatFrequency.isNotEmpty;
    final id =
        '${isRecurrent ? "recurrentAlarm" : "alarm"}_${label.hashCode}_${DateTime.now().millisecondsSinceEpoch}';
    return AlarmPayload(
      alarm: id,
      sourceApp: 'user_input',
      recurrenceType:
          isRecurrent ? 'recurrent' : 'single-occurrence',
      label: label,
      time: time,
      date: date,
      repeatFrequency: repeatFrequency,
      on: on,
    );
  }

  Map<String, dynamic> toMap() => {
        'alarm': alarm,
        'id': alarm,
        'sourceApp': sourceApp,
        'recurrenceType': recurrenceType,
        'label': label,
        'time': time,
        if (date != null) 'date': date,
        if (repeatFrequency != null) 'repeatFrequency': repeatFrequency,
        if (on != null) 'on': on,
      };

  /// Human-readable description for embedding.
  String toDescription() {
    if (isRecurrent) {
      final onStr = on != null && on!.isNotEmpty ? ' on $on' : '';
      return 'Recurring alarm: $label at $time, ${repeatFrequency ?? ""}$onStr';
    } else {
      return 'Alarm: $label on ${date ?? "unknown date"} at $time';
    }
  }
}

// ---------------------------------------------------------------------------
// Phone Call Payload
// ---------------------------------------------------------------------------

/// Normalized phone call payload.
class PhoneCallPayload {
  final String call; // ID
  final String sourceApp;
  final String? date;
  final String? startTime;
  final String? endTime;
  final String? duration;
  final String callDirection; // 'incoming' | 'outgoing' | 'missed'
  final String? withContact;
  final String? phoneNumber;

  const PhoneCallPayload({
    required this.call,
    this.sourceApp = 'system_calls',
    this.date,
    this.startTime,
    this.endTime,
    this.duration,
    required this.callDirection,
    this.withContact,
    this.phoneNumber,
  });

  factory PhoneCallPayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'PHONE_CALL');
    return PhoneCallPayload(
      call: normalized['call'] ?? normalized['id'] ?? '',
      sourceApp: normalized['sourceApp'] ?? 'system_calls',
      date: normalized['date'],
      startTime: normalized['startTime'],
      endTime: normalized['endTime'],
      duration: normalized['duration']?.toString(),
      callDirection: _normalizeCallDirection(
        normalized['callDirection'] ?? normalized['callType'],
      ),
      withContact: normalized['contactName'] ?? normalized['with_contact'],
      phoneNumber: normalized['phoneNumber'],
    );
  }

  /// Create from the native [PhoneCall]-like map produced by `_itemToMap`.
  factory PhoneCallPayload.fromNativeMap(Map<String, dynamic> map) {
    final timestamp = map['timestamp'];
    final durationSecs = map['duration'];

    String? date;
    String? startTime;
    String? endTime;

    if (timestamp != null) {
      final dt = timestamp is int
          ? DateTime.fromMillisecondsSinceEpoch(timestamp)
          : DateTime.tryParse(timestamp.toString());
      if (dt != null) {
        date = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
        startTime =
            '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        if (durationSecs != null) {
          final endDt = dt.add(Duration(seconds: int.tryParse(durationSecs.toString()) ?? 0));
          endTime =
              '${endDt.hour.toString().padLeft(2, '0')}:${endDt.minute.toString().padLeft(2, '0')}';
        }
      }
    }

    return PhoneCallPayload(
      call: map['id']?.toString() ?? '',
      sourceApp: map['sourceApp']?.toString() ?? 'system_calls',
      date: date,
      startTime: startTime,
      endTime: endTime,
      duration: _formatDuration(durationSecs),
      callDirection: _normalizeCallDirection(map['callType']),
      withContact: map['contactName']?.toString(),
      phoneNumber: map['phoneNumber']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'call': call,
        'id': call,
        'sourceApp': sourceApp,
        if (date != null) 'date': date,
        if (startTime != null) 'startTime': startTime,
        if (endTime != null) 'endTime': endTime,
        if (duration != null) 'duration': duration,
        'callDirection': callDirection,
        if (withContact != null) 'contactName': withContact,
        if (phoneNumber != null) 'phoneNumber': phoneNumber,
      };

  static String _normalizeCallDirection(dynamic value) {
    if (value == null) return 'unknown';
    final str = value.toString().toLowerCase();
    if (str.contains('incoming')) return 'incoming';
    if (str.contains('outgoing')) return 'outgoing';
    if (str.contains('missed')) return 'missed';
    if (str.contains('rejected')) return 'rejected';
    return str;
  }

  static String _formatDuration(dynamic seconds) {
    if (seconds == null) return '0s';
    final secs = int.tryParse(seconds.toString()) ?? 0;
    if (secs < 60) return '${secs}s';
    if (secs < 3600) return '${secs ~/ 60}m ${secs % 60}s';
    return '${secs ~/ 3600}h ${(secs % 3600) ~/ 60}m';
  }
}

// ---------------------------------------------------------------------------
// Event Payload
// ---------------------------------------------------------------------------

/// Metadata for a single-occurrence calendar event.
class SingleEventMetadata {
  final String label;
  final String date;
  final String startTime;
  final String endTime;

  const SingleEventMetadata({
    required this.label,
    required this.date,
    required this.startTime,
    required this.endTime,
  });

  factory SingleEventMetadata.fromMap(Map<String, dynamic> map) {
    return SingleEventMetadata(
      label: map['label'] ?? map['title'] ?? '',
      date: map['date'] ?? '',
      startTime: map['startTime'] ?? map['start_time'] ?? '',
      endTime: map['endTime'] ?? map['end_time'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'date': date,
        'startTime': startTime,
        'endTime': endTime,
      };
}

/// Metadata for a recurring calendar event.
class RecurrentEventMetadata {
  final String label;
  final String startTime;
  final String endTime;
  final String repeatFrequency;
  final String on;

  const RecurrentEventMetadata({
    required this.label,
    required this.startTime,
    required this.endTime,
    required this.repeatFrequency,
    required this.on,
  });

  factory RecurrentEventMetadata.fromMap(Map<String, dynamic> map) {
    return RecurrentEventMetadata(
      label: map['label'] ?? map['title'] ?? '',
      startTime: map['startTime'] ?? map['start_time'] ?? '',
      endTime: map['endTime'] ?? map['end_time'] ?? '',
      repeatFrequency: map['repeatFrequency'] ?? map['repeat_frequency'] ?? '',
      on: map['on'] ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'startTime': startTime,
        'endTime': endTime,
        'repeatFrequency': repeatFrequency,
        'on': on,
      };
}

/// Normalized calendar event payload.
class EventPayload {
  final String event; // ID
  final String sourceApp;
  final String recurrenceInfo; // 'single-occurrence' | 'recurrent'
  final String title;
  final String? location;
  final String? notes;
  final String? startDate;
  final String? endDate;
  final List<String> attendees;
  final String? repeatFrequency;
  final String? on;

  const EventPayload({
    required this.event,
    this.sourceApp = 'system_calendar',
    required this.recurrenceInfo,
    required this.title,
    this.location,
    this.notes,
    this.startDate,
    this.endDate,
    this.attendees = const [],
    this.repeatFrequency,
    this.on,
  });

  bool get isRecurrent => recurrenceInfo == 'recurrent';

  factory EventPayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'EVENT');
    return EventPayload(
      event: normalized['event'] ?? normalized['id'] ?? '',
      sourceApp: normalized['sourceApp'] ?? 'system_calendar',
      recurrenceInfo:
          normalized['recurrenceInfo'] ?? 'single-occurrence',
      title: normalized['title'] ??
          normalized['label'] ??
          normalized['summary'] ??
          '',
      location: normalized['location'],
      notes: normalized['notes'] ?? normalized['description'],
      startDate: normalized['startDate']?.toString(),
      endDate: normalized['endDate']?.toString(),
      attendees: _parseAttendees(normalized['attendees']),
      repeatFrequency: normalized['repeatFrequency'],
      on: normalized['on'],
    );
  }

  /// Create from a native CalendarEvent-like map produced by `_itemToMap`.
  factory EventPayload.fromNativeMap(Map<String, dynamic> map) {
    // Parse recurrence from RRULE if present
    final rrule = map['recurrenceRule'];
    final isRecurring = map['isRecurring'] == true ||
        (rrule != null && rrule.toString().isNotEmpty);

    String? repeatFrequency;
    String? onValue;

    if (isRecurring && rrule != null) {
      final parsed = RRuleParser.parse(rrule.toString());
      repeatFrequency = parsed['frequency'];
      onValue = parsed['on'];
    }

    return EventPayload(
      event: map['id']?.toString() ?? '',
      sourceApp: map['sourceApp']?.toString() ?? 'system_calendar',
      recurrenceInfo:
          isRecurring ? 'recurrent' : 'single-occurrence',
      title: map['title']?.toString() ?? '',
      location: map['location']?.toString(),
      notes: map['notes']?.toString(),
      startDate: map['startDate']?.toString(),
      endDate: map['endDate']?.toString(),
      attendees: _parseAttendees(map['attendees']),
      repeatFrequency: repeatFrequency,
      on: onValue,
    );
  }

  Map<String, dynamic> toMap() => {
        'event': event,
        'id': event,
        'sourceApp': sourceApp,
        'recurrenceInfo': recurrenceInfo,
        'title': title,
        if (location != null) 'location': location,
        if (notes != null) 'notes': notes,
        if (startDate != null) 'startDate': startDate,
        if (endDate != null) 'endDate': endDate,
        if (attendees.isNotEmpty) 'attendees': attendees,
        if (repeatFrequency != null) 'repeatFrequency': repeatFrequency,
        if (on != null) 'on': on,
      };

  static List<String> _parseAttendees(dynamic value) {
    if (value == null) return [];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [];
  }
}

// ---------------------------------------------------------------------------
// Contact Payload
// ---------------------------------------------------------------------------

/// Normalized contact payload.
class ContactPayload {
  final String contact; // ID
  final String sourceApp;
  final String name;
  final List<String> phoneNumbers;
  final List<String> emailAddresses;
  final String? organization;
  final String? jobTitle;

  const ContactPayload({
    required this.contact,
    this.sourceApp = 'system_contacts',
    required this.name,
    this.phoneNumbers = const [],
    this.emailAddresses = const [],
    this.organization,
    this.jobTitle,
  });

  factory ContactPayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'CONTACT');
    return ContactPayload(
      contact: normalized['contact'] ?? normalized['id'] ?? '',
      sourceApp: normalized['sourceApp'] ?? 'system_contacts',
      name: normalized['fullName'] ??
          normalized['name'] ??
          '${normalized['givenName'] ?? ''} ${normalized['familyName'] ?? ''}'
              .trim(),
      phoneNumbers: _parseStringList(
        normalized['phoneNumbers'] ?? normalized['telephoneNumber'],
      ),
      emailAddresses: _parseStringList(normalized['emailAddresses']),
      organization:
          normalized['organization'] ?? normalized['organizationName'],
      jobTitle: normalized['jobTitle'],
    );
  }

  Map<String, dynamic> toMap() => {
        'contact': contact,
        'id': contact,
        'sourceApp': sourceApp,
        'fullName': name,
        'name': name,
        if (phoneNumbers.isNotEmpty) 'phoneNumbers': phoneNumbers,
        if (emailAddresses.isNotEmpty) 'emailAddresses': emailAddresses,
        if (organization != null) 'organizationName': organization,
        if (jobTitle != null) 'jobTitle': jobTitle,
      };

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return [];
    if (value is String) return [value];
    if (value is List) return value.map((e) => e.toString()).toList();
    return [];
  }
}

// ---------------------------------------------------------------------------
// Photo Payload
// ---------------------------------------------------------------------------

/// Normalized photo payload.
class PhotoPayload {
  final String photo; // ID
  final String sourceApp;
  final String? path;
  final String? filename;
  final String? creationDate;
  final String? creationTime;
  final String? location;
  final double? latitude;
  final double? longitude;

  const PhotoPayload({
    required this.photo,
    this.sourceApp = 'system_photos',
    this.path,
    this.filename,
    this.creationDate,
    this.creationTime,
    this.location,
    this.latitude,
    this.longitude,
  });

  factory PhotoPayload.fromMap(Map<String, dynamic> map) {
    final normalized = PayloadFieldNormalizer.normalize(map, 'PHOTO');
    return PhotoPayload(
      photo: normalized['photo'] ?? normalized['id'] ?? '',
      sourceApp: normalized['sourceApp'] ?? 'system_photos',
      path: normalized['filePath'] ?? normalized['path'],
      filename: normalized['filename'],
      creationDate: normalized['creationDate']?.toString(),
      creationTime: normalized['creationTime']?.toString(),
      location: normalized['locationName'] ?? normalized['location'],
      latitude: _parseDouble(normalized['latitude']),
      longitude: _parseDouble(normalized['longitude']),
    );
  }

  Map<String, dynamic> toMap() => {
        'photo': photo,
        'id': photo,
        'sourceApp': sourceApp,
        if (path != null) 'path': path,
        if (filename != null) 'filename': filename,
        if (creationDate != null) 'creationDate': creationDate,
        if (creationTime != null) 'creationTime': creationTime,
        if (location != null) 'locationName': location,
        if (latitude != null) 'latitude': latitude,
        if (longitude != null) 'longitude': longitude,
      };

  static double? _parseDouble(dynamic value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

// ---------------------------------------------------------------------------
// RRULE Parser
// ---------------------------------------------------------------------------

/// Utility to parse RRULE strings into human-readable recurrence info.
///
/// Supports common patterns from iOS EventKit and Android ContentProvider:
///   `RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR`
///   `RRULE:FREQ=MONTHLY;BYMONTHDAY=15`
///   `RRULE:FREQ=YEARLY;BYMONTH=9;BYMONTHDAY=11`
class RRuleParser {
  static const _weekdayNames = {
    'MO': 'Monday',
    'TU': 'Tuesday',
    'WE': 'Wednesday',
    'TH': 'Thursday',
    'FR': 'Friday',
    'SA': 'Saturday',
    'SU': 'Sunday',
  };

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// Parse an RRULE string into `{'frequency': '...', 'on': '...'}`.
  static Map<String, String?> parse(String rrule) {
    // Strip "RRULE:" prefix if present
    final rule = rrule.startsWith('RRULE:')
        ? rrule.substring(6)
        : rrule;

    final parts = <String, String>{};
    for (final segment in rule.split(';')) {
      final kv = segment.split('=');
      if (kv.length == 2) {
        parts[kv[0].toUpperCase()] = kv[1];
      }
    }

    final freq = (parts['FREQ'] ?? '').toLowerCase();
    String? onValue;

    switch (freq) {
      case 'daily':
        onValue = 'every day';
        break;
      case 'weekly':
        final byDay = parts['BYDAY'];
        if (byDay != null) {
          final days = byDay
              .split(',')
              .map((d) => _weekdayNames[d.trim().toUpperCase()] ?? d)
              .toList();
          onValue = days.join(', ');
        }
        break;
      case 'monthly':
        final byMonthDay = parts['BYMONTHDAY'];
        final byDay = parts['BYDAY'];
        if (byMonthDay != null) {
          onValue = _ordinal(int.tryParse(byMonthDay) ?? 0);
        } else if (byDay != null) {
          // e.g., "2TU" = second Tuesday
          final match = RegExp(r'(-?\d+)?(\w{2})').firstMatch(byDay);
          if (match != null) {
            final pos = match.group(1);
            final day =
                _weekdayNames[match.group(2)?.toUpperCase()] ?? byDay;
            if (pos == '-1') {
              onValue = 'last $day';
            } else if (pos != null) {
              onValue = '${_ordinal(int.tryParse(pos) ?? 0)} $day';
            } else {
              onValue = day;
            }
          }
        }
        break;
      case 'yearly':
        final byMonth = parts['BYMONTH'];
        final byMonthDay = parts['BYMONTHDAY'];
        if (byMonth != null && byMonthDay != null) {
          final monthIdx = int.tryParse(byMonth);
          if (monthIdx != null && monthIdx >= 1 && monthIdx <= 12) {
            onValue =
                '${byMonthDay.padLeft(2, '0')}-${_monthNames[monthIdx - 1]}';
          }
        }
        break;
    }

    return {
      'frequency': freq.isNotEmpty ? freq : null,
      'on': onValue,
    };
  }

  static String _ordinal(int n) {
    if (n <= 0) return n.toString();
    if (n >= 11 && n <= 13) return '${n}th';
    switch (n % 10) {
      case 1:
        return '${n}st';
      case 2:
        return '${n}nd';
      case 3:
        return '${n}rd';
      default:
        return '${n}th';
    }
  }
}
