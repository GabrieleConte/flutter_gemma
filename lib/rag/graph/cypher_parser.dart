import 'dart:async';

import 'graph_repository.dart';

/// Token types for Cypher lexer
enum CypherTokenType {
  // Keywords
  match,
  where,
  return_,
  and,
  or,
  not,
  limit,
  orderBy,
  asc,
  desc,
  
  // Punctuation
  openParen,
  closeParen,
  openBracket,
  closeBracket,
  openBrace,
  closeBrace,
  colon,
  comma,
  dot,
  arrow,
  dash,
  star,
  
  // Operators
  equals,
  notEquals,
  lessThan,
  greaterThan,
  lessThanOrEqual,
  greaterThanOrEqual,
  contains,
  startsWith,
  endsWith,
  in_,
  
  // Literals
  identifier,
  string,
  number,
  boolean,
  null_,
  
  // End of input
  eof,
}

/// Token from Cypher lexer
class CypherToken {
  final CypherTokenType type;
  final String value;
  final int position;

  CypherToken(this.type, this.value, this.position);

  @override
  String toString() => 'Token($type, "$value", $position)';
}

/// Lexer for simplified Cypher queries
class CypherLexer {
  final String input;
  int _position = 0;
  
  static const _keywords = {
    'match': CypherTokenType.match,
    'where': CypherTokenType.where,
    'return': CypherTokenType.return_,
    'and': CypherTokenType.and,
    'or': CypherTokenType.or,
    'not': CypherTokenType.not,
    'limit': CypherTokenType.limit,
    'order': CypherTokenType.orderBy,
    'by': CypherTokenType.orderBy,
    'asc': CypherTokenType.asc,
    'desc': CypherTokenType.desc,
    'contains': CypherTokenType.contains,
    'starts': CypherTokenType.startsWith,
    'ends': CypherTokenType.endsWith,
    'with': CypherTokenType.identifier, // Handle later
    'in': CypherTokenType.in_,
    'true': CypherTokenType.boolean,
    'false': CypherTokenType.boolean,
    'null': CypherTokenType.null_,
  };

  CypherLexer(this.input);

  List<CypherToken> tokenize() {
    final tokens = <CypherToken>[];
    
    while (_position < input.length) {
      _skipWhitespace();
      if (_position >= input.length) break;
      
      final token = _nextToken();
      if (token != null) {
        tokens.add(token);
      }
    }
    
    tokens.add(CypherToken(CypherTokenType.eof, '', _position));
    return tokens;
  }

  void _skipWhitespace() {
    while (_position < input.length && 
           input[_position].trim().isEmpty) {
      _position++;
    }
  }

  CypherToken? _nextToken() {
    final startPos = _position;
    final char = input[_position];
    
    // Single character tokens
    switch (char) {
      case '(':
        _position++;
        return CypherToken(CypherTokenType.openParen, '(', startPos);
      case ')':
        _position++;
        return CypherToken(CypherTokenType.closeParen, ')', startPos);
      case '[':
        _position++;
        return CypherToken(CypherTokenType.openBracket, '[', startPos);
      case ']':
        _position++;
        return CypherToken(CypherTokenType.closeBracket, ']', startPos);
      case '{':
        _position++;
        return CypherToken(CypherTokenType.openBrace, '{', startPos);
      case '}':
        _position++;
        return CypherToken(CypherTokenType.closeBrace, '}', startPos);
      case ':':
        _position++;
        return CypherToken(CypherTokenType.colon, ':', startPos);
      case ',':
        _position++;
        return CypherToken(CypherTokenType.comma, ',', startPos);
      case '.':
        _position++;
        return CypherToken(CypherTokenType.dot, '.', startPos);
      case '*':
        _position++;
        return CypherToken(CypherTokenType.star, '*', startPos);
    }
    
    // Arrow and dash
    if (char == '-') {
      if (_peek() == '>') {
        _position += 2;
        return CypherToken(CypherTokenType.arrow, '->', startPos);
      } else if (_peek() == '[' || _peek() == '-') {
        // Part of relationship pattern
        _position++;
        return CypherToken(CypherTokenType.dash, '-', startPos);
      }
      _position++;
      return CypherToken(CypherTokenType.dash, '-', startPos);
    }
    
    // Comparison operators
    if (char == '=') {
      _position++;
      return CypherToken(CypherTokenType.equals, '=', startPos);
    }
    if (char == '<') {
      if (_peek() == '=') {
        _position += 2;
        return CypherToken(CypherTokenType.lessThanOrEqual, '<=', startPos);
      } else if (_peek() == '>') {
        _position += 2;
        return CypherToken(CypherTokenType.notEquals, '<>', startPos);
      }
      _position++;
      return CypherToken(CypherTokenType.lessThan, '<', startPos);
    }
    if (char == '>') {
      if (_peek() == '=') {
        _position += 2;
        return CypherToken(CypherTokenType.greaterThanOrEqual, '>=', startPos);
      }
      _position++;
      return CypherToken(CypherTokenType.greaterThan, '>', startPos);
    }
    if (char == '!') {
      if (_peek() == '=') {
        _position += 2;
        return CypherToken(CypherTokenType.notEquals, '!=', startPos);
      }
    }
    
    // String literals
    if (char == '"' || char == "'") {
      return _readString(char);
    }
    
    // Numbers
    if (_isDigit(char)) {
      return _readNumber();
    }
    
    // Identifiers and keywords
    if (_isIdentifierStart(char)) {
      return _readIdentifier();
    }
    
    // Unknown character, skip
    _position++;
    return null;
  }

