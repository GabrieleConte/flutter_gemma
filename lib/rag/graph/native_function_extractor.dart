/// Native Function Calling Entity Extractor
///
/// Uses LiteRT-LM's native function calling capabilities for structured
/// entity extraction, providing better accuracy and consistent output format.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/function_call_parser.dart';
import '../../core/model.dart';
import '../../core/model_response.dart';
import '../../core/tool.dart';
import 'entity_extractor.dart';

/// Extended tool definition with required fields for function calling
/// Extends the existing Tool class with JSON serialization for OpenAI-compatible format
class ToolDefinition extends Tool {
  final List<String> required;

  const ToolDefinition({
    required super.name,
    required super.description,
    super.parameters = const {},
    this.required = const [],
  });

  /// Convert to OpenAI-compatible function calling format
  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': {
            ...parameters,
            'required': required,
          },
        },
      };
}

/// Parameter definition for tool functions (helper for building JSON schema)
class ParameterDefinition {
  final String type;
  final String description;
  final List<String>? enumValues;
  final Map<String, ParameterDefinition>? properties;
  final ParameterDefinition? items;

  const ParameterDefinition({
    required this.type,
    required this.description,
    this.enumValues,
    this.properties,
    this.items,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'type': type,
      'description': description,
    };
    if (enumValues != null) json['enum'] = enumValues;
    if (properties != null) {
      json['properties'] = {
        for (final entry in properties!.entries)
          entry.key: entry.value.toJson(),
      };
    }
    if (items != null) json['items'] = items!.toJson();
    return json;
  }
}

/// Standard tools for entity extraction
/// Uses same format as lib/core/tool.dart Tool class
class ExtractionTools {
  /// Tool for extracting entities and relationships
  /// Format matches the existing Tool.parameters JSON schema format
  static const extractAll = ToolDefinition(
    name: 'extract_entities_and_relationships',
    description: 'Extract named entities and their relationships from text. '
        'Identify people, organizations, locations, events, and how they connect.',
    parameters: {
      'type': 'object',
      'properties': {
        'entities': {
          'type': 'array',
          'description': 'List of extracted entities',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string', 'description': 'Entity name'},
              'type': {
                'type': 'string',
                'description': 'Entity type',
                'enum': [
                  'PERSON',
                  'ORGANIZATION',
                  'LOCATION',
                  'EVENT',
                  'DATE',
                  'PROJECT',
                  'SKILL',
                  'TOPIC',
                  'OTHER'
                ]
              },
              'description': {'type': 'string', 'description': 'Brief description'}
            },
            'required': ['name', 'type']
          }
        },
        'relationships': {
          'type': 'array',
          'description': 'List of relationships between entities',
          'items': {
            'type': 'object',
            'properties': {
              'source': {'type': 'string', 'description': 'Source entity name'},
              'target': {'type': 'string', 'description': 'Target entity name'},
              'type': {
                'type': 'string',
                'description': 'Relationship type',
                'enum': [
                  'WORKS_AT',
                  'KNOWS',
                  'PART_OF',
                  'LOCATED_IN',
                  'RELATED_TO',
                  'CREATED_BY',
                  'REPORTS_TO'
                ]
              }
            },
            'required': ['source', 'target', 'type']
          }
        }
      },
    },
    required: ['entities', 'relationships'],
  );

  static List<ToolDefinition> get all => [extractAll];
}

/// Entity extractor using native function calling
///
/// Leverages LiteRT-LM's native function calling for structured extraction.
/// Falls back to JSON parsing if native calls aren't available.
class NativeFunctionExtractor implements EntityExtractor {
  /// Callback for function-calling capable LLM
  /// Should return function call responses when given tool definitions
  final Future<String> Function(
    String prompt, {
    List<ToolDefinition>? tools,
  }) llmCallback;

  /// Callback for embeddings
  final Future<List<double>> Function(String text) embeddingCallback;

  /// Model type for proper parsing
  final ModelType modelType;

  /// Configuration
  final EntityExtractionConfig config;

  /// Enable debug logging
  final bool enableLogging;

