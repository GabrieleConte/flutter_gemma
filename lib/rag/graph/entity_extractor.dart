import 'dart:async';
import 'dart:convert';

/// Extraction result containing entities and relationships
class ExtractionResult {
  final List<ExtractedEntity> entities;
  final List<ExtractedRelationship> relationships;
  final String sourceId;
  final String sourceType;

  ExtractionResult({
    required this.entities,
    required this.relationships,
    required this.sourceId,
    required this.sourceType,
  });
}

/// Entity extracted from text using LLM
class ExtractedEntity {
  final String name;
  final String type;
  final String? description;
  final Map<String, dynamic>? attributes;
  final double confidence;

  ExtractedEntity({
    required this.name,
    required this.type,
    this.description,
    this.attributes,
    this.confidence = 1.0,
  });

  factory ExtractedEntity.fromJson(Map<String, dynamic> json) {
    // Handle various key names that LLMs might produce
    final name = json['name'] as String? 
        ?? json['entity'] as String?
        ?? json['entity_name'] as String?
        ?? json['label'] as String?
        ?? '';
    final type = json['type'] as String? 
        ?? json['entity_type'] as String?
        ?? json['category'] as String?
        ?? 'UNKNOWN';
    return ExtractedEntity(
      name: name,
      type: type.toUpperCase(),
      description: json['description'] as String?,
      attributes: json['attributes'] as Map<String, dynamic>?,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'description': description,
    'attributes': attributes,
    'confidence': confidence,
  };
}

/// Relationship extracted between entities using LLM
class ExtractedRelationship {
  final String sourceEntity;
  final String targetEntity;
  final String type;
  final String? description;
  final double weight;
  final double confidence;

  ExtractedRelationship({
    required this.sourceEntity,
    required this.targetEntity,
    required this.type,
    this.description,
    this.weight = 1.0,
    this.confidence = 1.0,
  });

  factory ExtractedRelationship.fromJson(Map<String, dynamic> json) {
    // Handle various key names that LLMs might produce
    final source = json['source'] as String? 
        ?? json['sourceEntity'] as String? 
        ?? json['entity1'] as String?
        ?? json['from'] as String?
        ?? json['subject'] as String?
        ?? '';
    final target = json['target'] as String? 
        ?? json['targetEntity'] as String? 
        ?? json['entity2'] as String?
        ?? json['to'] as String?
        ?? json['object'] as String?
        ?? '';
    final type = json['type'] as String? 
        ?? json['relationship'] as String? 
        ?? json['relation'] as String?
        ?? json['relationship_type'] as String?
        ?? 'RELATED_TO';
    return ExtractedRelationship(
      sourceEntity: source,
      targetEntity: target,
      type: type.toUpperCase().replaceAll(' ', '_'),
      description: json['description'] as String?,
      weight: (json['weight'] as num?)?.toDouble() ?? 1.0,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
    );
  }

  Map<String, dynamic> toJson() => {
    'source': sourceEntity,
    'target': targetEntity,
    'type': type,
    'description': description,
    'weight': weight,
    'confidence': confidence,
  };
}

/// Entity types supported by the extractor
class EntityTypes {
  static const String person = 'PERSON';
  static const String organization = 'ORGANIZATION';
  static const String location = 'LOCATION';
  static const String event = 'EVENT';
  static const String date = 'DATE';
  static const String project = 'PROJECT';
  static const String document = 'DOCUMENT';
  static const String email = 'EMAIL';
  static const String phone = 'PHONE';
  static const String skill = 'SKILL';
  static const String topic = 'TOPIC';
  
  static const List<String> all = [
    person, organization, location, event, date,
    project, document, email, phone, skill, topic,
  ];
}

/// Relationship types for entity connections
class RelationshipTypes {
  static const String worksAt = 'WORKS_AT';
  static const String worksFor = 'WORKS_FOR';
  static const String colleagueOf = 'COLLEAGUE_OF';
  static const String knows = 'KNOWS';
  static const String attendedBy = 'ATTENDED_BY';
  static const String locatedIn = 'LOCATED_IN';
  static const String partOf = 'PART_OF';
  static const String createdBy = 'CREATED_BY';
  static const String ownedBy = 'OWNED_BY';
  static const String mentionedIn = 'MENTIONED_IN';
  static const String relatedTo = 'RELATED_TO';
  static const String hasSkill = 'HAS_SKILL';
  static const String interestedIn = 'INTERESTED_IN';
  static const String contactOf = 'CONTACT_OF';
  static const String scheduledFor = 'SCHEDULED_FOR';
}

/// Configuration for entity extraction
class EntityExtractionConfig {
  /// Minimum confidence score to accept an entity
  final double minEntityConfidence;
  
