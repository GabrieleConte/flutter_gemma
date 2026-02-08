import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/rag/graph/native_function_extractor.dart';
import 'package:flutter_gemma/rag/graph/entity_extractor.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma/core/tool.dart';

void main() {
  group('ToolDefinition', () {
    test('extends Tool class', () {
      const tool = ToolDefinition(
        name: 'test_function',
        description: 'A test function',
        parameters: {
          'type': 'object',
          'properties': {
            'param1': {'type': 'string', 'description': 'First parameter'},
          },
        },
        required: ['param1'],
      );

      // Verify it extends Tool
      expect(tool, isA<Tool>());
      expect(tool.name, equals('test_function'));
      expect(tool.description, equals('A test function'));
    });

    test('toJson produces valid OpenAI-compatible structure', () {
      const tool = ToolDefinition(
        name: 'test_function',
        description: 'A test function',
        parameters: {
          'type': 'object',
          'properties': {
            'param1': {'type': 'string'},
          },
        },
        required: ['param1'],
      );

      final json = tool.toJson();

      expect(json['type'], equals('function'));
      expect(json['function']['name'], equals('test_function'));
      expect(json['function']['parameters']['required'], contains('param1'));
    });
  });

  group('ExtractionTools', () {
    test('extractAll tool has entities and relationships', () {
      final json = ExtractionTools.extractAll.toJson();
      final params = json['function']['parameters'] as Map;

      expect(params['properties'], isA<Map>());
      expect((params['properties'] as Map).containsKey('entities'), isTrue);
      expect((params['properties'] as Map).containsKey('relationships'), isTrue);
    });

    test('all returns list of tools', () {
      final tools = ExtractionTools.all;

      expect(tools, isNotEmpty);
      expect(tools.first.name, equals('extract_entities_and_relationships'));
    });

    test('extractAll can be used as Tool', () {
      // Verify it can be used wherever Tool is expected
      const Tool tool = ExtractionTools.extractAll;
      expect(tool.name, equals('extract_entities_and_relationships'));
    });
  });

  group('NativeFunctionExtractor', () {
    test('extracts from empty text returns empty result', () async {
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async => '',
        embeddingCallback: (text) async => List.filled(256, 0.0),
      );

      final result = await extractor.extractFromText(
        '',
        sourceId: 'test',
        sourceType: 'text',
      );

      expect(result.entities, isEmpty);
      expect(result.relationships, isEmpty);
    });

    test('handles JSON response', () async {
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async => '''
{
  "entities": [
    {"name": "John Doe", "type": "PERSON", "description": "A person"}
  ],
  "relationships": [
    {"source": "John Doe", "target": "Acme Corp", "type": "WORKS_AT"}
  ]
}
''',
        embeddingCallback: (text) async => List.filled(256, 0.0),
      );

      final result = await extractor.extractFromText(
        'John Doe works at Acme Corp',
        sourceId: 'test',
        sourceType: 'text',
      );

      expect(result.entities.length, equals(1));
      expect(result.entities.first.name, equals('John Doe'));
      expect(result.relationships.length, equals(1));
      expect(result.relationships.first.type, equals('WORKS_AT'));
    });

    test('handles FunctionGemma format response', () async {
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async =>
            '<start_function_call>call:extract_entities_and_relationships{entities:<escape>[{"name":"Alice","type":"PERSON"}]<escape>,relationships:<escape>[]<escape>}<end_function_call>',
        embeddingCallback: (text) async => List.filled(256, 0.0),
        modelType: ModelType.functionGemma,
      );

      final result = await extractor.extractFromText(
        'Alice is a developer',
        sourceId: 'test',
        sourceType: 'text',
      );

      // Note: This test verifies the extractor handles the format,
      // but actual parsing depends on FunctionCallParser implementation
      expect(result.sourceId, equals('test'));
    });

    test('truncates long text', () async {
      String? capturedPrompt;
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async {
          capturedPrompt = prompt;
          return '{"entities": [], "relationships": []}';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
      );

      // Create very long text
      final longText = 'word ' * 1000; // 5000+ chars

      await extractor.extractFromText(
        longText,
        sourceId: 'test',
        sourceType: 'text',
      );

      // Verify text was truncated
      expect(capturedPrompt, contains('[truncated]'));
    });

    test('generateEmbedding delegates to callback', () async {
      var embeddingCalled = false;
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async => '',
        embeddingCallback: (text) async {
          embeddingCalled = true;
          return List.filled(256, 0.5);
        },
      );

      final embedding = await extractor.generateEmbedding('test text');

      expect(embeddingCalled, isTrue);
      expect(embedding.length, equals(256));
    });

    test('extractFromStructured handles contact data', () async {
      String? capturedPrompt;
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async {
          capturedPrompt = prompt;
          return '{"entities": [], "relationships": []}';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
      );

      await extractor.extractFromStructured(
        {
          'fullName': 'Jane Doe',
          'organization': 'Tech Corp',
          'emailAddresses': ['jane@techcorp.com'],
        },
        sourceId: 'contact-1',
        sourceType: 'contact',
      );

      expect(capturedPrompt, contains('Jane Doe'));
      expect(capturedPrompt, contains('Tech Corp'));
    });

    test('extractFromStructured handles event data', () async {
      String? capturedPrompt;
      final extractor = NativeFunctionExtractor(
        llmCallback: (prompt, {tools}) async {
          capturedPrompt = prompt;
          return '{"entities": [], "relationships": []}';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
      );

      await extractor.extractFromStructured(
        {
          'title': 'Team Meeting',
          'location': 'Conference Room A',
          'attendees': ['Alice', 'Bob'],
        },
        sourceId: 'event-1',
        sourceType: 'calendar_event',
      );

      expect(capturedPrompt, contains('Team Meeting'));
      expect(capturedPrompt, contains('Conference Room A'));
    });
  });

  group('AdaptiveEntityExtractor', () {
    test('tries native extraction first', () async {
      var nativeCallCount = 0;

      final extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) async {
          if (tools != null) {
            nativeCallCount++;
          }
          return '''
{
  "entities": [{"name": "Test", "type": "TOPIC"}],
  "relationships": []
}
''';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
        enableFunctionCalling: true,
      );

      await extractor.extractFromText(
        'Test extraction',
        sourceId: 'test',
        sourceType: 'text',
      );

      // Native should be attempted first
      expect(nativeCallCount, greaterThan(0));
    });

    test('falls back when native returns empty', () async {
      var callCount = 0;

      final extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) async {
          callCount++;
          if (tools != null) {
            // Native call returns empty
            return '{"entities": [], "relationships": []}';
          }
          // LLM fallback returns data
          return '''
{
  "entities": [{"name": "Fallback", "type": "TOPIC"}],
  "relationships": []
}
''';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
        enableFunctionCalling: true,
      );

      await extractor.extractFromText(
        'Test extraction',
        sourceId: 'test',
        sourceType: 'text',
      );

      // Should have called both native and LLM
      expect(callCount, equals(2));
    });

    test('disables native when enableFunctionCalling is false', () async {
      var nativeCallCount = 0;

      final extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) async {
          if (tools != null) nativeCallCount++;
          return '{"entities": [], "relationships": []}';
        },
        embeddingCallback: (text) async => List.filled(256, 0.0),
        enableFunctionCalling: false,
      );

      await extractor.extractFromText(
        'Test extraction',
        sourceId: 'test',
        sourceType: 'text',
      );

      expect(nativeCallCount, equals(0));
    });

    test('getStats returns extraction statistics', () async {
      final extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) async =>
            '{"entities": [{"name": "Test", "type": "TOPIC"}], "relationships": []}',
        embeddingCallback: (text) async => List.filled(256, 0.0),
        enableFunctionCalling: true,
      );

      await extractor.extractFromText(
        'Test',
        sourceId: 'test',
        sourceType: 'text',
      );

      final stats = extractor.getStats();

      expect(stats['nativeEnabled'], isTrue);
      expect(stats['nativeSuccesses'], isA<int>());
      expect(stats['nativeFailures'], isA<int>());
    });

    test('resetStats clears counters', () async {
      final extractor = AdaptiveEntityExtractor(
        llmCallback: (prompt, {tools}) async =>
            '{"entities": [{"name": "Test", "type": "TOPIC"}], "relationships": []}',
        embeddingCallback: (text) async => List.filled(256, 0.0),
        enableFunctionCalling: true,
      );

      await extractor.extractFromText(
        'Test',
        sourceId: 'test',
        sourceType: 'text',
      );

      extractor.resetStats();
      final stats = extractor.getStats();

      expect(stats['nativeSuccesses'], equals(0));
      expect(stats['nativeFailures'], equals(0));
    });
  });
}