  String? _peek() {
    if (_position + 1 >= input.length) return null;
    return input[_position + 1];
  }

  bool _isDigit(String char) => char.codeUnitAt(0) >= 48 && char.codeUnitAt(0) <= 57;

  bool _isIdentifierStart(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 65 && code <= 90) ||  // A-Z
           (code >= 97 && code <= 122) || // a-z
           char == '_';
  }

  bool _isIdentifierPart(String char) {
    return _isIdentifierStart(char) || _isDigit(char);
  }

  CypherToken _readString(String quote) {
    final startPos = _position;
    _position++; // Skip opening quote
    
    final buffer = StringBuffer();
    while (_position < input.length && input[_position] != quote) {
      if (input[_position] == '\\' && _position + 1 < input.length) {
        _position++;
        switch (input[_position]) {
          case 'n':
            buffer.write('\n');
            break;
          case 't':
            buffer.write('\t');
            break;
          case 'r':
            buffer.write('\r');
            break;
          case '\\':
            buffer.write('\\');
            break;
          default:
            buffer.write(input[_position]);
        }
      } else {
        buffer.write(input[_position]);
      }
      _position++;
    }
    
    if (_position < input.length) {
      _position++; // Skip closing quote
    }
    
    return CypherToken(CypherTokenType.string, buffer.toString(), startPos);
  }

  CypherToken _readNumber() {
    final startPos = _position;
    final buffer = StringBuffer();
    var hasDecimal = false;
    
    while (_position < input.length) {
      final char = input[_position];
      if (_isDigit(char)) {
        buffer.write(char);
        _position++;
      } else if (char == '.' && !hasDecimal) {
        buffer.write(char);
        hasDecimal = true;
        _position++;
      } else {
        break;
      }
    }
    
    return CypherToken(CypherTokenType.number, buffer.toString(), startPos);
  }

  CypherToken _readIdentifier() {
    final startPos = _position;
    final buffer = StringBuffer();
    
    while (_position < input.length && 
           _isIdentifierPart(input[_position])) {
      buffer.write(input[_position]);
      _position++;
    }
    
    final value = buffer.toString();
    final lowerValue = value.toLowerCase();
    
    // Check for keywords
    final keywordType = _keywords[lowerValue];
    if (keywordType != null) {
      return CypherToken(keywordType, value, startPos);
    }
    
    return CypherToken(CypherTokenType.identifier, value, startPos);
  }
}

/// Parsed node pattern from MATCH clause
class NodePattern {
  final String? variable;
  final List<String> labels;
  final Map<String, dynamic> properties;

  NodePattern({
    this.variable,
    this.labels = const [],
    this.properties = const {},
  });

  @override
  String toString() => 
      '($variable${labels.isNotEmpty ? ':${labels.join(':')}' : ''})';
}

/// Parsed relationship pattern from MATCH clause
class RelationshipPattern {
  final String? variable;
  final List<String> types;
  final bool isDirected;
  final int? minLength;
  final int? maxLength;
  final Map<String, dynamic> properties;

  RelationshipPattern({
    this.variable,
    this.types = const [],
    this.isDirected = true,
    this.minLength,
    this.maxLength,
    this.properties = const {},
  });