  /// Minimum confidence score to accept a relationship
  final double minRelationshipConfidence;
  
  /// Entity types to extract
  final List<String> entityTypes;
  
  /// Maximum entities per extraction
  final int maxEntities;
  
  /// Maximum relationships per extraction
  final int maxRelationships;
  
  /// Enable coreference resolution (merge references to same entity)
  final bool resolveCoreferences;

  EntityExtractionConfig({
    this.minEntityConfidence = 0.7,
    this.minRelationshipConfidence = 0.6,
    this.entityTypes = const [],
    this.maxEntities = 50,
    this.maxRelationships = 100,
    this.resolveCoreferences = true,
  });
}

/// Interface for LLM-based entity extraction
abstract class EntityExtractor {
  /// Extract entities and relationships from text
  Future<ExtractionResult> extractFromText(
    String text, {
    required String sourceId,
    required String sourceType,
  });

  /// Extract entities from structured data (contacts, events, etc.)
  Future<ExtractionResult> extractFromStructured(
    Map<String, dynamic> data, {
    required String sourceId,
    required String sourceType,
  });

  /// Generate entity embedding using the embedding model
  Future<List<double>> generateEmbedding(String text);
}

/// Prompt templates for entity extraction
class ExtractionPrompts {
  static String entityExtractionPrompt(
    String text, 
    List<String> entityTypes,
  ) {
    final typesStr = entityTypes.isEmpty 
        ? EntityTypes.all.join(', ')
        : entityTypes.join(', ');
    
    return '''Extract named entities and their relationships from the following text.

Entity Types to extract: $typesStr

For each entity, provide:
- name: The entity's name
- type: One of the entity types listed above
- description: A brief description if available

For each relationship, provide:
- source: Source entity name
- target: Target entity name
- type: Relationship type (e.g., WORKS_AT, KNOWS, LOCATED_IN, PART_OF, etc.)

Return the results as JSON in this format:
{
  "entities": [
    {"name": "...", "type": "...", "description": "..."}
  ],
  "relationships": [
    {"source": "...", "target": "...", "type": "..."}
  ]
}

Text to analyze:
"""
$text
"""

JSON output:''';
  }

  static String contactExtractionPrompt(Map<String, dynamic> contact) {
    final name = contact['fullName'] ?? contact['name'] ?? 'Unknown';
    final org = contact['organization'] ?? contact['organizationName'] ?? '';
    final job = contact['jobTitle'] ?? '';
    final emails = (contact['emailAddresses'] as List?)?.join(', ') ?? '';
    final phones = (contact['phoneNumbers'] as List?)?.join(', ') ?? '';
    final note = contact['note'] ?? '';

    return '''Extract entities and relationships from this contact.

Contact:
Name: $name
Organization: $org
Job: $job
Email: $emails
Phone: $phones
Notes: $note

Return JSON with this exact format:
{"entities":[{"name":"PersonName","type":"PERSON"},{"name":"CompanyName","type":"ORGANIZATION"}],"relationships":[{"source":"PersonName","target":"CompanyName","type":"WORKS_AT"}]}

Your JSON:''';
  }

  static String eventExtractionPrompt(Map<String, dynamic> event) {
    final title = event['title'] ?? event['summary'] ?? 'Untitled Event';
    final location = event['location'] ?? '';
    final description = event['notes'] ?? event['description'] ?? '';
    final attendees = (event['attendees'] as List?)?.join(', ') ?? '';
    final startDate = event['startDate'] ?? event['start'] ?? '';
    final endDate = event['endDate'] ?? event['end'] ?? '';

    // Build a more explicit prompt that ensures location is extracted
    final locationInstruction = location.toString().isNotEmpty
        ? '\nIMPORTANT: Extract "$location" as a LOCATION entity and link it to the event with LOCATED_IN.'
        : '';

    return '''Extract entities from this calendar event.

Title: $title
Location: $location
Description: $description
Attendees: $attendees
Date: $startDate to $endDate
$locationInstruction
Required extractions:
1. The event itself (type: EVENT)
2. Each attendee as PERSON
3. The location as LOCATION (if present)

Return JSON:
{"entities":[{"name":"Event Name","type":"EVENT"},{"name":"Location Name","type":"LOCATION"},{"name":"Person","type":"PERSON"}],"relationships":[{"source":"Event Name","target":"Location Name","type":"LOCATED_IN"},{"source":"Person","target":"Event Name","type":"ATTENDS"}]}

Your JSON:''';
  }

