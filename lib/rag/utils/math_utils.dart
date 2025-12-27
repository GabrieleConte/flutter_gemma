import 'dart:math';

/// Mathematical utilities for RAG operations.
class MathUtils {
  MathUtils._();

  /// Computes the cosine similarity between two vectors.
  ///
  /// Cosine similarity measures the cosine of the angle between two vectors,
  /// resulting in a value between -1 and 1:
  /// - 1 means vectors are identical in direction
  /// - 0 means vectors are orthogonal (perpendicular)
  /// - -1 means vectors are opposite in direction
  ///
  /// Formula: similarity = (A · B) / (||A|| × ||B||)
  ///
  /// For normalized embedding vectors, the result is typically between 0 and 1.
  ///
  /// Returns 0.0 if vectors have different lengths or either has zero magnitude.
  static double cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    if (normA == 0 || normB == 0) return 0.0;

    return dotProduct / (sqrt(normA) * sqrt(normB));
  }

  /// Computes the Euclidean distance between two vectors.
  ///
  /// Formula: distance = sqrt(Σ(a[i] - b[i])²)
  ///
  /// Returns [double.infinity] if vectors have different lengths.
  static double euclideanDistance(List<double> a, List<double> b) {
    if (a.length != b.length) return double.infinity;

    double sum = 0.0;
    for (int i = 0; i < a.length; i++) {
      final diff = a[i] - b[i];
      sum += diff * diff;
    }

    return sqrt(sum);
  }

  /// Computes the dot product of two vectors.
  ///
  /// Formula: dotProduct = Σ(a[i] × b[i])
  ///
  /// Returns 0.0 if vectors have different lengths.
  static double dotProduct(List<double> a, List<double> b) {
    if (a.length != b.length) return 0.0;

    double result = 0.0;
    for (int i = 0; i < a.length; i++) {
      result += a[i] * b[i];
    }
    return result;
  }

  /// Computes the L2 norm (magnitude) of a vector.
  ///
  /// Formula: ||v|| = sqrt(Σ(v[i]²))
  static double l2Norm(List<double> v) {
    double sum = 0.0;
    for (final value in v) {
      sum += value * value;
    }
    return sqrt(sum);
  }

  /// Normalizes a vector to unit length.
  ///
  /// Returns a new list with the same direction but magnitude of 1.
  /// Returns an empty list if the input has zero magnitude.
  static List<double> normalize(List<double> v) {
    final norm = l2Norm(v);
    if (norm == 0) return List.filled(v.length, 0.0);
    return v.map((x) => x / norm).toList();
  }
}