  NativeFunctionExtractor({
    required this.llmCallback,
    required this.embeddingCallback,
    this.modelType = ModelType.functionGemma,
    EntityExtractionConfig? config,
    this.enableLogging = false,
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

    // Truncate text if needed (preserve ~70% of context for text)
    const maxTextLength = 2500;
    final truncatedText = text.length > maxTextLength
        ? '${text.substring(0, maxTextLength)}...[truncated]'
        : text;

    // Build extraction prompt with tool context
    final prompt = _buildExtractionPrompt(truncatedText);

    try {
      // Try native function calling first
      final response = await llmCallback(
        prompt,
        tools: ExtractionTools.all,
      );

      if (enableLogging) {
        debugPrint('NativeFunctionExtractor: Raw response: $response');
      }

      // Parse the response
      final result = _parseResponse(response, sourceId, sourceType);

      if (enableLogging) {
        debugPrint(
            'NativeFunctionExtractor: Extracted ${result.entities.length} entities, ${result.relationships.length} relationships');
      }

      return result;
    } catch (e) {
      debugPrint('NativeFunctionExtractor: Error during extraction: $e');

      // Return empty result on error
      return ExtractionResult(
        entities: [],
        relationships: [],
        sourceId: sourceId,
        sourceType: sourceType,
      );
    }
  }

  @override
  Future<ExtractionResult> extractFromStructured(
    Map<String, dynamic> data, {
    required String sourceId,
    required String sourceType,
  }) async {
    // Convert structured data to text and extract
    final text = _structuredToText(data, sourceType);
    return extractFromText(
      text,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  @override
  Future<List<double>> generateEmbedding(String text) async {
    return embeddingCallback(text);
  }

  /// Build prompt for entity extraction
  String _buildExtractionPrompt(String text) {
    final typesStr = config.entityTypes.isEmpty
        ? EntityTypes.all.join(', ')
        : config.entityTypes.join(', ');

    return '''Analyze the following text and extract all named entities and their relationships.

Entity types to look for: $typesStr

Text to analyze:
"""
$text
"""

Call extract_entities_and_relationships with the entities and relationships you find.''';
  }

  /// Parse LLM response (handles both function calls and JSON)
  ExtractionResult _parseResponse(
    String response,
    String sourceId,
    String sourceType,
  ) {
    // Try parsing as function call first
    final functionCall = FunctionCallParser.parse(
      response,
      modelType: modelType,
    );

    if (functionCall != null) {
      return _parseFunctionCallResult(functionCall, sourceId, sourceType);
    }

    // Fallback: try to extract JSON directly
    return _parseJsonResponse(response, sourceId, sourceType);
  }

  /// Parse function call result into extraction result
  ExtractionResult _parseFunctionCallResult(
    FunctionCallResponse call,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    final args = call.args;

    // Parse entities
    if (args['entities'] is List) {
      for (final e in args['entities'] as List) {
        if (e is Map<String, dynamic>) {
          try {
            final entity = ExtractedEntity.fromJson(e);
            if (entity.name.isNotEmpty &&
                entity.confidence >= config.minEntityConfidence) {
              entities.add(entity);
            }
          } catch (err) {
            if (enableLogging) {
              debugPrint('NativeFunctionExtractor: Failed to parse entity: $e');
            }
          }
        }
      }
    }

    // Parse relationships
    if (args['relationships'] is List) {
      for (final r in args['relationships'] as List) {
        if (r is Map<String, dynamic>) {
          try {
            final rel = ExtractedRelationship.fromJson(r);
            if (rel.sourceEntity.isNotEmpty &&
                rel.targetEntity.isNotEmpty &&
                rel.confidence >= config.minRelationshipConfidence) {
              relationships.add(rel);
            }
          } catch (err) {
            if (enableLogging) {
              debugPrint(
                  'NativeFunctionExtractor: Failed to parse relationship: $r');
            }
          }
        }
      }
    }

    return ExtractionResult(
      entities: entities.take(config.maxEntities).toList(),
      relationships: relationships.take(config.maxRelationships).toList(),
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Parse JSON response as fallback
  ExtractionResult _parseJsonResponse(
    String response,
    String sourceId,
    String sourceType,
  ) {
    final entities = <ExtractedEntity>[];
    final relationships = <ExtractedRelationship>[];

    try {
      // Find JSON in response
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(response);
      if (jsonMatch == null) {
        return ExtractionResult(
          entities: [],
          relationships: [],
          sourceId: sourceId,
          sourceType: sourceType,
        );
      }

      final json = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;

      // Parse entities
      if (json['entities'] is List) {
        for (final e in json['entities'] as List) {
          if (e is Map<String, dynamic>) {
            try {
              entities.add(ExtractedEntity.fromJson(e));
            } catch (_) {}
          }
        }
      }

      // Parse relationships
      if (json['relationships'] is List) {
        for (final r in json['relationships'] as List) {
          if (r is Map<String, dynamic>) {
            try {
              relationships.add(ExtractedRelationship.fromJson(r));
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      if (enableLogging) {
        debugPrint('NativeFunctionExtractor: Failed to parse JSON: $e');
      }
    }

    return ExtractionResult(
      entities: entities
          .where((e) => e.confidence >= config.minEntityConfidence)
          .take(config.maxEntities)
          .toList(),
      relationships: relationships
          .where((r) => r.confidence >= config.minRelationshipConfidence)
          .take(config.maxRelationships)
          .toList(),
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  /// Convert structured data to text for extraction
  String _structuredToText(Map<String, dynamic> data, String sourceType) {
    switch (sourceType.toLowerCase()) {
      case 'contact':
      case 'contacts':
        return _contactToText(data);
      case 'event':
      case 'calendar':
      case 'calendar_event':
        return _eventToText(data);
      case 'phone_call':
      case 'phone_calls':
      case 'call':
      case 'calls':
        return _phoneCallToText(data);
      case 'photo':
      case 'photos':
        return _photoToText(data);
      case 'note':
      case 'notes':
        return _noteToText(data);
      case 'alarm':
      case 'alarms':
        return _alarmToText(data);
      default:
        return _genericToText(data);
    }
  }

  String _contactToText(Map<String, dynamic> contact) {
    final parts = <String>[];

    final name = contact['fullName'] ?? contact['name'];
    if (name != null) parts.add('Name: $name');

    final org = contact['organization'] ?? contact['organizationName'];
    if (org != null) parts.add('Organization: $org');

    final job = contact['jobTitle'];
    if (job != null) parts.add('Job Title: $job');

    final emails = contact['emailAddresses'];
    if (emails is List && emails.isNotEmpty) {
      parts.add('Email: ${emails.join(", ")}');
    }

    final phones = contact['phoneNumbers'];
    if (phones is List && phones.isNotEmpty) {
      parts.add('Phone: ${phones.join(", ")}');
    }

    return parts.join('\n');
  }

  String _eventToText(Map<String, dynamic> event) {
    final parts = <String>[];

    final title = event['title'] ?? event['summary'];
    if (title != null) parts.add('Event: $title');

    final location = event['location'];
    if (location != null) parts.add('Location: $location');

    final start = event['start'] ?? event['startDate'];
    if (start != null) parts.add('Start: $start');

    final end = event['end'] ?? event['endDate'];
    if (end != null) parts.add('End: $end');

    final attendees = event['attendees'];
    if (attendees is List && attendees.isNotEmpty) {
      parts.add('Attendees: ${attendees.join(", ")}');
    }

    final description = event['description'] ?? event['notes'];
    if (description != null) parts.add('Description: $description');

    // Recurrence info
    final recurrenceInfo = event['recurrenceInfo'];
    if (recurrenceInfo != null) parts.add('Recurrence: $recurrenceInfo');
    final repeatFrequency = event['repeatFrequency'];
    if (repeatFrequency != null) parts.add('Repeat: $repeatFrequency');
    final onValue = event['on'];
    if (onValue != null) parts.add('On: $onValue');

    return parts.join('\n');
  }

  String _phoneCallToText(Map<String, dynamic> call) {
    final parts = <String>[];

    final contact = call['contactName'] ?? call['name'];
    if (contact != null) parts.add('Contact: $contact');

    final phone = call['phoneNumber'];
    if (phone != null) parts.add('Phone: $phone');

    final direction = call['callDirection'] ?? call['callType'];
    if (direction != null) parts.add('Direction: $direction');

    final date = call['date'];
    if (date != null) parts.add('Date: $date');

    final startTime = call['startTime'];
    if (startTime != null) parts.add('Start time: $startTime');

    final endTime = call['endTime'];
    if (endTime != null) parts.add('End time: $endTime');

    final duration = call['duration'];
    if (duration != null) parts.add('Duration: $duration');

    return parts.join('\n');
  }

  String _photoToText(Map<String, dynamic> photo) {
    final parts = <String>[];

    final filename = photo['filename'] ?? photo['name'];
    if (filename != null) parts.add('Photo: $filename');

    final location = photo['locationName'] ?? photo['location'];
    if (location != null) parts.add('Location: $location');

    final date = photo['creationDate'] ?? photo['dateTaken'];
    if (date != null) parts.add('Date: $date');

    return parts.join('\n');
  }

  String _noteToText(Map<String, dynamic> note) {
    final parts = <String>[];

    final title = note['title'];
    if (title != null) parts.add('Note: $title');

    final text = note['text'] ?? note['content'];
    if (text != null) {
      final preview = text.toString().length > 500
          ? '${text.toString().substring(0, 500)}...'
          : text.toString();
      parts.add('Content: $preview');
    }

    final dateCreated = note['dateCreated'];
    if (dateCreated != null) parts.add('Created: $dateCreated');

    final dateModified = note['dateModified'];
    if (dateModified != null) parts.add('Modified: $dateModified');

    return parts.join('\n');
  }

  String _alarmToText(Map<String, dynamic> alarm) {
    final parts = <String>[];

    final label = alarm['label'];
    if (label != null) parts.add('Alarm: $label');

    final time = alarm['time'];
    if (time != null) parts.add('Time: $time');

    final recurrenceType = alarm['recurrenceType'];
    if (recurrenceType != null) parts.add('Type: $recurrenceType');

    final date = alarm['date'];
    if (date != null) parts.add('Date: $date');

    final repeatFrequency = alarm['repeatFrequency'];
    if (repeatFrequency != null) parts.add('Repeat: $repeatFrequency');

    final onValue = alarm['on'];
    if (onValue != null) parts.add('On: $onValue');

    return parts.join('\n');
  }

  String _genericToText(Map<String, dynamic> data) {
    final parts = <String>[];

    for (final entry in data.entries) {
      if (entry.value != null) {
        final value = entry.value is List
            ? (entry.value as List).join(', ')
            : entry.value.toString();
        parts.add('${entry.key}: $value');
      }
    }

    return parts.join('\n');
  }
}

/// Adaptive extractor that tries native function calling first,
/// then falls back to prompt-based extraction
class AdaptiveEntityExtractor implements EntityExtractor {
  final NativeFunctionExtractor? _nativeExtractor;
  final LLMEntityExtractor _llmExtractor;

  /// Whether native extraction is available
  final bool nativeFunctionCallingEnabled;

  /// Track success rate for adaptive behavior
  int _nativeSuccesses = 0;
  int _nativeFailures = 0;

  /// Threshold to disable native extraction if failure rate is too high
  static const _maxFailureRate = 0.5;

  AdaptiveEntityExtractor({
    required Future<String> Function(String prompt,
            {List<ToolDefinition>? tools})
        llmCallback,
    required Future<List<double>> Function(String text) embeddingCallback,
    ModelType modelType = ModelType.functionGemma,
    bool enableFunctionCalling = true,
    EntityExtractionConfig? config,
    bool enableLogging = false,
  })  : nativeFunctionCallingEnabled = enableFunctionCalling,
        _nativeExtractor = enableFunctionCalling
            ? NativeFunctionExtractor(
                llmCallback: llmCallback,
                embeddingCallback: embeddingCallback,
                modelType: modelType,
                config: config,
                enableLogging: enableLogging,
              )
            : null,
        _llmExtractor = LLMEntityExtractor(
          llmCallback: (prompt) => llmCallback(prompt),
          embeddingCallback: embeddingCallback,
          config: config,
        );

  @override
  Future<ExtractionResult> extractFromText(
    String text, {
    required String sourceId,
    required String sourceType,
  }) async {
    // Try native extraction if enabled and not failing too often
    if (_shouldTryNative()) {
      try {
        final result = await _nativeExtractor!.extractFromText(
          text,
          sourceId: sourceId,
          sourceType: sourceType,
        );

        // Check if extraction was successful
        if (result.entities.isNotEmpty || result.relationships.isNotEmpty) {
          _nativeSuccesses++;
          return result;
        }

        // Empty result might indicate parsing failure
        _nativeFailures++;
      } catch (e) {
        _nativeFailures++;
        debugPrint('AdaptiveEntityExtractor: Native extraction failed: $e');
      }
    }

    // Fallback to prompt-based extraction
    return _llmExtractor.extractFromText(
      text,
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
    if (_shouldTryNative()) {
      try {
        final result = await _nativeExtractor!.extractFromStructured(
          data,
          sourceId: sourceId,
          sourceType: sourceType,
        );

        if (result.entities.isNotEmpty || result.relationships.isNotEmpty) {
          _nativeSuccesses++;
          return result;
        }

        _nativeFailures++;
      } catch (e) {
        _nativeFailures++;
      }
    }

    return _llmExtractor.extractFromStructured(
      data,
      sourceId: sourceId,
      sourceType: sourceType,
    );
  }

  @override
  Future<List<double>> generateEmbedding(String text) {
    return _llmExtractor.generateEmbedding(text);
  }

  /// Check if we should try native extraction
  bool _shouldTryNative() {
    if (!nativeFunctionCallingEnabled || _nativeExtractor == null) {
      return false;
    }

    // Always try for the first few attempts
    final total = _nativeSuccesses + _nativeFailures;
    if (total < 5) return true;

    // Disable if failure rate exceeds threshold
    final failureRate = _nativeFailures / total;
    return failureRate < _maxFailureRate;
  }

  /// Get extraction statistics
  Map<String, dynamic> getStats() => {
        'nativeEnabled': nativeFunctionCallingEnabled,
        'nativeSuccesses': _nativeSuccesses,
        'nativeFailures': _nativeFailures,
        'failureRate': _nativeSuccesses + _nativeFailures > 0
            ? _nativeFailures / (_nativeSuccesses + _nativeFailures)
            : 0.0,
      };

  /// Reset statistics
  void resetStats() {
    _nativeSuccesses = 0;
    _nativeFailures = 0;
  }
}
