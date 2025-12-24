import 'dart:async';

import 'graph_repository.dart';
import 'entity_extractor.dart';

/// Data source types for the personal knowledge graph
class DataSourceTypes {
  static const String contact = 'CONTACT';
  static const String calendar = 'CALENDAR';
  static const String document = 'DOCUMENT';
  static const String photo = 'PHOTO';
  static const String phoneCall = 'PHONE_CALL';
  static const String note = 'NOTE';
  
  static const List<String> all = [
    contact, calendar, document, photo, phoneCall, note,
  ];
}

/// The central "You" entity that connects all personal data
class YouEntity {
  /// The fixed ID for the "You" entity
  static const String id = 'you_central_node';
  
  /// The display name
  static const String name = 'You';
  
  /// The entity type
  static const String type = 'SELF';
  
  /// Create the GraphEntity for "You"
  static GraphEntity create({List<double>? embedding}) {
    return GraphEntity(
      id: id,
      name: name,
      type: type,
      embedding: embedding,
      description: 'The central node representing you - connects all your personal data',
      metadata: {
        'isGlobalNode': true,
        'dataFamilies': DataSourceTypes.all,
      },
      lastModified: DateTime.now(),
    );
  }
}

/// Relationship types from "You" to data families
class YouRelationshipTypes {
  /// You -> Contact: You know this person
  static const String knows = 'KNOWS';
  
  /// You -> Calendar Event: You have/attended this event
  static const String hasEvent = 'HAS_EVENT';
  
  /// You -> Document: You own/created this document
  static const String ownsDocument = 'OWNS_DOCUMENT';
  
  /// You -> Photo: You have/took this photo
  static const String hasPhoto = 'HAS_PHOTO';
  
  /// You -> Phone Call: You made/received this call
  static const String madeCall = 'MADE_CALL';
  
  /// You -> Note: You wrote this note
  static const String wroteNote = 'WROTE_NOTE';
  
  /// Generic relationship for data ownership
  static const String owns = 'OWNS';
  
  /// Get the appropriate relationship type for a data source
  static String forDataSource(String dataSourceType) {
    switch (dataSourceType.toUpperCase()) {
      case 'CONTACT':
      case 'CONTACTS':
        return knows;
      case 'CALENDAR':
      case 'CALENDAR_EVENT':
      case 'EVENT':
        return hasEvent;
      case 'DOCUMENT':
      case 'DOCUMENTS':
      case 'DRIVE':
        return ownsDocument;
      case 'PHOTO':
      case 'PHOTOS':
        return hasPhoto;
      case 'PHONE_CALL':
      case 'PHONE_CALLS':
      case 'CALL':
      case 'CALLS':
        return madeCall;
      case 'NOTE':
      case 'NOTES':
        return wroteNote;
      default:
        return owns;
    }
  }
}

/// Configuration for link prediction
class LinkPredictionConfig {
  /// Time window for temporal proximity (co-occurrence)
  final Duration temporalWindow;
  
  /// Minimum co-occurrence count to create a link
  final int minCoOccurrenceCount;
  
  /// Weight for co-occurrence based links
  final double coOccurrenceWeight;
  
  /// Weight for template-based links (deterministic)
  final double templateWeight;
  
  /// Enable temporal proximity linking
  final bool enableTemporalLinks;
  
  /// Enable co-mention pattern detection
  final bool enableCoMentionLinks;
  
  /// Enable template-based inference
  final bool enableTemplateLinks;

  LinkPredictionConfig({
    this.temporalWindow = const Duration(hours: 2),
    this.minCoOccurrenceCount = 2,
    this.coOccurrenceWeight = 0.7,
    this.templateWeight = 1.0,
    this.enableTemporalLinks = true,
    this.enableCoMentionLinks = true,
    this.enableTemplateLinks = true,
  });
}

/// Predicted link between entities
class PredictedLink {
  final String sourceEntityId;
  final String targetEntityId;
  final String relationshipType;
  final double confidence;
  final String predictionMethod;
  final Map<String, dynamic>? evidence;

  PredictedLink({
    required this.sourceEntityId,
    required this.targetEntityId,
    required this.relationshipType,
    required this.confidence,
    required this.predictionMethod,
    this.evidence,
  });

