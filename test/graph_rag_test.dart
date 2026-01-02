import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/rag/graph/graph_repository.dart';
import 'package:flutter_gemma/rag/graph/entity_extractor.dart';
import 'package:flutter_gemma/rag/graph/community_detection.dart';
import 'package:flutter_gemma/rag/graph/cypher_parser.dart';
import 'package:flutter_gemma/rag/graph/hybrid_query_engine.dart';
import 'package:flutter_gemma/rag/connectors/data_connector.dart';
import 'package:flutter_gemma/rag/graph/background_indexing.dart';

void main() {
  group('GraphEntity', () {
    test('creates entity with required fields', () {
      final entity = GraphEntity(
        id: 'test-1',
        name: 'John Doe',
        type: 'PERSON',
        lastModified: DateTime.now(),
      );

      expect(entity.id, 'test-1');
      expect(entity.name, 'John Doe');
      expect(entity.type, 'PERSON');
    });

    test('creates entity with optional fields', () {
      final embedding = [0.1, 0.2, 0.3];
      final entity = GraphEntity(
        id: 'test-2',
        name: 'Google',
        type: 'ORGANIZATION',
        embedding: embedding,
        description: 'A tech company',
        metadata: {'industry': 'technology'},
        lastModified: DateTime.now(),
      );

      expect(entity.embedding, embedding);
      expect(entity.description, 'A tech company');
      expect(entity.metadata?['industry'], 'technology');
    });
  });

  group('GraphRelationship', () {
    test('creates relationship with default weight', () {
      final rel = GraphRelationship(
        id: 'rel-1',
        sourceId: 'person-1',
        targetId: 'org-1',
        type: 'WORKS_AT',
      );

      expect(rel.weight, 1.0);
    });

    test('creates relationship with custom weight', () {
      final rel = GraphRelationship(
        id: 'rel-2',
        sourceId: 'person-1',
        targetId: 'person-2',
        type: 'KNOWS',
        weight: 0.8,
      );

      expect(rel.weight, 0.8);
    });
  });

  group('EntityExtractor', () {
    test('ExtractedEntity parses from JSON', () {
      final json = {
        'name': 'Alice',
        'type': 'PERSON',
        'description': 'Software engineer',
        'confidence': 0.95,
      };

      final entity = ExtractedEntity.fromJson(json);

      expect(entity.name, 'Alice');
      expect(entity.type, 'PERSON');
      expect(entity.description, 'Software engineer');
      expect(entity.confidence, 0.95);
    });

    test('ExtractedRelationship parses from JSON', () {
      final json = {
        'source': 'Alice',
        'target': 'Google',
        'type': 'WORKS_AT',
        'weight': 1.0,
        'confidence': 0.9,
      };

      final rel = ExtractedRelationship.fromJson(json);

      expect(rel.sourceEntity, 'Alice');
      expect(rel.targetEntity, 'Google');
      expect(rel.type, 'WORKS_AT');
    });

    test('EntityTypes contains expected types', () {
      expect(EntityTypes.person, 'PERSON');
      expect(EntityTypes.organization, 'ORGANIZATION');
      expect(EntityTypes.event, 'EVENT');
      expect(EntityTypes.all.length, greaterThan(5));
    });

    test('RelationshipTypes contains expected types', () {
      expect(RelationshipTypes.worksAt, 'WORKS_AT');
      expect(RelationshipTypes.knows, 'KNOWS');
    });
  });

  group('EntityMerger', () {
    test('deduplicates similar entity names', () {
      final entities = [
        ExtractedEntity(name: 'John Smith', type: 'PERSON'),
        ExtractedEntity(name: 'John', type: 'PERSON'),
        ExtractedEntity(name: 'Jane Doe', type: 'PERSON'),
      ];

      final merged = EntityMerger.deduplicateEntities(entities);

      // Should merge 'John' into 'John Smith'
      expect(merged.length, 2);
    });

    test('keeps distinct entities separate', () {
      final entities = [
        ExtractedEntity(name: 'Alice', type: 'PERSON'),
        ExtractedEntity(name: 'Bob', type: 'PERSON'),
        ExtractedEntity(name: 'Charlie', type: 'PERSON'),
      ];

      final merged = EntityMerger.deduplicateEntities(entities);

      expect(merged.length, 3);
    });
  });

  group('CommunityDetection', () {
    test('CommunityDetectionConfig has default values', () {
      final config = CommunityDetectionConfig();

      expect(config.resolution, 1.0);
      expect(config.maxDepth, 2);
      expect(config.minCommunitySize, 2);
    });

    test('DetectedCommunity calculates size correctly', () {
      final community = DetectedCommunity(
        id: 'comm-1',
        level: 0,
        entityIds: {'e1', 'e2', 'e3'},
        modularity: 0.5,
      );

      expect(community.size, 3);
    });

    test('LeidenCommunityDetector handles empty input', () async {
      final detector = LeidenCommunityDetector();
      final result = await detector.detectCommunities([], []);

      expect(result.communities, isEmpty);
      expect(result.hierarchyDepth, 0);
    });

    test('LeidenCommunityDetector detects communities', () async {
      final entities = [
        GraphEntity(
            id: 'e1', name: 'A', type: 'PERSON', lastModified: DateTime.now()),
        GraphEntity(
            id: 'e2', name: 'B', type: 'PERSON', lastModified: DateTime.now()),
        GraphEntity(
            id: 'e3', name: 'C', type: 'PERSON', lastModified: DateTime.now()),
      ];

      final relationships = [
        GraphRelationship(
            id: 'r1', sourceId: 'e1', targetId: 'e2', type: 'KNOWS'),
        GraphRelationship(
            id: 'r2', sourceId: 'e2', targetId: 'e3', type: 'KNOWS'),
      ];

      final detector = LeidenCommunityDetector(
        config: CommunityDetectionConfig(minCommunitySize: 1),
      );
      final result = await detector.detectCommunities(entities, relationships);

      expect(result.communities, isNotEmpty);
    });
  });

  group('CypherParser', () {
    late CypherParser parser;

    setUp(() {
      parser = CypherParser();
    });

    test('parses simple MATCH clause', () {
      const query = 'MATCH (n:PERSON) RETURN n';
      final parsed = parser.parse(query);

      expect(parsed.matchPatterns.length, 1);
      expect(parsed.matchPatterns.first.nodes.length, 1);
      expect(parsed.matchPatterns.first.nodes.first.labels, contains('PERSON'));
    });

    test('parses MATCH with variable', () {
      const query = 'MATCH (p:PERSON) RETURN p';
      final parsed = parser.parse(query);

      expect(parsed.matchPatterns.first.nodes.first.variable, 'p');
    });

    test('parses single node pattern', () {
      // Note: Simplified Cypher parser handles single node patterns
      const query = 'MATCH (p:PERSON) RETURN p';
      final parsed = parser.parse(query);

      expect(parsed.matchPatterns.first.nodes.length, 1);
      expect(parsed.matchPatterns.first.nodes.first.labels, contains('PERSON'));
    });

    test('parses WHERE clause', () {
      const query = 'MATCH (p:PERSON) WHERE p.name = "John" RETURN p';
      final parsed = parser.parse(query);

      expect(parsed.whereCondition, isNotNull);
      expect(parsed.whereCondition, isA<ComparisonCondition>());
    });

    test('parses LIMIT clause', () {
      const query = 'MATCH (p:PERSON) RETURN p LIMIT 10';
      final parsed = parser.parse(query);

      expect(parsed.limit, 10);
    });

    test('parses RETURN *', () {
      const query = 'MATCH (p:PERSON) RETURN *';
      final parsed = parser.parse(query);

      expect(parsed.returnAll, isTrue);
    });

    test('parses compound WHERE with AND', () {
      const query =
          'MATCH (p:PERSON) WHERE p.name = "John" AND p.age > 30 RETURN p';
      final parsed = parser.parse(query);

      expect(parsed.whereCondition, isA<AndCondition>());
    });

    test('handles empty query gracefully', () {
      // Empty query returns empty result
      final parsed = parser.parse('');
      expect(parsed.matchPatterns, isEmpty);
    });
  });

  group('WhereCondition evaluation', () {
    test('ComparisonCondition evaluates equality', () {
      final condition = ComparisonCondition(
        left: 'name',
        operator: '=',
        right: 'John',
      );

      expect(condition.evaluate({'name': 'John'}), isTrue);
      expect(condition.evaluate({'name': 'Jane'}), isFalse);
    });

    test('ComparisonCondition evaluates CONTAINS', () {
      final condition = ComparisonCondition(
        left: 'name',
        operator: 'CONTAINS',
        right: 'oh',
      );

      expect(condition.evaluate({'name': 'John'}), isTrue);
      expect(condition.evaluate({'name': 'Jane'}), isFalse);
    });

    test('AndCondition requires all true', () {
      final condition = AndCondition([
        ComparisonCondition(left: 'a', operator: '=', right: 1),
        ComparisonCondition(left: 'b', operator: '=', right: 2),
      ]);

      expect(condition.evaluate({'a': 1, 'b': 2}), isTrue);
      expect(condition.evaluate({'a': 1, 'b': 3}), isFalse);
    });

    test('OrCondition requires any true', () {
      final condition = OrCondition([
        ComparisonCondition(left: 'a', operator: '=', right: 1),
        ComparisonCondition(left: 'b', operator: '=', right: 2),
      ]);

      expect(condition.evaluate({'a': 1, 'b': 3}), isTrue);
      expect(condition.evaluate({'a': 2, 'b': 3}), isFalse);
    });

    test('NotCondition inverts result', () {
      final condition = NotCondition(
        ComparisonCondition(left: 'a', operator: '=', right: 1),
      );

      expect(condition.evaluate({'a': 1}), isFalse);
      expect(condition.evaluate({'a': 2}), isTrue);
    });
  });

  group('HybridQueryConfig', () {
    test('has default values', () {
      final config = HybridQueryConfig();

      expect(config.cypherWeight, 0.4);
      expect(config.embeddingWeight, 0.4);
      expect(config.communityWeight, 0.2);
      expect(config.topK, 10);
      expect(config.includeCommunityContext, isTrue);
    });

    test('allows customization', () {
      final config = HybridQueryConfig(
        cypherWeight: 0.5,
        embeddingWeight: 0.5,
        communityWeight: 0.0,
        topK: 20,
        includeCommunityContext: false,
      );

      expect(config.cypherWeight, 0.5);
      expect(config.topK, 20);
      expect(config.includeCommunityContext, isFalse);
    });
  });

  group('HybridQueryBuilder', () {
    test('builds query with fluent API', () {
      final builder = HybridQueryBuilder()
          .query('Find people at Google')
          .types(['PERSON'])
          .limit(5)
          .withCommunities(false);

      // Builder stores configuration for execution
      expect(builder, isNotNull);
    });
  });

  group('DataConnector', () {
    test('Contact creates from minimal data', () {
      final contact = Contact(
        id: 'c1',
        lastModified: DateTime.now(),
      );

      expect(contact.fullName, isEmpty);
    });

    test('Contact fullName combines name parts', () {
      final contact = Contact(
        id: 'c1',
        givenName: 'John',
        familyName: 'Public',
        lastModified: DateTime.now(),
      );

      expect(contact.fullName, 'John Public');
    });

    test('CalendarEvent calculates duration', () {
      final start = DateTime(2024, 1, 1, 10, 0);
      final end = DateTime(2024, 1, 1, 11, 30);

      final event = CalendarEvent(
        id: 'e1',
        title: 'Meeting',
        startDate: start,
        endDate: end,
        lastModified: DateTime.now(),
      );

      expect(event.duration.inMinutes, 90);
    });

    test('ConnectorConfig has defaults', () {
      final config = ConnectorConfig();

      expect(config.incrementalSync, isTrue);
      expect(config.batchSize, 100);
    });

    test('ConnectorManager registers connectors', () {
      final manager = ConnectorManager();

      // Can't fully test without mocks, but verify API works
      expect(manager.connectors, isEmpty);
    });
  });

  group('IndexingProgress', () {
    test('calculates progress correctly', () {
      final progress = IndexingProgress(
        status: IndexingStatus.running,
        currentPhase: 'Processing',
        processedItems: 50,
        totalItems: 100,
      );

      expect(progress.progress, 0.5);
    });

    test('handles zero total items', () {
      final progress = IndexingProgress(
        status: IndexingStatus.idle,
        currentPhase: 'Idle',
        totalItems: 0,
      );

      expect(progress.progress, 0.0);
    });

    test('copyWith preserves unchanged values', () {
      final original = IndexingProgress(
        status: IndexingStatus.running,
        currentPhase: 'Phase 1',
        processedItems: 10,
        totalItems: 100,
      );

      final updated = original.copyWith(processedItems: 20);

      expect(updated.status, IndexingStatus.running);
      expect(updated.currentPhase, 'Phase 1');
      expect(updated.processedItems, 20);
      expect(updated.totalItems, 100);
    });
  });

  group('ExtractionPrompts', () {
    test('generates entity extraction prompt', () {
      final prompt = ExtractionPrompts.entityExtractionPrompt(
        'John works at Google',
        ['PERSON', 'ORGANIZATION'],
      );

      expect(prompt, contains('John works at Google'));
      expect(prompt, contains('PERSON'));
      expect(prompt, contains('ORGANIZATION'));
    });

    test('generates contact extraction prompt', () {
      final prompt = ExtractionPrompts.contactExtractionPrompt({
        'fullName': 'John Doe',
        'organization': 'Google',
        'jobTitle': 'Engineer',
      });

      expect(prompt, contains('John Doe'));
      expect(prompt, contains('Google'));
    });

    test('generates event extraction prompt', () {
      final prompt = ExtractionPrompts.eventExtractionPrompt({
        'title': 'Team Meeting',
        'location': 'Room 101',
        'attendees': ['Alice', 'Bob'],
      });

      expect(prompt, contains('Team Meeting'));
      expect(prompt, contains('Room 101'));
    });

    test('generates community summary prompt', () {
      final prompt = ExtractionPrompts.communitySummaryPrompt(
        ['Alice', 'Bob', 'Charlie'],
        ['Engineer', 'Designer', 'Manager'],
        ['Alice KNOWS Bob', 'Bob WORKS_WITH Charlie'],
      );

      expect(prompt, contains('Alice'));
      expect(prompt, contains('community'));
    });
  });

  group('HybridQueryResult Extension', () {
    test('hasResults returns correct value', () {
      final emptyResult = HybridQueryResult(
        entities: [],
        communities: [],
        contextString: '',
        metadata: QueryMetadata(
          originalQuery: 'test',
          totalEntitiesSearched: 0,
          totalCommunitiesSearched: 0,
          executionTime: Duration.zero,
        ),
      );

      expect(emptyResult.hasResults, isFalse);
    });

    test('entityIds returns unique IDs', () {
      final entity1 = GraphEntity(
        id: 'e1',
        name: 'A',
        type: 'PERSON',
        lastModified: DateTime.now(),
      );
      final entity2 = GraphEntity(
        id: 'e2',
        name: 'B',
        type: 'PERSON',
        lastModified: DateTime.now(),
      );

      final result = HybridQueryResult(
        entities: [
          ScoredQueryEntity(entity: entity1, score: 1.0, source: 'embedding'),
          ScoredQueryEntity(entity: entity2, score: 0.8, source: 'embedding'),
        ],
        communities: [],
        contextString: '',
        metadata: QueryMetadata(
          originalQuery: 'test',
          totalEntitiesSearched: 2,
          totalCommunitiesSearched: 0,
          executionTime: Duration.zero,
        ),
      );

      expect(result.entityIds, {'e1', 'e2'});
    });
  });
}
