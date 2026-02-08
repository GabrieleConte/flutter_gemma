import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gemma/core/function_call_parser.dart';
import 'package:flutter_gemma/core/model.dart';

void main() {
  group('FunctionGemma Parser', () {
    test('parses function call with single parameter', () {
      const input = '<start_function_call>call:get_weather{location:<escape>San Francisco<escape>}<end_function_call>';

      final result = FunctionCallParser.parse(input, modelType: ModelType.functionGemma);

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('San Francisco'));
    });

    test('parses function call with multiple parameters', () {
      const input = '<start_function_call>call:get_weather{location:<escape>Tokyo<escape>,unit:<escape>celsius<escape>}<end_function_call>';

      final result = FunctionCallParser.parse(input, modelType: ModelType.functionGemma);

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('Tokyo'));
      expect(result.args['unit'], equals('celsius'));
    });

    test('returns null for invalid format', () {
      const input = 'Just some regular text';

      final result = FunctionCallParser.parse(input, modelType: ModelType.functionGemma);

      expect(result, isNull);
    });

    test('isFunctionCallStart detects FunctionGemma format', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '<start_function_call>call:test',
          modelType: ModelType.functionGemma,
        ),
        isTrue,
      );
    });

    test('isFunctionCallStart does not detect JSON for FunctionGemma', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '{"name": "test"}',
          modelType: ModelType.functionGemma,
        ),
        isFalse,
      );
    });

    test('isFunctionCallComplete detects complete FunctionGemma call', () {
      const input = '<start_function_call>call:test{}<end_function_call>';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.functionGemma,
        ),
        isTrue,
      );
    });

    test('isFunctionCallComplete returns false for incomplete call', () {
      const input = '<start_function_call>call:test{param:<escape>value';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.functionGemma,
        ),
        isFalse,
      );
    });
  });

  group('JSON Parser (existing models)', () {
    test('still works for gemmaIt', () {
      const input = '<tool_code>{"name": "get_weather", "parameters": {"location": "NYC"}}</tool_code>';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('get_weather'));
      expect(result.args['location'], equals('NYC'));
    });

    test('still works for null modelType (backward compatibility)', () {
      const input = '{"name": "test", "parameters": {"key": "value"}}';

      final result = FunctionCallParser.parse(input);

      expect(result, isNotNull);
      expect(result!.name, equals('test'));
      expect(result.args['key'], equals('value'));
    });

    test('isFunctionCallStart works for JSON models', () {
      expect(
        FunctionCallParser.isFunctionCallStart(
          '{"name": "test"}',
          modelType: ModelType.gemmaIt,
        ),
        isTrue,
      );
    });

    test('isFunctionCallComplete works for JSON models', () {
      const input = '{"name": "test", "parameters": {}}';

      expect(
        FunctionCallParser.isFunctionCallComplete(
          input,
          modelType: ModelType.gemmaIt,
        ),
        isTrue,
      );
    });
  });

  group('Python Function Call Parser', () {
    test('parses Python function call with keyword arguments', () {
      const input = '''
```python
validate_relationship(relationship_type="FAMILY_MEMBER", is_valid=True, confidence=0.95)
```
''';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('validate_relationship'));
      expect(result.args['relationship_type'], equals('FAMILY_MEMBER'));
      expect(result.args['is_valid'], equals(true));
      expect(result.args['confidence'], equals(0.95));
    });

    test('parses Python function call without markdown block', () {
      const input = 'validate_relationship(relationship_type="COLLEAGUE", is_valid=False, confidence=0.3)';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('validate_relationship'));
      expect(result.args['relationship_type'], equals('COLLEAGUE'));
      expect(result.args['is_valid'], equals(false));
      expect(result.args['confidence'], equals(0.3));
    });

    test('parses Python function call with single quotes', () {
      const input = "validate_relationship(relationship_type='FRIEND', is_valid=True, confidence=0.8)";

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('validate_relationship'));
      expect(result.args['relationship_type'], equals('FRIEND'));
      expect(result.args['is_valid'], equals(true));
    });

    test('skips Python built-in functions', () {
      const input = 'print("hello")';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNull);
    });

    test('finds function call in mixed content', () {
      const input = '''
**Analysis:**
The semantic similarity score of 82% strongly suggests a close relationship.

**Call to `validate_relationship`:**

```python
def validate_relationship(relationship_type, is_valid, confidence):
  pass

validate_relationship(relationship_type="FAMILY_MEMBER", is_valid=True, confidence=0.95)
```
''';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('validate_relationship'));
      expect(result.args['relationship_type'], equals('FAMILY_MEMBER'));
      expect(result.args['is_valid'], equals(true));
    });

    test('parses tool_code block with nested parens in values', () {
      // Real-world example: LLM wraps a Python function call in ```tool_code
      // and values contain parentheses (e.g. "Dad (PERSON)")
      const input = '''```tool_code
validate_relationship(entity_a="Dad (PERSON)", entity_b="Dad's birthday (EVENT)", rules={"LOCATED_IN": "no proof"})
```''';

      final result = FunctionCallParser.parse(input, modelType: ModelType.gemmaIt);

      expect(result, isNotNull);
      expect(result!.name, equals('validate_relationship'));
      // Should parse entity_a and entity_b correctly despite nested parens
      expect(result.args['entity_a'], equals('Dad (PERSON)'));
      expect(result.args['entity_b'], equals("Dad's birthday (EVENT)"));
    });
  });
}