  /// Convert to GraphRelationship
  GraphRelationship toRelationship() {
    return GraphRelationship(
      id: '${sourceEntityId}_${relationshipType}_$targetEntityId',
      sourceId: sourceEntityId,
      targetId: targetEntityId,
      type: relationshipType,
      weight: confidence,
      metadata: {
        'predictionMethod': predictionMethod,
        if (evidence != null) 'evidence': evidence,
      },
    );
  }
}

/// Link prediction engine for personal knowledge graphs
class LinkPredictor {
  final GraphRepository repository;
  final LinkPredictionConfig config;

  LinkPredictor({
    required this.repository,
    LinkPredictionConfig? config,
  }) : config = config ?? LinkPredictionConfig();

  /// Ensure the "You" entity exists in the graph
  Future<void> ensureYouEntityExists({
    Future<List<double>> Function(String text)? embeddingCallback,
  }) async {
    final existing = await repository.getEntity(YouEntity.id);
    if (existing == null) {
      List<double>? embedding;
      if (embeddingCallback != null) {
        embedding = await embeddingCallback(
          'Central user node representing the owner of this personal data',
        );
      }
      await repository.addEntity(YouEntity.create(embedding: embedding));
      print('[LinkPredictor] Created "You" central entity');
    }
  }

  /// Create a link from "You" to an entity based on data source type
  Future<PredictedLink?> linkToYou({
    required String entityId,
    required String dataSourceType,
  }) async {
    // Verify the entity exists
    final entity = await repository.getEntity(entityId);
    if (entity == null) return null;
    
    final relationshipType = YouRelationshipTypes.forDataSource(dataSourceType);
    
    return PredictedLink(
      sourceEntityId: YouEntity.id,
      targetEntityId: entityId,
      relationshipType: relationshipType,
      confidence: config.templateWeight,
      predictionMethod: 'template_you_link',
      evidence: {
        'dataSourceType': dataSourceType,
        'entityType': entity.type,
      },
    );
  }

  /// Run template-based inference for a contact
  List<PredictedLink> inferFromContact(Map<String, dynamic> contact) {
    final links = <PredictedLink>[];
    
    final personId = _generateEntityId(
      contact['fullName'] ?? contact['name'] ?? '',
      'PERSON',
    );
    final orgName = contact['organization'] ?? contact['organizationName'];
    
    // If person works at an organization
    if (orgName != null && orgName.toString().isNotEmpty) {
      final orgId = _generateEntityId(orgName.toString(), 'ORGANIZATION');
      links.add(PredictedLink(
        sourceEntityId: personId,
        targetEntityId: orgId,
        relationshipType: RelationshipTypes.worksAt,
        confidence: config.templateWeight,
        predictionMethod: 'template_contact_org',
        evidence: {'organizationName': orgName},
      ));
    }
    
    return links;
  }

  /// Run template-based inference for a calendar event
  List<PredictedLink> inferFromCalendarEvent(Map<String, dynamic> event) {
    final links = <PredictedLink>[];
    
    final eventId = _generateEntityId(
      event['title'] ?? event['summary'] ?? '',
      'EVENT',
    );
    final location = event['location'];
    final attendees = event['attendees'] as List<dynamic>?;
    
    // Event at location
    if (location != null && location.toString().isNotEmpty) {
      final locationId = _generateEntityId(location.toString(), 'LOCATION');
      links.add(PredictedLink(
        sourceEntityId: eventId,
        targetEntityId: locationId,
        relationshipType: RelationshipTypes.locatedIn,
        confidence: config.templateWeight,
        predictionMethod: 'template_event_location',
        evidence: {'location': location},
      ));
    }
    
    // Attendees of event
    if (attendees != null) {
      for (final attendee in attendees) {
        final attendeeStr = attendee.toString();
        if (attendeeStr.isNotEmpty) {
          final attendeeId = _generateEntityId(attendeeStr, 'PERSON');
          links.add(PredictedLink(
            sourceEntityId: attendeeId,
            targetEntityId: eventId,
            relationshipType: RelationshipTypes.attendedBy,
            confidence: config.templateWeight,
            predictionMethod: 'template_event_attendee',
            evidence: {'attendee': attendeeStr},
          ));
        }
      }
    }
    
    return links;
  }