  @override
  String toString() {
    final typesStr = types.isNotEmpty ? ':${types.join('|')}' : '';
    final lengthStr = minLength != null || maxLength != null
        ? '*${minLength ?? ''}..${maxLength ?? ''}'
        : '';
    return '-[$variable$typesStr$lengthStr]-${isDirected ? '>' : ''}';
  }
}

/// Parsed path pattern from MATCH clause
class PathPattern {
  final List<NodePattern> nodes;
  final List<RelationshipPattern> relationships;

  PathPattern({
    this.nodes = const [],
    this.relationships = const [],
  });
}

/// Where clause condition
abstract class WhereCondition {
  bool evaluate(Map<String, dynamic> bindings);
}

/// Comparison condition
class ComparisonCondition implements WhereCondition {
  final String left;
  final String operator;
  final dynamic right;

  ComparisonCondition({
    required this.left,
    required this.operator,
    required this.right,
  });

  @override
  bool evaluate(Map<String, dynamic> bindings) {
    final leftValue = _resolveValue(left, bindings);
    final rightValue = right is String && right.contains('.') 
        ? _resolveValue(right, bindings)
        : right;
    
    switch (operator) {
      case '=':
        return leftValue == rightValue;
      case '<>':
      case '!=':
        return leftValue != rightValue;
      case '<':
        return _compare(leftValue, rightValue) < 0;
      case '>':
        return _compare(leftValue, rightValue) > 0;
      case '<=':
        return _compare(leftValue, rightValue) <= 0;
      case '>=':
        return _compare(leftValue, rightValue) >= 0;
      case 'CONTAINS':
        return leftValue.toString().contains(rightValue.toString());
      case 'STARTS WITH':
        return leftValue.toString().startsWith(rightValue.toString());
      case 'ENDS WITH':
        return leftValue.toString().endsWith(rightValue.toString());
      case 'IN':
        return (rightValue as List).contains(leftValue);
      default:
        return false;
    }
  }

  dynamic _resolveValue(String path, Map<String, dynamic> bindings) {
    final parts = path.split('.');
    dynamic value = bindings;
    for (final part in parts) {
      if (value is Map) {
        value = value[part];
      } else {
        return null;
      }
    }
    return value;
  }

  int _compare(dynamic a, dynamic b) {
    if (a is num && b is num) {
      return a.compareTo(b);
    }
    return a.toString().compareTo(b.toString());
  }
}

/// Logical AND condition
class AndCondition implements WhereCondition {
  final List<WhereCondition> conditions;

  AndCondition(this.conditions);

  @override
  bool evaluate(Map<String, dynamic> bindings) {
    return conditions.every((c) => c.evaluate(bindings));
  }
}

/// Logical OR condition
class OrCondition implements WhereCondition {
  final List<WhereCondition> conditions;

  OrCondition(this.conditions);

  @override
  bool evaluate(Map<String, dynamic> bindings) {
    return conditions.any((c) => c.evaluate(bindings));
  }
}

/// Logical NOT condition
class NotCondition implements WhereCondition {
  final WhereCondition condition;

  NotCondition(this.condition);

  @override
  bool evaluate(Map<String, dynamic> bindings) {
    return !condition.evaluate(bindings);
  }
}

/// Return clause item
class ReturnItem {
  final String expression;
  final String? alias;

  ReturnItem({
    required this.expression,
    this.alias,
  });
}

/// Order by clause item
class OrderByItem {
  final String expression;
  final bool ascending;

  OrderByItem({
    required this.expression,
    this.ascending = true,
  });
}

/// Parsed Cypher query
class ParsedCypherQuery {
  final List<PathPattern> matchPatterns;
  final WhereCondition? whereCondition;
  final List<ReturnItem> returnItems;
  final List<OrderByItem> orderByItems;
  final int? limit;
  final bool returnAll;

  ParsedCypherQuery({
    this.matchPatterns = const [],
    this.whereCondition,
    this.returnItems = const [],
    this.orderByItems = const [],
    this.limit,
    this.returnAll = false,
  });
}

/// Parser for simplified Cypher queries
class CypherParser {
  late List<CypherToken> _tokens;
  int _current = 0;

  /// Parse a Cypher query string
  ParsedCypherQuery parse(String query) {
    final lexer = CypherLexer(query);
    _tokens = lexer.tokenize();
    _current = 0;
    
    return _parseQuery();
  }

