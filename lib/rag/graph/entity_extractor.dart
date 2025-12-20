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
    return ExtractedEntity(
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? 'UNKNOWN',
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
    return ExtractedRelationship(
      sourceEntity: json['source'] as String? ?? json['sourceEntity'] as String? ?? '',
      targetEntity: json['target'] as String? ?? json['targetEntity'] as String? ?? '',
      type: json['type'] as String? ?? json['relationship'] as String? ?? 'RELATED_TO',
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

    return '''Analyze this contact and extract entities and relationships.

Contact Information:
- Name: $name
- Organization: $org
- Job Title: $job
- Email(s): $emails
- Phone(s): $phones
- Notes: $note

Extract entities (the person, their organization, location, skills mentioned, etc.)
and relationships between them.

Return as JSON:
{
  "entities": [...],
  "relationships": [...]
}

JSON output:''';
  }

  static String eventExtractionPrompt(Map<String, dynamic> event) {
    final title = event['title'] ?? event['summary'] ?? 'Untitled Event';
    final location = event['location'] ?? '';
    final description = event['notes'] ?? event['description'] ?? '';
    final attendees = (event['attendees'] as List?)?.join(', ') ?? '';
    final startDate = event['startDate'] ?? event['start'] ?? '';
    final endDate = event['endDate'] ?? event['end'] ?? '';

    return '''Analyze this calendar event and extract entities and relationships.

Event Information:
- Title: $title
- Location: $location
- Description: $description
- Attendees: $attendees
- Start: $startDate
- End: $endDate

Extract entities (people, places, topics, projects mentioned)
and relationships between them.

Return as JSON:
{
  "entities": [...],
  "relationships": [...]
}

JSON output:''';
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
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      
      final entitiesJson = json['entities'] as List<dynamic>? ?? [];
      final relationshipsJson = json['relationships'] as List<dynamic>? ?? [];
      
      final entities = entitiesJson
          .map((e) => ExtractedEntity.fromJson(e as Map<String, dynamic>))
          .where((e) => e.name.isNotEmpty)
          .toList();
      
      final relationships = relationshipsJson
          .map((r) => ExtractedRelationship.fromJson(r as Map<String, dynamic>))
          .where((r) => r.sourceEntity.isNotEmpty && r.targetEntity.isNotEmpty)
          .toList();
      
      return _ParsedExtraction(entities: entities, relationships: relationships);
    } catch (e) {
      // If parsing fails, try a more lenient approach
      return _fallbackParsing(response);
    }
  }

  /// Extract JSON from response that might contain extra text
  String _extractJson(String response) {
    // Find the first { and last }
    final start = response.indexOf('{');
    final end = response.lastIndexOf('}');
    
    if (start >= 0 && end > start) {
      return response.substring(start, end + 1);
    }
    
    throw const FormatException('No JSON found in response');
  }

  /// Fallback parsing for non-JSON responses
  _ParsedExtraction _fallbackParsing(String response) {
    // Simple fallback - extract entity names from response
    final entities = <ExtractedEntity>[];
    
    // Look for capitalized words/phrases as potential entities
    final namePattern = RegExp(r'\b([A-Z][a-z]+(?:\s+[A-Z][a-z]+)*)\b');
    final matches = namePattern.allMatches(response);
    
    final seenNames = <String>{};
    for (final match in matches) {
      final name = match.group(1)!;
      if (!seenNames.contains(name.toLowerCase())) {
        seenNames.add(name.toLowerCase());
        entities.add(ExtractedEntity(
          name: name,
          type: EntityTypes.person, // Default type
          confidence: 0.5,
        ));
      }
    }
    
    return _ParsedExtraction(entities: entities, relationships: []);
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