  static String communitySummaryPrompt(
    List<String> entityNames,
    List<String> entityDescriptions,
    List<String> relationships,
  ) {
    return '''Generate a comprehensive summary for a community of related entities.

Entities in this community:
${entityNames.asMap().entries.map((e) => '- ${e.value}: ${entityDescriptions.length > e.key ? entityDescriptions[e.key] : ""}').join('\n')}

Relationships:
${relationships.map((r) => '- $r').join('\n')}

Write a coherent summary (2-3 paragraphs) that:
1. Identifies the main theme or connection between these entities
2. Describes the key relationships and interactions
3. Highlights any notable patterns or important details

Summary:''';
  }

  /// Prompt for hierarchical community summaries (higher-level communities)
  /// Following the GraphRAG paper approach: summarize child community summaries
  static String hierarchicalCommunitySummaryPrompt(
    List<String> childSummaries,
    int level,
  ) {
    return '''You are creating a summary of a high-level community that contains multiple sub-communities.

This is a Level $level community. Synthesize the following sub-community summaries into a coherent high-level summary.

Sub-community summaries:
${childSummaries.asMap().entries.map((e) => '--- Sub-community ${e.key + 1} ---\n${e.value}').join('\n\n')}

Write a unified summary (2-3 paragraphs) that:
1. Identifies the overarching theme connecting all sub-communities
2. Highlights the most important patterns and relationships at this higher level
3. Provides a birds-eye view useful for understanding the entire group

High-level Summary:''';
  }
}

/// LLM-based entity extractor implementation
class LLMEntityExtractor implements EntityExtractor {
  /// Callback to send text to LLM and get response
  final Future<String> Function(String prompt) llmCallback;
  
  /// Callback to generate embeddings
  final Future<List<double>> Function(String text) embeddingCallback;
  
  /// Configuration
  final EntityExtractionConfig config;

  LLMEntityExtractor({
    required this.llmCallback,
    required this.embeddingCallback,
    EntityExtractionConfig? config,
  }) : config = config ?? EntityExtractionConfig();