  ParsedCypherQuery _parseQuery() {
    final matchPatterns = <PathPattern>[];
    WhereCondition? whereCondition;
    final returnItems = <ReturnItem>[];
    final orderByItems = <OrderByItem>[];
    int? limit;
    var returnAll = false;
    
    // Parse MATCH clauses
    while (_check(CypherTokenType.match)) {
      _advance();
      matchPatterns.add(_parsePathPattern());
    }
    
    // Parse WHERE clause
    if (_check(CypherTokenType.where)) {
      _advance();
      whereCondition = _parseWhereCondition();
    }
    
    // Parse RETURN clause
    if (_check(CypherTokenType.return_)) {
      _advance();
      
      if (_check(CypherTokenType.star)) {
        _advance();
        returnAll = true;
      } else {
        do {
          if (_check(CypherTokenType.comma)) _advance();
          returnItems.add(_parseReturnItem());
        } while (_check(CypherTokenType.comma));
      }
    }
    
    // Parse ORDER BY clause
    if (_check(CypherTokenType.orderBy)) {
      _advance();
      if (_check(CypherTokenType.orderBy)) _advance(); // Skip "BY"
      
      do {
        if (_check(CypherTokenType.comma)) _advance();
        orderByItems.add(_parseOrderByItem());
      } while (_check(CypherTokenType.comma));
    }
    
    // Parse LIMIT clause
    if (_check(CypherTokenType.limit)) {
      _advance();
      if (_check(CypherTokenType.number)) {
        limit = int.tryParse(_advance().value);
      }
    }
    
    return ParsedCypherQuery(
      matchPatterns: matchPatterns,
      whereCondition: whereCondition,
      returnItems: returnItems,
      orderByItems: orderByItems,
      limit: limit,
      returnAll: returnAll,
    );
  }

  PathPattern _parsePathPattern() {
    final nodes = <NodePattern>[];
    final relationships = <RelationshipPattern>[];
    
    // First node
    nodes.add(_parseNodePattern());
    
    // Subsequent (relationship, node) pairs
    while (_check(CypherTokenType.dash)) {
      relationships.add(_parseRelationshipPattern());
      nodes.add(_parseNodePattern());
    }
    
    return PathPattern(nodes: nodes, relationships: relationships);
  }

  NodePattern _parseNodePattern() {
    _consume(CypherTokenType.openParen, 'Expected (');
    
    String? variable;
    final labels = <String>[];
    final properties = <String, dynamic>{};
    
    // Variable name
    if (_check(CypherTokenType.identifier)) {
      variable = _advance().value;
    }
    
    // Labels
    while (_check(CypherTokenType.colon)) {
      _advance();
      if (_check(CypherTokenType.identifier)) {
        labels.add(_advance().value);
      }
    }
    
    // Properties
    if (_check(CypherTokenType.openBrace)) {
      _advance();
      properties.addAll(_parseProperties());
      _consume(CypherTokenType.closeBrace, 'Expected }');
    }
    
    _consume(CypherTokenType.closeParen, 'Expected )');
    
    return NodePattern(
      variable: variable,
      labels: labels,
      properties: properties,
    );
  }

  RelationshipPattern _parseRelationshipPattern() {
    _consume(CypherTokenType.dash, 'Expected -');
    
    String? variable;
    final types = <String>[];
    var isDirected = true;
    int? minLength;
    int? maxLength;
    final properties = <String, dynamic>{};
    
    // Check for relationship details
    if (_check(CypherTokenType.openBracket)) {
      _advance();
      
      // Variable name
      if (_check(CypherTokenType.identifier)) {
        variable = _advance().value;
      }
      
      // Types
      while (_check(CypherTokenType.colon)) {
        _advance();
        if (_check(CypherTokenType.identifier)) {
          types.add(_advance().value);
        }
      }
      
      // Variable length
      if (_check(CypherTokenType.star)) {
        _advance();
        // Parse min..max
        if (_check(CypherTokenType.number)) {
          minLength = int.tryParse(_advance().value);
        }
        if (_check(CypherTokenType.dot)) {
          _advance();
          _consume(CypherTokenType.dot, 'Expected ..');
          if (_check(CypherTokenType.number)) {
            maxLength = int.tryParse(_advance().value);
          }
        }
      }
      
      // Properties
      if (_check(CypherTokenType.openBrace)) {
        _advance();
        properties.addAll(_parseProperties());
        _consume(CypherTokenType.closeBrace, 'Expected }');
      }
      
      _consume(CypherTokenType.closeBracket, 'Expected ]');
    }
    
    // Check for direction
    _consume(CypherTokenType.dash, 'Expected -');
    if (_check(CypherTokenType.greaterThan)) {
      _advance();
      isDirected = true;
    } else {
      isDirected = false;
    }
    
    return RelationshipPattern(
      variable: variable,
      types: types,
      isDirected: isDirected,
      minLength: minLength,
      maxLength: maxLength,
      properties: properties,
    );
  }

