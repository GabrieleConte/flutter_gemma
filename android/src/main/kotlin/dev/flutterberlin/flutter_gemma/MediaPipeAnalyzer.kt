package dev.flutterberlin.flutter_gemma

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log

/**
 * Photo analyzer for extracting basic metadata and heuristics from images.
 * 
 * Note: Full MediaPipe Vision Tasks (FaceDetector, ObjectDetector, ImageLabeler)
 * require additional dependencies. This implementation provides basic analysis
 * without ML models, focusing on metadata extraction and simple heuristics.
 * 
 * To enable full MediaPipe Vision support, add to build.gradle:
 * implementation 'com.google.mediapipe:tasks-vision:0.10.14'
 */
class MediaPipeAnalyzer(private val context: Context) {
    
    companion object {
        private const val TAG = "MediaPipeAnalyzer"
    }
    
    private var isInitialized = false
    
    /**
     * Initialize the analyzer.
     */
    fun initialize(): Boolean {
        isInitialized = true
        Log.i(TAG, "MediaPipeAnalyzer initialized (basic mode - no ML models)")
        return true
    }
    
    /**
     * Analyze a photo and return basic metadata and heuristics.
     * Full ML-based detection requires additional MediaPipe Vision dependencies.
     */
    fun analyzePhoto(
        photoId: String,
        imageBytes: ByteArray,
        detectFaces: Boolean = true,
        detectObjects: Boolean = true,
        detectText: Boolean = false
    ): PhotoAnalysisResult {
        val bitmap = try {
            BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to decode image: ${e.message}")
            return createEmptyResult(photoId)
        }
        
        if (bitmap == null) {
            Log.e(TAG, "Failed to decode image bytes")
            return createEmptyResult(photoId)
        }
        
        // Basic analysis without ML models
        val isScreenshot = checkIfScreenshot(bitmap)
        val dominantColors = extractDominantColors(bitmap)
        val labels = inferLabelsFromMetadata(bitmap, isScreenshot)
        
        bitmap.recycle()
        
        return PhotoAnalysisResult(
            photoId = photoId,
            faces = emptyList(), // Requires MediaPipe Vision
            objects = emptyList(), // Requires MediaPipe Vision
            texts = emptyList(), // Requires ML Kit or Tesseract
            labels = labels,
            dominantColors = dominantColors,
            isScreenshot = isScreenshot,
            hasText = false // Would need OCR
        )
    }
    
    /**
     * Infer basic labels from image metadata and characteristics.
     */
    private fun inferLabelsFromMetadata(bitmap: Bitmap, isScreenshot: Boolean): List<String> {
        val labels = mutableListOf<String>()
        
        // Aspect ratio based labels
        val aspectRatio = bitmap.width.toFloat() / bitmap.height
        when {
            aspectRatio > 1.7f -> labels.add("landscape")
            aspectRatio < 0.6f -> labels.add("portrait")
            aspectRatio in 0.9f..1.1f -> labels.add("square")
        }
        
        // Size based labels
        val megapixels = (bitmap.width * bitmap.height) / 1_000_000f
        when {
            megapixels > 8 -> labels.add("high_resolution")
            megapixels < 1 -> labels.add("low_resolution")
        }
        
        if (isScreenshot) {
            labels.add("screenshot")
        }
        
        return labels
    }
    
    /**
     * Check if image appears to be a screenshot based on heuristics.
     */
    private fun checkIfScreenshot(bitmap: Bitmap): Boolean {
        // Heuristics for detecting screenshots:
        
        // 1. Check aspect ratio (common phone screen ratios)
        val aspectRatio = bitmap.width.toFloat() / bitmap.height
        val isPhoneRatio = aspectRatio in 0.4f..0.6f || aspectRatio in 1.7f..2.5f
        
        // 2. Check for typical screenshot dimensions
        val commonWidths = setOf(1080, 1440, 1170, 1284, 1242, 828, 750, 720, 1125, 2778, 2532)
        val commonHeights = setOf(1920, 2560, 2532, 2778, 2688, 1792, 1334, 1280, 2436, 1242)
        val isCommonDimension = bitmap.width in commonWidths || bitmap.height in commonHeights
        
        // 3. Check if dimensions match exact phone resolutions
        val exactMatches = setOf(
            Pair(1080, 1920), Pair(1080, 2340), Pair(1080, 2400),
            Pair(1440, 2560), Pair(1440, 3040), Pair(1440, 3200),
            Pair(1170, 2532), Pair(1284, 2778), Pair(1242, 2688),
            Pair(750, 1334), Pair(828, 1792), Pair(1125, 2436)
        )
        val isExactMatch = exactMatches.contains(Pair(bitmap.width, bitmap.height)) ||
                          exactMatches.contains(Pair(bitmap.height, bitmap.width))
        
        return isExactMatch || (isPhoneRatio && isCommonDimension)
    }
    
    /**
     * Extract dominant colors from the image.
     */
    private fun extractDominantColors(bitmap: Bitmap): String {
        val colorCounts = mutableMapOf<Int, Int>()
        
        val stepX = maxOf(1, bitmap.width / 10)
        val stepY = maxOf(1, bitmap.height / 10)
        
        for (x in 0 until bitmap.width step stepX) {
            for (y in 0 until bitmap.height step stepY) {
                val pixel = bitmap.getPixel(x, y)
                // Quantize to reduce color space
                val quantized = quantizeColor(pixel)
                colorCounts[quantized] = (colorCounts[quantized] ?: 0) + 1
            }
        }
        
        // Get top 3 colors
        val topColors = colorCounts.entries
            .sortedByDescending { it.value }
            .take(3)
            .map { colorToHex(it.key) }
        
        return topColors.joinToString(",")
    }
    
    private fun quantizeColor(color: Int): Int {
        val r = (android.graphics.Color.red(color) / 32) * 32
        val g = (android.graphics.Color.green(color) / 32) * 32
        val b = (android.graphics.Color.blue(color) / 32) * 32
        return android.graphics.Color.rgb(r, g, b)
    }
    
    private fun colorToHex(color: Int): String {
        return String.format("#%02X%02X%02X",
            android.graphics.Color.red(color),
            android.graphics.Color.green(color),
            android.graphics.Color.blue(color)
        )
    }
    
    private fun createEmptyResult(photoId: String): PhotoAnalysisResult {
        return PhotoAnalysisResult(
            photoId = photoId,
            faces = emptyList(),
            objects = emptyList(),
            texts = emptyList(),
            labels = emptyList(),
            dominantColors = null,
            isScreenshot = false,
            hasText = false
        )
    }
    
    /**
     * Release resources.
     */
    fun close() {
        isInitialized = false
        Log.i(TAG, "MediaPipeAnalyzer closed")
    }
}