  @override
  Future<ExtractionResult> extractFromText(
    String text, {
    required String sourceId,
    required String sourceType,
  }) async {
    if (text.trim().isEmpty) {
      return ExtractionResult(
        entities: [],
        relationships: [],
        sourceId: sourceId,
        sourceType: sourceType,
      );
    }

    final prompt = ExtractionPrompts.entityExtractionPrompt(
      text,
      config.entityTypes,
    );
    
    final response = await llmCallback(prompt);
    final parsed = _parseExtractionResponse(response);
    
    return ExtractionResult(
      entities: parsed.entities
          .where((e) => e.confidence >= config.minEntityConfidence)
          .take(config.maxEntities)
          .toList(),
      relationships: parsed.relationships
          .where((r) => r.confidence >= config.minRelationshipConfidence)
          .take(config.maxRelationships)
          .toList(),
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  @override
  Future<ExtractionResult> extractFromStructured(
    Map<String, dynamic> data, {
    required String sourceId,
    required String sourceType,
  }) async {
    String prompt;
    
    switch (sourceType.toLowerCase()) {
      case 'contact':
      case 'contacts':
        prompt = ExtractionPrompts.contactExtractionPrompt(data);
        break;
      case 'event':
      case 'calendar':
      case 'calendar_event':
        prompt = ExtractionPrompts.eventExtractionPrompt(data);
        break;
      default:
        // Generic extraction from data
        prompt = ExtractionPrompts.entityExtractionPrompt(
          _structuredDataToText(data),
          config.entityTypes,
        );
    }
    
    final response = await llmCallback(prompt);
    final parsed = _parseExtractionResponse(response);
    
    return ExtractionResult(
      entities: parsed.entities
          .where((e) => e.confidence >= config.minEntityConfidence)
          .take(config.maxEntities)
          .toList(),
      relationships: parsed.relationships
          .where((r) => r.confidence >= config.minRelationshipConfidence)
          .take(config.maxRelationships)
          .toList(),
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  @override
  Future<List<double>> generateEmbedding(String text) async {
    return await embeddingCallback(text);
  }

  /// Parse LLM response into extraction result
  _ParsedExtraction _parseExtractionResponse(String response) {
    try {
      // Try to extract JSON from response
      final jsonStr = _extractJson(response);
      
      // Debug: Log extracted JSON
      assert(() {
        print('[EntityExtractor] Extracted JSON: ${jsonStr.length > 500 ? "${jsonStr.substring(0, 500)}..." : jsonStr}');
        return true;
      }());
      
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      final entitiesJson = json['entities'] as List<dynamic>? ?? [];
      final relationshipsJson = json['relationships'] as List<dynamic>? ?? [];
      
      // Debug: Log parsed counts
      assert(() {
        print('[EntityExtractor] Found ${entitiesJson.length} entity entries, ${relationshipsJson.length} relationship entries');
        return true;
      }());
      
      final entities = entitiesJson
          .map((e) {
            try {
              return ExtractedEntity.fromJson(e as Map<String, dynamic>);
            } catch (err) {
              assert(() {
                print('[EntityExtractor] Error parsing entity: $e -> $err');
                return true;
              }());
              return null;
            }
          })
          .whereType<ExtractedEntity>()
          .where((e) => e.name.isNotEmpty)
          .toList();
      
      final relationships = relationshipsJson
          .map((r) {
            try {
              return ExtractedRelationship.fromJson(r as Map<String, dynamic>);
            } catch (err) {
              assert(() {
                print('[EntityExtractor] Error parsing relationship: $r -> $err');
                return true;
              }());
              return null;
            }
          })
          .whereType<ExtractedRelationship>()
          .where((r) => r.sourceEntity.isNotEmpty && r.targetEntity.isNotEmpty)
          .toList();
      
      // Debug: Log final counts
      assert(() {
        print('[EntityExtractor] Parsed ${entities.length} entities, ${relationships.length} relationships');
        if (entities.isNotEmpty) {
          print('[EntityExtractor] First entity: ${entities.first.name} (${entities.first.type})');
        }
        return true;
      }());
      
      return _ParsedExtraction(entities: entities, relationships: relationships);
    } catch (e) {
      // If parsing fails, try a more lenient approach
      assert(() {
        print('[EntityExtractor] JSON parsing failed: $e');
        print('[EntityExtractor] Response preview: ${response.length > 200 ? "${response.substring(0, 200)}..." : response}');
        return true;
      }());
      return _fallbackParsing(response);
    }
  }

  /// Extract JSON from response that might contain extra text or markdown
  String _extractJson(String response) {
    var text = response;
    
    // Remove markdown code blocks if present
    if (text.contains('```json')) {
      final jsonStart = text.indexOf('```json');
      final jsonEnd = text.indexOf('```', jsonStart + 7);
      if (jsonEnd > jsonStart) {
        text = text.substring(jsonStart + 7, jsonEnd).trim();
      } else {
        // No closing ```, take everything after ```json
        text = text.substring(jsonStart + 7).trim();
      }
    } else if (text.contains('```')) {
      // Generic code block
      final codeStart = text.indexOf('```');
      final codeEnd = text.indexOf('```', codeStart + 3);
      if (codeEnd > codeStart) {
        text = text.substring(codeStart + 3, codeEnd).trim();
      } else {
        // No closing ```, take everything after ```
        text = text.substring(codeStart + 3).trim();
      }
    }
    
    // Find the first {
    final start = text.indexOf('{');
    
    if (start >= 0) {
      // Extract from first { to end and always try to repair
      // This handles truncated JSON where lastIndexOf('}') finds a nested }
      final jsonPart = text.substring(start);
      final repaired = _repairTruncatedJson(jsonPart);
      return repaired;
    }
    
    throw const FormatException('No JSON found in response');
  }
  
  /// Try to repair truncated JSON by adding missing closing brackets
  String _repairTruncatedJson(String partialJson) {
    var result = partialJson.trim();
    
    // Count open brackets
    var openBraces = 0;
    var openBrackets = 0;
    var inString = false;
    var escape = false;
    
    for (var i = 0; i < result.length; i++) {
      final char = result[i];
      
      if (escape) {
        escape = false;
        continue;
      }
      
      if (char == '\\') {
        escape = true;
        continue;
      }
      
      if (char == '"') {
        inString = !inString;
        continue;
      }
      
      if (inString) continue;
      
      if (char == '{') openBraces++;
      if (char == '}') openBraces--;
      if (char == '[') openBrackets++;
      if (char == ']') openBrackets--;
    }
    
    // If we're in a string, close it
    if (inString) {
      result += '"';
    }
    
    // If last character is a comma or colon, remove it
    result = result.trimRight();
    if (result.endsWith(',') || result.endsWith(':')) {
      result = result.substring(0, result.length - 1);
    }
    
    // Add missing closing brackets
    result += ']' * openBrackets;
    result += '}' * openBraces;
    
    assert(() {
      print('[EntityExtractor] Repaired JSON: added $openBrackets ] and $openBraces }');
      return true;
    }());
    
    return result;
  }

  /// Fallback parsing for non-JSON or malformed JSON responses
  _ParsedExtraction _fallbackParsing(String response) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];
    
    // Try to extract partial JSON - look for individual entity objects
    final entityPattern = RegExp(
      r'\{"name"\s*:\s*"([^"]+)"\s*,\s*"type"\s*:\s*"([^"]+)"',
      caseSensitive: false,
    );
    
    // Collect entity names for relationship validation
    final entityNames = <String>{};
    
    for (final match in entityPattern.allMatches(response)) {
      final name = match.group(1) ?? '';
      final type = match.group(2) ?? 'UNKNOWN';
      if (name.isNotEmpty && name.length > 1 && !name.contains('+39')) {
        entities.add(ExtractedEntity(
          name: name,
          type: type.toUpperCase(),
          confidence: 0.7,
        ));
        entityNames.add(name.toLowerCase());
      }
    }
    
    // Try to extract relationships - only keep those referencing found entities
    // Also track seen relationships to avoid duplicates from hallucinated JSON
    final relPattern = RegExp(
      r'\{"source"\s*:\s*"([^"]+)"\s*,\s*"target"\s*:\s*"([^"]+)"\s*,\s*"type"\s*:\s*"([^"]+)"',
      caseSensitive: false,
    );
    
    final seenRelationships = <String>{}; // Track unique relationships
    
    for (final match in relPattern.allMatches(response)) {
      final source = match.group(1) ?? '';
      final target = match.group(2) ?? '';
      final type = match.group(3) ?? 'RELATED_TO';
      if (source.isNotEmpty && target.isNotEmpty) {
        // Only add relationship if BOTH entities were actually extracted
        // This prevents orphan relationships from truncated JSON
        final sourceFound = entityNames.contains(source.toLowerCase());
        final targetFound = entityNames.contains(target.toLowerCase());
        
        if (sourceFound && targetFound) {
          // Create a unique key to detect duplicates
          final relKey = '${source.toLowerCase()}|${target.toLowerCase()}|${type.toLowerCase()}';
          if (!seenRelationships.contains(relKey)) {
            seenRelationships.add(relKey);
            relationships.add(ExtractedRelationship(
              sourceEntity: source,
              targetEntity: target,
              type: type.toUpperCase().replaceAll(' ', '_'),
              confidence: 0.7,
            ));
          }
        } else {
          assert(() {
            print('[EntityExtractor] Fallback: Skipping orphan relationship $source -> $target (source found: $sourceFound, target found: $targetFound)');
            return true;
          }());
        }
      }
    }
    
    // If still no entities, fallback to capitalized word extraction
    if (entities.isEmpty) {
      final namePattern = RegExp(r'\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b');
      final seenNames = <String>{};
      for (final match in namePattern.allMatches(response)) {
        final name = match.group(1)!;
        if (!seenNames.contains(name.toLowerCase()) && name.length > 2) {
          seenNames.add(name.toLowerCase());
          entities.add(ExtractedEntity(
            name: name,
            type: EntityTypes.person,
            confidence: 0.5,
          ));
        }
      }
    }
    
    assert(() {
      print('[EntityExtractor] Fallback parsed ${entities.length} entities, ${relationships.length} relationships');
      return true;
    }());
    
    return _ParsedExtraction(entities: entities, relationships: relationships);
  }

  /// Convert structured data to text for generic extraction
  String _structuredDataToText(Map<String, dynamic> data) {
    final buffer = StringBuffer();
    
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      
      if (value == null) continue;
      
      if (value is List) {
        if (value.isNotEmpty) {
          buffer.writeln('$key: ${value.join(', ')}');
        }
      } else if (value is Map) {
        buffer.writeln('$key: ${jsonEncode(value)}');
      } else {
        buffer.writeln('$key: $value');
      }
    }
    
    return buffer.toString();
  }
}

/// Helper class for parsed extraction results
class _ParsedExtraction {
  final List<ExtractedEntity> entities;
  final List<ExtractedRelationship> relationships;