  Map<String, dynamic> _parseProperties() {
    final properties = <String, dynamic>{};
    
    while (!_check(CypherTokenType.closeBrace) && !_isAtEnd()) {
      if (_check(CypherTokenType.comma)) _advance();
      
      if (_check(CypherTokenType.identifier)) {
        final key = _advance().value;
        _consume(CypherTokenType.colon, 'Expected :');
        final value = _parseValue();
        properties[key] = value;
      }
    }
    
    return properties;
  }

  dynamic _parseValue() {
    if (_check(CypherTokenType.string)) {
      return _advance().value;
    }
    if (_check(CypherTokenType.number)) {
      final value = _advance().value;
      return value.contains('.') ? double.parse(value) : int.parse(value);
    }
    if (_check(CypherTokenType.boolean)) {
      return _advance().value.toLowerCase() == 'true';
    }
    if (_check(CypherTokenType.null_)) {
      _advance();
      return null;
    }
    if (_check(CypherTokenType.openBracket)) {
      return _parseArray();
    }
    
    throw CypherParseException('Unexpected value');
  }

  List<dynamic> _parseArray() {
    _consume(CypherTokenType.openBracket, 'Expected [');
    final items = <dynamic>[];
    
    while (!_check(CypherTokenType.closeBracket) && !_isAtEnd()) {
      if (_check(CypherTokenType.comma)) _advance();
      items.add(_parseValue());
    }
    
    _consume(CypherTokenType.closeBracket, 'Expected ]');
    return items;
  }

  WhereCondition _parseWhereCondition() {
    return _parseOrCondition();
  }

  WhereCondition _parseOrCondition() {
    var left = _parseAndCondition();
    
    while (_check(CypherTokenType.or)) {
      _advance();
      final right = _parseAndCondition();
      left = OrCondition([left, right]);
    }
    
    return left;
  }

  WhereCondition _parseAndCondition() {
    var left = _parsePrimaryCondition();
    
    while (_check(CypherTokenType.and)) {
      _advance();
      final right = _parsePrimaryCondition();
      left = AndCondition([left, right]);
    }
    
    return left;
  }

  WhereCondition _parsePrimaryCondition() {
    if (_check(CypherTokenType.not)) {
      _advance();
      return NotCondition(_parsePrimaryCondition());
    }
    
    if (_check(CypherTokenType.openParen)) {
      _advance();
      final condition = _parseWhereCondition();
      _consume(CypherTokenType.closeParen, 'Expected )');
      return condition;
    }
    
    return _parseComparisonCondition();
  }

  ComparisonCondition _parseComparisonCondition() {
    // Parse left side (identifier or property access)
    final left = _parsePropertyAccess();
    
    // Parse operator
    String operator;
    if (_check(CypherTokenType.equals)) {
      _advance();
      operator = '=';
    } else if (_check(CypherTokenType.notEquals)) {
      _advance();
      operator = '<>';
    } else if (_check(CypherTokenType.lessThan)) {
      _advance();
      operator = '<';
    } else if (_check(CypherTokenType.greaterThan)) {
      _advance();
      operator = '>';
    } else if (_check(CypherTokenType.lessThanOrEqual)) {
      _advance();
      operator = '<=';
    } else if (_check(CypherTokenType.greaterThanOrEqual)) {
      _advance();
      operator = '>=';
    } else if (_check(CypherTokenType.contains)) {
      _advance();
      operator = 'CONTAINS';
    } else if (_check(CypherTokenType.startsWith)) {
      _advance();
      if (_checkAhead(CypherTokenType.identifier, 'WITH')) _advance();
      operator = 'STARTS WITH';
    } else if (_check(CypherTokenType.endsWith)) {
      _advance();
      if (_checkAhead(CypherTokenType.identifier, 'WITH')) _advance();
      operator = 'ENDS WITH';
    } else if (_check(CypherTokenType.in_)) {
      _advance();
      operator = 'IN';
    } else {
      throw CypherParseException('Expected comparison operator');
    }
    
    // Parse right side
    final right = operator == 'IN' ? _parseArray() : _parseValue();
    
    return ComparisonCondition(
      left: left,
      operator: operator,
      right: right,
    );
  }