  /// Run template-based inference for a phone call
  List<PredictedLink> inferFromPhoneCall(Map<String, dynamic> call) {
    final links = <PredictedLink>[];
    
    final callId = call['id'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    final contactName = call['contactName'] ?? call['name'];
    final phoneNumber = call['phoneNumber'] ?? call['number'];
    final callType = call['callType'] ?? call['type']; // incoming, outgoing, missed
    
    // Link call to contact/person
    if (contactName != null && contactName.toString().isNotEmpty) {
      final personId = _generateEntityId(contactName.toString(), 'PERSON');
      final relType = callType == 'incoming' ? 'RECEIVED_CALL_FROM' : 'CALLED';
      links.add(PredictedLink(
        sourceEntityId: YouEntity.id,
        targetEntityId: personId,
        relationshipType: relType,
        confidence: config.templateWeight,
        predictionMethod: 'template_call_contact',
        evidence: {
          'callId': callId,
          'callType': callType,
          if (phoneNumber != null) 'phoneNumber': phoneNumber,
        },
      ));
    }
    
    return links;
  }

  /// Run template-based inference for a photo
  List<PredictedLink> inferFromPhoto(Map<String, dynamic> photo) {
    final links = <PredictedLink>[];
    
    final photoId = _generateEntityId(
      photo['id'] ?? photo['name'] ?? '',
      'PHOTO',
    );
    final location = photo['location'] ?? photo['gpsLocation'];
    final people = photo['people'] ?? photo['faces'] as List<dynamic>?;
    final dateTaken = photo['dateTaken'] ?? photo['timestamp'];
    
    // Photo at location
    if (location != null && location.toString().isNotEmpty) {
      final locationId = _generateEntityId(location.toString(), 'LOCATION');
      links.add(PredictedLink(
        sourceEntityId: photoId,
        targetEntityId: locationId,
        relationshipType: 'TAKEN_AT',
        confidence: config.templateWeight,
        predictionMethod: 'template_photo_location',
        evidence: {'location': location},
      ));
    }
    
    // People in photo
    if (people != null) {
      for (final person in people) {
        final personStr = person.toString();
        if (personStr.isNotEmpty) {
          final personId = _generateEntityId(personStr, 'PERSON');
          links.add(PredictedLink(
            sourceEntityId: personId,
            targetEntityId: photoId,
            relationshipType: 'PICTURED_IN',
            confidence: config.templateWeight,
            predictionMethod: 'template_photo_person',
            evidence: {'person': personStr},
          ));
        }
      }
    }
    
    // Link photo to date if available
    if (dateTaken != null) {
      final dateStr = _formatDateForEntity(dateTaken);
      if (dateStr.isNotEmpty) {
        final dateId = _generateEntityId(dateStr, 'DATE');
        links.add(PredictedLink(
          sourceEntityId: photoId,
          targetEntityId: dateId,
          relationshipType: 'TAKEN_ON',
          confidence: config.templateWeight,
          predictionMethod: 'template_photo_date',
          evidence: {'date': dateStr},
        ));
      }
    }
    
    return links;
  }

  /// Run template-based inference for a document
  List<PredictedLink> inferFromDocument(Map<String, dynamic> document) {
    final links = <PredictedLink>[];
    
    final docId = _generateEntityId(
      document['id'] ?? document['name'] ?? document['title'] ?? '',
      'DOCUMENT',
    );
    final owner = document['owner'] ?? document['author'] ?? document['createdBy'];
    final sharedWith = document['sharedWith'] ?? document['collaborators'] as List<dynamic>?;
    final folder = document['folder'] ?? document['parent'];
    
    // Document created by owner
    if (owner != null && owner.toString().isNotEmpty) {
      final ownerId = _generateEntityId(owner.toString(), 'PERSON');
      links.add(PredictedLink(
        sourceEntityId: docId,
        targetEntityId: ownerId,
        relationshipType: RelationshipTypes.createdBy,
        confidence: config.templateWeight,
        predictionMethod: 'template_doc_owner',
        evidence: {'owner': owner},
      ));
    }
    
    // Document shared with people
    if (sharedWith != null) {
      for (final person in sharedWith) {
        final personStr = person.toString();
        if (personStr.isNotEmpty) {
          final personId = _generateEntityId(personStr, 'PERSON');
          links.add(PredictedLink(
            sourceEntityId: docId,
            targetEntityId: personId,
            relationshipType: 'SHARED_WITH',
            confidence: config.templateWeight,
            predictionMethod: 'template_doc_shared',
            evidence: {'sharedWith': personStr},
          ));
        }
      }
    }
    
    // Document in folder/project
    if (folder != null && folder.toString().isNotEmpty) {
      final folderId = _generateEntityId(folder.toString(), 'PROJECT');
      links.add(PredictedLink(
        sourceEntityId: docId,
        targetEntityId: folderId,
        relationshipType: RelationshipTypes.partOf,
        confidence: config.templateWeight,
        predictionMethod: 'template_doc_folder',
        evidence: {'folder': folder},
      ));
    }
    
    return links;
  }

  /// Run template-based inference for a note
  List<PredictedLink> inferFromNote(Map<String, dynamic> note) {
    final links = <PredictedLink>[];
    
    final noteId = _generateEntityId(
      note['id'] ?? note['title'] ?? '',
      'NOTE',
    );
    final folder = note['folder'] ?? note['notebook'];
    final tags = note['tags'] as List<dynamic>?;
    
    // Note in folder/notebook
    if (folder != null && folder.toString().isNotEmpty) {
      final folderId = _generateEntityId(folder.toString(), 'PROJECT');
      links.add(PredictedLink(
        sourceEntityId: noteId,
        targetEntityId: folderId,
        relationshipType: RelationshipTypes.partOf,
        confidence: config.templateWeight,
        predictionMethod: 'template_note_folder',
        evidence: {'folder': folder},
      ));
    }
    
    // Note with tags/topics
    if (tags != null) {
      for (final tag in tags) {
        final tagStr = tag.toString();
        if (tagStr.isNotEmpty) {
          final tagId = _generateEntityId(tagStr, 'TOPIC');
          links.add(PredictedLink(
            sourceEntityId: noteId,
            targetEntityId: tagId,
            relationshipType: 'TAGGED_WITH',
            confidence: config.templateWeight,
            predictionMethod: 'template_note_tag',
            evidence: {'tag': tagStr},
          ));
        }
      }
    }
    
    return links;
  }

  /// Get template-based inference for any data type
  List<PredictedLink> inferFromStructured(
    Map<String, dynamic> data,
    String dataSourceType,
  ) {
    if (!config.enableTemplateLinks) return [];
    
    switch (dataSourceType.toUpperCase()) {
      case 'CONTACT':
      case 'CONTACTS':
        return inferFromContact(data);
      case 'CALENDAR':
      case 'CALENDAR_EVENT':
      case 'EVENT':
        return inferFromCalendarEvent(data);
      case 'PHONE_CALL':
      case 'PHONE_CALLS':
      case 'CALL':
      case 'CALLS':
        return inferFromPhoneCall(data);
      case 'PHOTO':
      case 'PHOTOS':
        return inferFromPhoto(data);
      case 'DOCUMENT':
      case 'DOCUMENTS':
      case 'DRIVE':
        return inferFromDocument(data);
      case 'NOTE':
      case 'NOTES':
        return inferFromNote(data);
      default:
        return [];
    }
  }

  /// Detect co-mentions across data sources
  /// 
  /// Looks for entities that appear together in multiple items
  /// and creates MENTIONED_WITH relationships
  Future<List<PredictedLink>> detectCoMentions({
    required List<ExtractionResult> extractions,
    int minOccurrences = 2,
  }) async {
    if (!config.enableCoMentionLinks) return [];
    
    // Build co-occurrence matrix
    // Key: "entityA_entityB" (sorted), Value: list of source IDs where they co-occur
    final coOccurrences = <String, List<String>>{};
    
    for (final extraction in extractions) {
      final entityIds = extraction.entities.map((e) {
        return _generateEntityId(e.name, e.type);
      }).toList();
      
      // For each pair of entities in this extraction
      for (var i = 0; i < entityIds.length; i++) {
        for (var j = i + 1; j < entityIds.length; j++) {
          // Create sorted key to avoid duplicates
          final pair = [entityIds[i], entityIds[j]]..sort();
          final key = '${pair[0]}_${pair[1]}';
          
          coOccurrences.putIfAbsent(key, () => []);
          coOccurrences[key]!.add(extraction.sourceId);
        }
      }
    }
    
    // Create links for pairs that co-occur frequently
    final links = <PredictedLink>[];
    final threshold = minOccurrences > 0 ? minOccurrences : config.minCoOccurrenceCount;
    
    for (final entry in coOccurrences.entries) {
      if (entry.value.length >= threshold) {
        final parts = entry.key.split('_');
        if (parts.length >= 2) {
          final entityA = parts[0];
          final entityB = parts.sublist(1).join('_');
          
          // Calculate confidence based on co-occurrence count
          final confidence = (entry.value.length / extractions.length)
              .clamp(0.0, 1.0) * config.coOccurrenceWeight;
          
          links.add(PredictedLink(
            sourceEntityId: entityA,
            targetEntityId: entityB,
            relationshipType: 'MENTIONED_WITH',
            confidence: confidence,
            predictionMethod: 'co_mention',
            evidence: {
              'coOccurrenceCount': entry.value.length,
              'sources': entry.value.take(5).toList(), // First 5 sources
            },
          ));
        }
      }
    }
    
    return links;
  }

  /// Detect temporal proximity between events/items
  /// 
  /// Items that occur close in time may be related
  Future<List<PredictedLink>> detectTemporalProximity({
    required List<Map<String, dynamic>> timedItems,
    required String dataSourceType,
  }) async {
    if (!config.enableTemporalLinks) return [];
    
    final links = <PredictedLink>[];
    
    // Sort items by timestamp
    final sortedItems = List<Map<String, dynamic>>.from(timedItems);
    sortedItems.sort((a, b) {
      final aTime = _extractTimestamp(a);
      final bTime = _extractTimestamp(b);
      if (aTime == null || bTime == null) return 0;
      return aTime.compareTo(bTime);
    });
    
    // Find items within temporal window
    for (var i = 0; i < sortedItems.length; i++) {
      final itemA = sortedItems[i];
      final timeA = _extractTimestamp(itemA);
      if (timeA == null) continue;
      
      for (var j = i + 1; j < sortedItems.length; j++) {
        final itemB = sortedItems[j];
        final timeB = _extractTimestamp(itemB);
        if (timeB == null) continue;
        
        final difference = timeB.difference(timeA);
        if (difference > config.temporalWindow) break; // Items are sorted, no need to check further
        
        // Create temporal proximity link
        final idA = _getItemId(itemA, dataSourceType);
        final idB = _getItemId(itemB, dataSourceType);
        
        // Calculate confidence based on time proximity
        final maxMillis = config.temporalWindow.inMilliseconds;
        final actualMillis = difference.inMilliseconds;
        final confidence = (1 - actualMillis / maxMillis) * config.coOccurrenceWeight;
        
        links.add(PredictedLink(
          sourceEntityId: idA,
          targetEntityId: idB,
          relationshipType: 'TEMPORALLY_PROXIMATE',
          confidence: confidence,
          predictionMethod: 'temporal_proximity',
          evidence: {
            'timeDifferenceMinutes': difference.inMinutes,
            'timeA': timeA.toIso8601String(),
            'timeB': timeB.toIso8601String(),
          },
        ));
      }
    }
    
    return links;
  }

  /// Infer colleague relationships from shared organization
  Future<List<PredictedLink>> inferColleagueRelationships() async {
    final links = <PredictedLink>[];
    
    // Get all people and their organizations
    final people = await repository.getEntitiesByType('PERSON');
    final personToOrg = <String, List<String>>{};
    
    for (final person in people) {
      final relationships = await repository.getRelationships(person.id);
      for (final rel in relationships) {
        if (rel.type == 'WORKS_AT' || rel.type == 'WORKS_FOR') {
          personToOrg.putIfAbsent(person.id, () => []);
          personToOrg[person.id]!.add(rel.targetId);
        }
      }
    }
    
    // Find people who share organizations
    final orgToPeople = <String, List<String>>{};
    for (final entry in personToOrg.entries) {
      for (final orgId in entry.value) {
        orgToPeople.putIfAbsent(orgId, () => []);
        orgToPeople[orgId]!.add(entry.key);
      }
    }
    
    // Create colleague relationships
    for (final entry in orgToPeople.entries) {
      final colleagues = entry.value;
      if (colleagues.length > 1) {
        for (var i = 0; i < colleagues.length; i++) {
          for (var j = i + 1; j < colleagues.length; j++) {
            links.add(PredictedLink(
              sourceEntityId: colleagues[i],
              targetEntityId: colleagues[j],
              relationshipType: RelationshipTypes.colleagueOf,
              confidence: config.templateWeight * 0.8,
              predictionMethod: 'inferred_colleague',
              evidence: {'sharedOrganization': entry.key},
            ));
          }
        }
      }
    }
    
    return links;
  }

  /// Store predicted links in the repository
  Future<int> storePredictedLinks(List<PredictedLink> links) async {
    var stored = 0;
    
    for (final link in links) {
      try {
        // Check if both entities exist
        final source = await repository.getEntity(link.sourceEntityId);
        final target = await repository.getEntity(link.targetEntityId);
        
        if (source != null && target != null) {
          await repository.addRelationship(link.toRelationship());
          stored++;
        }
      } catch (e) {
        // Relationship might already exist, ignore
        assert(() {
          print('[LinkPredictor] Failed to store link: $e');
          return true;
        }());
      }
    }
    
    return stored;
  }

  // Helper methods
  
  String _generateEntityId(String name, String type) {
    final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final typePrefix = type.isNotEmpty ? '${type.toLowerCase()}_' : '';
    return '$typePrefix$normalized';
  }

  DateTime? _extractTimestamp(Map<String, dynamic> item) {
    final possibleFields = ['timestamp', 'date', 'startDate', 'createdAt', 'dateTaken'];
    for (final field in possibleFields) {
      final value = item[field];
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) {
        try {
          return DateTime.parse(value);
        } catch (_) {}
      }
    }
    return null;
  }