  _ParsedExtraction({
    required this.entities,
    required this.relationships,
  });
}

/// Direct entity extractor that extracts from structured data without LLM
/// 
/// This extractor is much faster than LLM-based extraction and should be used
/// for structured data sources like contacts, calendar events, photos, and calls.
/// It deterministically extracts entities from known fields.
class DirectEntityExtractor implements EntityExtractor {
  /// Callback to generate embeddings (still needed for entity embeddings)
  final Future<List<double>> Function(String text) embeddingCallback;
  
  /// Configuration
  final EntityExtractionConfig config;

  DirectEntityExtractor({
    required this.embeddingCallback,
    EntityExtractionConfig? config,
  }) : config = config ?? EntityExtractionConfig();

  @override
  Future<ExtractionResult> extractFromText(
    String text, {
    required String sourceId,
    required String sourceType,
  }) async {
    // Direct extractor doesn't handle free text - return empty result
    // Use LLMEntityExtractor for text extraction
    return ExtractionResult(
      entities: [],
      relationships: [],
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  @override
  Future<ExtractionResult> extractFromStructured(
    Map<String, dynamic> data, {
    required String sourceId,
    required String sourceType,
  }) async {
    switch (sourceType.toLowerCase()) {
      case 'contact':
      case 'contacts':
        return _extractFromContact(data, sourceId, sourceType);
      case 'event':
      case 'calendar':
      case 'calendar_event':
        return _extractFromCalendarEvent(data, sourceId, sourceType);
      case 'photo':
      case 'photos':
        return _extractFromPhoto(data, sourceId, sourceType);
      case 'phone_call':
      case 'phone_calls':
      case 'call':
      case 'calls':
        return _extractFromPhoneCall(data, sourceId, sourceType);
      default:
        // For unknown types, return empty - use LLM extractor instead
        return ExtractionResult(
          entities: [],
          relationships: [],
          sourceId: sourceId,
          sourceType: sourceType,
        );
    }
  }

  @override
  Future<List<double>> generateEmbedding(String text) async {
    return await embeddingCallback(text);
  }

  /// Extract entities from a contact
  ExtractionResult _extractFromContact(
    Map<String, dynamic> contact,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    // Extract person entity
    final fullName = contact['fullName'] ?? contact['name'];
    final givenName = contact['givenName'];
    final familyName = contact['familyName'];
    
    String personName = '';
    if (fullName != null && fullName.toString().isNotEmpty) {
      personName = fullName.toString();
    } else if (givenName != null || familyName != null) {
      personName = '${givenName ?? ''} ${familyName ?? ''}'.trim();
    }

    if (personName.isNotEmpty) {
      final jobTitle = contact['jobTitle']?.toString();
      final note = contact['note']?.toString();
      
      entities.add(ExtractedEntity(
        name: personName,
        type: EntityTypes.person,
        description: jobTitle ?? note,
        attributes: {
          if (contact['emailAddresses'] != null) 
            'emails': contact['emailAddresses'],
          if (contact['phoneNumbers'] != null) 
            'phones': contact['phoneNumbers'],
          if (jobTitle != null) 'jobTitle': jobTitle,
        },
        confidence: 1.0, // Deterministic extraction
      ));
    }

    // Extract organization entity if present
    final orgName = contact['organization'] ?? contact['organizationName'];
    if (orgName != null && orgName.toString().isNotEmpty) {
      entities.add(ExtractedEntity(
        name: orgName.toString(),
        type: EntityTypes.organization,
        confidence: 1.0,
      ));

      // Create WORKS_AT relationship
      if (personName.isNotEmpty) {
        relationships.add(ExtractedRelationship(
          sourceEntity: personName,
          targetEntity: orgName.toString(),
          type: RelationshipTypes.worksAt,
          confidence: 1.0,
        ));
      }
    }

    return ExtractionResult(
      entities: entities,
      relationships: relationships,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Extract entities from a calendar event
  ExtractionResult _extractFromCalendarEvent(
    Map<String, dynamic> event,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    // Extract event entity
    final title = event['title'] ?? event['summary'];
    if (title != null && title.toString().isNotEmpty) {
      final eventName = title.toString();
      final notes = event['notes'] ?? event['description'];
      final startDate = event['startDate'] ?? event['start'];
      final endDate = event['endDate'] ?? event['end'];
      
      entities.add(ExtractedEntity(
        name: eventName,
        type: EntityTypes.event,
        description: notes?.toString(),
        attributes: {
          if (startDate != null) 'startDate': startDate.toString(),
          if (endDate != null) 'endDate': endDate.toString(),
        },
        confidence: 1.0,
      ));

      // Extract location if present
      final location = event['location'];
      if (location != null && location.toString().isNotEmpty) {
        entities.add(ExtractedEntity(
          name: location.toString(),
          type: EntityTypes.location,
          confidence: 1.0,
        ));

        relationships.add(ExtractedRelationship(
          sourceEntity: eventName,
          targetEntity: location.toString(),
          type: RelationshipTypes.locatedIn,
          confidence: 1.0,
        ));
      }

      // Extract attendees as person entities
      final attendees = event['attendees'] as List<dynamic>?;
      if (attendees != null) {
        for (final attendee in attendees) {
          final attendeeStr = attendee.toString();
          if (attendeeStr.isNotEmpty) {
            entities.add(ExtractedEntity(
              name: attendeeStr,
              type: EntityTypes.person,
              confidence: 0.9, // Slightly lower - might be email addresses
            ));

            relationships.add(ExtractedRelationship(
              sourceEntity: attendeeStr,
              targetEntity: eventName,
              type: RelationshipTypes.attendedBy,
              confidence: 1.0,
            ));
          }
        }
      }
    }

    return ExtractionResult(
      entities: entities,
      relationships: relationships,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Extract entities from a photo
  ExtractionResult _extractFromPhoto(
    Map<String, dynamic> photo,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    // Extract photo entity
    final photoId = photo['id'] ?? photo['name'] ?? photo['filename'];
    final filename = photo['filename'] ?? photo['name'];
    
    if (photoId != null) {
      final photoName = filename?.toString() ?? photoId.toString();
      final creationDate = photo['creationDate'] ?? photo['dateTaken'] ?? photo['timestamp'];
      final width = photo['width'];
      final height = photo['height'];
      
      entities.add(ExtractedEntity(
        name: photoName,
        type: 'PHOTO',
        attributes: {
          if (creationDate != null) 'creationDate': creationDate.toString(),
          if (width != null) 'width': width,
          if (height != null) 'height': height,
          if (photo['mediaType'] != null) 'mediaType': photo['mediaType'],
        },
        confidence: 1.0,
      ));

      // Extract location if present
      final locationName = photo['locationName'] ?? photo['location'];
      final latitude = photo['latitude'];
      final longitude = photo['longitude'];
      
      if (locationName != null && locationName.toString().isNotEmpty) {
        entities.add(ExtractedEntity(
          name: locationName.toString(),
          type: EntityTypes.location,
          attributes: {
            if (latitude != null) 'latitude': latitude,
            if (longitude != null) 'longitude': longitude,
          },
          confidence: 1.0,
        ));

        relationships.add(ExtractedRelationship(
          sourceEntity: photoName,
          targetEntity: locationName.toString(),
          type: 'TAKEN_AT',
          confidence: 1.0,
        ));
      } else if (latitude != null && longitude != null) {
        // Create a generic location entity from coordinates
        final coordLocation = 'Location ($latitude, $longitude)';
        entities.add(ExtractedEntity(
          name: coordLocation,
          type: EntityTypes.location,
          attributes: {
            'latitude': latitude,
            'longitude': longitude,
          },
          confidence: 0.8,
        ));

        relationships.add(ExtractedRelationship(
          sourceEntity: photoName,
          targetEntity: coordLocation,
          type: 'TAKEN_AT',
          confidence: 0.8,
        ));
      }

      // Extract date entity if present
      if (creationDate != null) {
        final dateStr = _formatDateForEntity(creationDate);
        if (dateStr.isNotEmpty) {
          entities.add(ExtractedEntity(
            name: dateStr,
            type: EntityTypes.date,
            confidence: 1.0,
          ));

          relationships.add(ExtractedRelationship(
            sourceEntity: photoName,
            targetEntity: dateStr,
            type: 'TAKEN_ON',
            confidence: 1.0,
          ));
        }
      }

      // Extract people in photo if available (from face detection etc.)
      final people = photo['people'] ?? photo['faces'] as List<dynamic>?;
      if (people != null) {
        for (final person in people) {
          final personStr = person.toString();
          if (personStr.isNotEmpty) {
            entities.add(ExtractedEntity(
              name: personStr,
              type: EntityTypes.person,
              confidence: 0.8, // Face recognition might not be perfect
            ));

            relationships.add(ExtractedRelationship(
              sourceEntity: personStr,
              targetEntity: photoName,
              type: 'PICTURED_IN',
              confidence: 0.8,
            ));
          }
        }
      }
    }

    return ExtractionResult(
      entities: entities,
      relationships: relationships,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Extract entities from a phone call
  ExtractionResult _extractFromPhoneCall(
    Map<String, dynamic> call,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    // Extract person entity from contact name
    final contactName = call['contactName'] ?? call['name'];
    final phoneNumber = call['phoneNumber'] ?? call['number'];
    final callType = call['callType'] ?? call['type'];
    final timestamp = call['timestamp'] ?? call['date'];
    final duration = call['duration'];

    if (contactName != null && contactName.toString().isNotEmpty) {
      entities.add(ExtractedEntity(
        name: contactName.toString(),
        type: EntityTypes.person,
        attributes: {
          if (phoneNumber != null) 'phoneNumber': phoneNumber.toString(),
        },
        confidence: 1.0,
      ));

      // Create call relationship from "You" perspective
      // The actual "You" link will be created by LinkPredictor
    } else if (phoneNumber != null && phoneNumber.toString().isNotEmpty) {
      // If no contact name, create a phone number entity
      entities.add(ExtractedEntity(
        name: phoneNumber.toString(),
        type: EntityTypes.phone,
        attributes: {
          if (callType != null) 'lastCallType': callType.toString(),
          if (timestamp != null) 'lastCallTime': timestamp.toString(),
          if (duration != null) 'lastCallDuration': duration,
        },
        confidence: 0.9,
      ));
    }

    // Extract date entity if timestamp is available
    if (timestamp != null) {
      final dateStr = _formatDateForEntity(timestamp);
      if (dateStr.isNotEmpty) {
        entities.add(ExtractedEntity(
          name: dateStr,
          type: EntityTypes.date,
          confidence: 1.0,
        ));
      }
    }

    return ExtractionResult(
      entities: entities,
      relationships: relationships,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Format date for entity name
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

/// Entity deduplication and merging utilities
class EntityMerger {
  /// Merge entities with similar names
  static List<ExtractedEntity> deduplicateEntities(
    List<ExtractedEntity> entities, {
    double similarityThreshold = 0.8,
  }) {
    final merged = <ExtractedEntity>[];
    final processed = <int>{};
    
    for (var i = 0; i < entities.length; i++) {
      if (processed.contains(i)) continue;
      
      var best = entities[i];
      
      // Find similar entities
      for (var j = i + 1; j < entities.length; j++) {
        if (processed.contains(j)) continue;
        
        if (_areSimilarNames(best.name, entities[j].name, similarityThreshold)) {
          // Merge: keep the one with higher confidence or more info
          if (entities[j].confidence > best.confidence ||
              (entities[j].description?.isNotEmpty ?? false) &&
                  (best.description?.isEmpty ?? true)) {
            best = entities[j];
          }
          processed.add(j);
        }
      }
      
      merged.add(best);
      processed.add(i);
    }
    
    return merged;
  }

  /// Check if two names are similar (simple implementation)
  static bool _areSimilarNames(String a, String b, double threshold) {
    final aLower = a.toLowerCase().trim();
    final bLower = b.toLowerCase().trim();
    
    // Exact match
    if (aLower == bLower) return true;
    
    // One contains the other
    if (aLower.contains(bLower) || bLower.contains(aLower)) {
      return true;
    }
    
    // Simple Jaccard similarity on words
    final aWords = aLower.split(RegExp(r'\s+')).toSet();
    final bWords = bLower.split(RegExp(r'\s+')).toSet();
    
    final intersection = aWords.intersection(bWords).length;
    final union = aWords.union(bWords).length;
    
    return union > 0 && (intersection / union) >= threshold;
  }

  /// Update relationships to use canonical entity names
  static List<ExtractedRelationship> remapRelationships(
    List<ExtractedRelationship> relationships,
    Map<String, String> nameMapping,
  ) {
    return relationships.map((r) {
      final source = nameMapping[r.sourceEntity.toLowerCase()] ?? r.sourceEntity;
      final target = nameMapping[r.targetEntity.toLowerCase()] ?? r.targetEntity;
      
      return ExtractedRelationship(
        sourceEntity: source,
        targetEntity: target,
        type: r.type,
        description: r.description,
        weight: r.weight,
        confidence: r.confidence,
      );
    }).toList();
  }
}