  String _parsePropertyAccess() {
    final parts = <String>[];
    
    if (_check(CypherTokenType.identifier)) {
      parts.add(_advance().value);
      
      while (_check(CypherTokenType.dot)) {
        _advance();
        if (_check(CypherTokenType.identifier)) {
          parts.add(_advance().value);
        }
      }
    }
    
    return parts.join('.');
  }

  ReturnItem _parseReturnItem() {
    final expression = _parsePropertyAccess();
    String? alias;
    
    // Check for AS alias
    if (_checkAhead(CypherTokenType.identifier, 'AS')) {
      _advance();
      if (_check(CypherTokenType.identifier)) {
        alias = _advance().value;
      }
    }
    
    return ReturnItem(expression: expression, alias: alias);
  }

  OrderByItem _parseOrderByItem() {
    final expression = _parsePropertyAccess();
    var ascending = true;
    
    if (_check(CypherTokenType.asc)) {
      _advance();
      ascending = true;
    } else if (_check(CypherTokenType.desc)) {
      _advance();
      ascending = false;
    }
    
    return OrderByItem(expression: expression, ascending: ascending);
  }

  bool _check(CypherTokenType type) {
    if (_isAtEnd()) return false;
    return _peek().type == type;
  }

  bool _checkAhead(CypherTokenType type, String value) {
    if (_isAtEnd()) return false;
    final token = _peek();
    return token.type == type && 
           token.value.toUpperCase() == value.toUpperCase();
  }

  CypherToken _advance() {
    if (!_isAtEnd()) _current++;
    return _previous();
  }

  bool _isAtEnd() {
    return _peek().type == CypherTokenType.eof;
  }

  CypherToken _peek() {
    return _tokens[_current];
  }

  CypherToken _previous() {
    return _tokens[_current - 1];
  }

  CypherToken _consume(CypherTokenType type, String message) {
    if (_check(type)) return _advance();
    throw CypherParseException('$message at position ${_peek().position}');
  }
}

/// Exception during Cypher parsing
class CypherParseException implements Exception {
  final String message;
  CypherParseException(this.message);
  
  @override
  String toString() => 'CypherParseException: $message';
}

/// Query executor for parsed Cypher queries
class CypherQueryExecutor {
  final GraphRepository repository;

  CypherQueryExecutor(this.repository);

  /// Execute a Cypher query against the graph
  Future<List<Map<String, dynamic>>> execute(String query) async {
    final parser = CypherParser();
    final parsed = parser.parse(query);
    
    return await _executeQuery(parsed);
  }

  Future<List<Map<String, dynamic>>> _executeQuery(ParsedCypherQuery query) async {
    if (query.matchPatterns.isEmpty) {
      return [];
    }

    // Start with results from first pattern
    var results = await _matchPattern(query.matchPatterns.first);
    
    // Join with subsequent patterns
    for (var i = 1; i < query.matchPatterns.length; i++) {
      final patternResults = await _matchPattern(query.matchPatterns[i]);
      results = _joinResults(results, patternResults);
    }
    
    // Apply WHERE filter
    if (query.whereCondition != null) {
      results = results
          .where((r) => query.whereCondition!.evaluate(r))
          .toList();
    }
    
    // Apply ORDER BY
    if (query.orderByItems.isNotEmpty) {
      results.sort((a, b) {
        for (final item in query.orderByItems) {
          final aVal = _getNestedValue(a, item.expression);
          final bVal = _getNestedValue(b, item.expression);
          final cmp = _compareValues(aVal, bVal);
          if (cmp != 0) {
            return item.ascending ? cmp : -cmp;
          }
        }
        return 0;
      });
    }
    
    // Apply LIMIT
    if (query.limit != null && results.length > query.limit!) {
      results = results.take(query.limit!).toList();
    }
    
    // Project results based on RETURN clause
    if (!query.returnAll && query.returnItems.isNotEmpty) {
      results = results.map((r) {
        final projected = <String, dynamic>{};
        for (final item in query.returnItems) {
          final key = item.alias ?? item.expression.split('.').last;
          projected[key] = _getNestedValue(r, item.expression);
        }
        return projected;
      }).toList();
    }
    
    return results;
  }