  String _getItemId(Map<String, dynamic> item, String dataSourceType) {
    final id = item['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString();
    final name = item['name'] ?? item['title'] ?? id;
    return _generateEntityId(name.toString(), dataSourceType);
  }

  String _formatDateForEntity(dynamic date) {
    DateTime? dt;
    if (date is DateTime) {
      dt = date;
    } else if (date is int) {
      dt = DateTime.fromMillisecondsSinceEpoch(date);
    } else if (date is String) {
      try {
        dt = DateTime.parse(date);
      } catch (_) {}
    }
    
    if (dt != null) {
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    return '';
  }
}

/// Extension for batch link prediction
extension LinkPredictorBatch on LinkPredictor {
  /// Process a batch of items and predict links
  Future<List<PredictedLink>> processBatch({
    required List<Map<String, dynamic>> items,
    required String dataSourceType,
    required List<ExtractionResult> extractions,
    bool includeYouLinks = true,
  }) async {
    final allLinks = <PredictedLink>[];
    
    // 1. Ensure "You" entity exists
    if (includeYouLinks) {
      await ensureYouEntityExists();
    }
    
    // 2. Template-based inference for each item
    for (final item in items) {
      final templateLinks = inferFromStructured(item, dataSourceType);
      allLinks.addAll(templateLinks);
    }
    
    // 3. Detect co-mentions from extractions
    if (extractions.isNotEmpty) {
      final coMentionLinks = await detectCoMentions(extractions: extractions);
      allLinks.addAll(coMentionLinks);
    }
    
    // 4. Detect temporal proximity
    final timedItems = items.where((item) {
      return _extractTimestamp(item) != null;
    }).toList();
    
    if (timedItems.isNotEmpty) {
      final temporalLinks = await detectTemporalProximity(
        timedItems: timedItems,
        dataSourceType: dataSourceType,
      );
      allLinks.addAll(temporalLinks);
    }
    
    return allLinks;
  }

  DateTime? _extractTimestamp(Map<String, dynamic> item) {
    final possibleFields = ['timestamp', 'date', 'startDate', 'createdAt', 'dateTaken'];
    for (final field in possibleFields) {
      final value = item[field];
      if (value is DateTime) return value;
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) {
        try {
          return DateTime.parse(value);
        } catch (_) {}
      }
    }
    return null;
  }
}
