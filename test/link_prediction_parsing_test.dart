import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/rag/graph/link_prediction.dart';

void main() {
  group('extractRelationshipKeyword', () {
    test('parses bare keyword FAMILY_MEMBER', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword('FAMILY_MEMBER'),
        'FAMILY_MEMBER',
      );
    });

    test('parses bare keyword NONE', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword('NONE'),
        'NONE',
      );
    });

    test('parses bare keyword with surrounding whitespace', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword('  COLLEAGUE  '),
        'COLLEAGUE',
      );
    });

    test('parses bare keyword case-insensitively', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword('family_member'),
        'FAMILY_MEMBER',
      );
    });

    test('parses arrow-style: validate_relationship(...) -> FAMILY_MEMBER', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(
          'validate_relationship(Bob Gallipoli, John Gallipoli) -> FAMILY_MEMBER',
        ),
        'FAMILY_MEMBER',
      );
    });

    test('parses arrow-style with spaces', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(
          'result -> WORKS_AT',
        ),
        'WORKS_AT',
      );
    });

    test('parses keyword as last word in short response', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(
          'CALL validate_relationship FRIEND',
        ),
        'FRIEND',
      );
    });

    test('parses KNOWS from mixed text', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(
          'The relationship type is KNOWS',
        ),
        'KNOWS',
      );
    });

    test('returns null for long unrelated response', () {
      // Over 80 chars of unrelated text without any keyword
      const longResponse = 'This is a very long response from the LLM that '
          'does not contain any known relationship type keyword at all and keeps going';
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(longResponse),
        isNull,
      );
    });

    test('returns null for empty response', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(''),
        isNull,
      );
    });

    test('returns null for unrecognised keyword', () {
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword('ENEMY'),
        isNull,
      );
    });

    test('parses all known relationship types', () {
      for (final type in EmbeddingSimilarityLinkPredictor.knownRelationshipTypes) {
        expect(
          EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(type),
          type,
          reason: 'Should recognise $type',
        );
      }
    });

    test('parses "CALL validate_relationship" does not match (no keyword)', () {
      // "CALL validate_relationship" has no known type as the last word;
      // "validate_relationship" is not in the set
      expect(
        EmbeddingSimilarityLinkPredictor.extractRelationshipKeyword(
          'CALL validate_relationship',
        ),
        isNull,
      );
    });
  });
}