  Future<List<Map<String, dynamic>>> _matchPattern(PathPattern pattern) async {
    if (pattern.nodes.isEmpty) return [];
    
    var results = <Map<String, dynamic>>[];
    
    // Get entities matching first node pattern
    final firstNode = pattern.nodes.first;
    List<GraphEntity> entities;
    
    if (firstNode.labels.isNotEmpty) {
      entities = await repository.getEntitiesByType(firstNode.labels.first);
    } else {
      // Get all entities (would need a method for this)
      entities = [];
    }
    
    // Filter by properties
    entities = entities.where((e) {
      for (final prop in firstNode.properties.entries) {
        // Check entity properties (simplified)
        if (e.name != prop.value && e.type != prop.value) {
          return false;
        }
      }
      return true;
    }).toList();
    
    // Initialize results with matched entities
    for (final entity in entities) {
      final binding = <String, dynamic>{};
      if (firstNode.variable != null) {
        binding[firstNode.variable!] = _entityToMap(entity);
      }
      results.add(binding);
    }
    
    // Extend matches through relationships
    for (var i = 0; i < pattern.relationships.length; i++) {
      final rel = pattern.relationships[i];
      final nextNode = pattern.nodes[i + 1];
      
      results = await _extendMatches(results, rel, nextNode);
    }
    
    return results;
  }

  Future<List<Map<String, dynamic>>> _extendMatches(
    List<Map<String, dynamic>> currentResults,
    RelationshipPattern relPattern,
    NodePattern nextNodePattern,
  ) async {
    final extended = <Map<String, dynamic>>[];
    
    for (final result in currentResults) {
      // Get the last matched entity
      final lastVar = result.keys.last;
      final lastEntity = result[lastVar] as Map<String, dynamic>?;
      if (lastEntity == null) continue;
      
      final entityId = lastEntity['id'] as String?;
      if (entityId == null) continue;
      
      // Get neighbors
      final neighbors = await repository.getEntityNeighbors(
        entityId,
        depth: 1,
        relationshipType: relPattern.types.isNotEmpty 
            ? relPattern.types.first 
            : null,
      );
      
      // Filter by next node pattern
      for (final neighbor in neighbors) {
        if (_matchesNodePattern(neighbor, nextNodePattern)) {
          final newResult = Map<String, dynamic>.from(result);
          
          if (nextNodePattern.variable != null) {
            newResult[nextNodePattern.variable!] = _entityToMap(neighbor);
          }
          
          extended.add(newResult);
        }
      }
    }
    
    return extended;
  }

  bool _matchesNodePattern(GraphEntity entity, NodePattern pattern) {
    // Check labels
    if (pattern.labels.isNotEmpty) {
      if (!pattern.labels.contains(entity.type)) {
        return false;
      }
    }
    
    // Check properties (simplified)
    for (final prop in pattern.properties.entries) {
      if (prop.key == 'name' && entity.name != prop.value) {
        return false;
      }
      if (prop.key == 'type' && entity.type != prop.value) {
        return false;
      }
    }
    
    return true;
  }

  Map<String, dynamic> _entityToMap(GraphEntity entity) {
    return {
      'id': entity.id,
      'name': entity.name,
      'type': entity.type,
      'description': entity.description,
      'lastModified': entity.lastModified.toIso8601String(),
      ...?entity.metadata,
    };
  }

  List<Map<String, dynamic>> _joinResults(
    List<Map<String, dynamic>> left,
    List<Map<String, dynamic>> right,
  ) {
    // Simple cross join - in production, use proper join logic
    final joined = <Map<String, dynamic>>[];
    
    for (final l in left) {
      for (final r in right) {
        joined.add({...l, ...r});
      }
    }
    
    return joined;
  }

  dynamic _getNestedValue(Map<String, dynamic> map, String path) {
    final parts = path.split('.');
    dynamic value = map;
    
    for (final part in parts) {
      if (value is Map<String, dynamic>) {
        value = value[part];
      } else {
        return null;
      }
    }
    
    return value;
  }

  int _compareValues(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    
    if (a is num && b is num) {
      return a.compareTo(b);
    }
    
    return a.toString().compareTo(b.toString());
  }
}
