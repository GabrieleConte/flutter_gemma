package dev.flutterberlin.flutter_gemma.engines.litertlm

import android.util.Log
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import dev.flutterberlin.flutter_gemma.engines.*
import kotlinx.coroutines.flow.MutableSharedFlow

private const val TAG = "LiteRtLmSession"

/**
 * LiteRT-LM Session implementation.
 *
 * Key Design Decision: Chunk Buffering
 * - MediaPipe: addQueryChunk() directly on session
 * - LiteRT-LM: sendMessage() takes complete message
 * - Solution: Buffer chunks in StringBuilder, send on generateResponse()
 *
 * Key Design Decision: Vision Path
 * - All messages (text and multimodal) use the Conversation API.
 * - For images: Message.of(Content.ImageBytes(image), Content.Text(text))
 *   Image MUST come before text — Gemma3's chat template inserts image soft-tokens
 *   at the start of the user turn, so reversing the order breaks cross-attention.
 * - The lower-level Session.generateContent() API requires images to be
 *   pre-processed by the vision encoder BEFORE the call, and there is no
 *   public preprocessing API in LiteRT-LM 0.9.x. Only Conversation.sendMessage()
 *   (via nativeSendMessage) handles the full pipeline internally.
 */
class LiteRtLmSession(
    engine: Engine,
    config: SessionConfig,
    private val resultFlow: MutableSharedFlow<Pair<String, Boolean>>,
    private val errorFlow: MutableSharedFlow<Throwable>
) : InferenceSession {

    private val conversation: Conversation

    // Chunk buffering (MediaPipe compatibility) - thread-safe access
    private val pendingPrompt = StringBuilder()
    private val promptLock = Any()
    @Volatile private var pendingImage: ByteArray? = null

    init {
        val samplerConfig = SamplerConfig(
            topK = config.topK,
            topP = (config.topP ?: 0.95f).toDouble(),
            temperature = config.temperature.toDouble(),
        )
        conversation = engine.createConversation(
            ConversationConfig(samplerConfig = samplerConfig, systemMessage = null)
        )
        Log.d(TAG, "Created LiteRT-LM conversation with topK=${config.topK}, temp=${config.temperature}")
    }

    override fun addQueryChunk(prompt: String) {
        // Accumulate chunks (LiteRT-LM uses sendMessage, not addQueryChunk)
        synchronized(promptLock) {
            pendingPrompt.append(prompt)
            Log.v(TAG, "Accumulated chunk: ${prompt.length} chars, total: ${pendingPrompt.length}")
        }
    }

    override fun addImage(imageBytes: ByteArray) {
        // Store image for multimodal message (thread-safe)
        synchronized(promptLock) {
            pendingImage = imageBytes
        }
        Log.d(TAG, "Added image: ${imageBytes.size} bytes")
    }

    override fun generateResponse(): String {
        val text: String
        val image: ByteArray?
        synchronized(promptLock) {
            text = pendingPrompt.toString()
            pendingPrompt.clear()
            image = pendingImage
            pendingImage = null
        }
        Log.d(TAG, "Generating sync response, text=${text.length} chars, image=${image?.size ?: 0} bytes")

        return try {
            if (image != null) {
                // Image MUST precede text so the vision soft-tokens are prepended to the
                // user turn. Conversation.sendMessage() runs the full pipeline:
                // vision encoder → soft tokens → LLM prefill.
                // (Session.generateContent() skips preprocessing and cannot be used.)
                //
                // Gemma4DataProcessor (used by re-authored Qwen3.5 .litertlm models)
                // validates image count by counting occurrences of the regex:
                //   (<start_of_image>|<image_soft_token>|<start_of_audio>|<audio_soft_token>)
                // in the formatted text. When no placeholder is found but 1 image is
                // provided in Contents → "Provided more images than expected".
                // Injecting <start_of_image> before the text gives count=1, matching
                // the 1 Content.ImageBytes → validation passes.
                val textWithImageToken = "<start_of_image>$text"
                val raw = conversation.sendMessage(
                    Message.user(Contents.of(Content.ImageBytes(image), Content.Text(textWithImageToken)))
                ).toString()
                // LiteRT-LM returns multimodal responses with <start_of_turn> before
                // every token (the full formatted context, not just new tokens).
                // Extract the actual content by removing control tokens.
                extractVisionResponse(raw)
            } else {
                conversation.sendMessage(Message.user(Contents.of(Content.Text(text)))).toString()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Error generating response: ${e.javaClass.name}", e)
            errorFlow.tryEmit(if (e is Exception) e else RuntimeException(e))
            throw if (e is Exception) e else RuntimeException(e)
        }
    }

    override fun generateResponseAsync() {
        val text: String
        val image: ByteArray?
        synchronized(promptLock) {
            text = pendingPrompt.toString()
            pendingPrompt.clear()
            image = pendingImage
            pendingImage = null
        }
        Log.d(TAG, "Generating async response, text=${text.length} chars, image=${image?.size ?: 0} bytes")

        try {
            if (image != null) {
                // Same Conversation-API path as generateResponse (see comment there).
                // <start_of_image> is the placeholder Gemma4DataProcessor counts
                // via regex to validate image count (see generateResponse for details).
                val textWithImageToken = "<start_of_image>$text"
                conversation.sendMessageAsync(
                    Message.user(Contents.of(Content.ImageBytes(image), Content.Text(textWithImageToken))),
                    object : MessageCallback {
                        override fun onMessage(message: Message) {
                            resultFlow.tryEmit(message.toString() to false)
                        }
                        override fun onDone() {
                            resultFlow.tryEmit("" to true)
                        }
                        override fun onError(throwable: Throwable) {
                            Log.e(TAG, "Async vision generation error", throwable)
                            errorFlow.tryEmit(throwable)
                            resultFlow.tryEmit("" to true)
                        }
                    }
                )
            } else {
                conversation.sendMessageAsync(Message.user(Contents.of(Content.Text(text))), object : MessageCallback {
                    override fun onMessage(message: Message) {
                        resultFlow.tryEmit(message.toString() to false)
                    }
                    override fun onDone() {
                        resultFlow.tryEmit("" to true)
                    }
                    override fun onError(throwable: Throwable) {
                        Log.e(TAG, "Async generation error", throwable)
                        errorFlow.tryEmit(throwable)
                        resultFlow.tryEmit("" to true)
                    }
                })
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to start async generation: ${e.javaClass.name}", e)
            errorFlow.tryEmit(if (e is Exception) e else RuntimeException(e))
            resultFlow.tryEmit("" to true)
        }
    }

    /**
     * Extracts readable content from a multimodal LiteRT-LM response.
     *
     * LiteRT-LM's Conversation.sendMessage() with image content returns the full
     * formatted exchange including <start_of_turn> before every token:
     *   "<start_of_turn>user\n<start_of_turn>word1\n<start_of_turn>word2\n..."
     *
     * We strip the control tokens and the leading role header to get plain text.
     */
    private fun extractVisionResponse(raw: String): String {
        val stripped = raw
            .replace("<start_of_turn>", "")
            .replace("<end_of_turn>", "")
        val lines = stripped.lines()
        // Drop the first line if it is a role label (user/model/system/assistant)
        val roleLabels = setOf("user", "model", "system", "assistant")
        val contentLines = if (lines.firstOrNull()?.trim() in roleLabels) {
            lines.drop(1)
        } else {
            lines
        }
        return contentLines
            .filter { it.isNotBlank() }
            .joinToString(" ")
            .trim()
    }

    override fun sizeInTokens(prompt: String): Int {
        // LiteRT-LM doesn't expose tokenizer API
        // Estimate: ~4 characters per token (GPT-style average)
        val estimate = (prompt.length + 3) / 4
        Log.w(TAG, "sizeInTokens: LiteRT-LM does not support token counting. " +
                "Using estimate (~4 chars/token): $estimate tokens for ${prompt.length} chars. " +
                "This may be inaccurate for non-English text.")
        return estimate
    }

    override fun cancelGeneration() {
        try {
            conversation.cancelProcess()
            Log.d(TAG, "cancelGeneration: cancelled")
        } catch (e: Exception) {
            Log.w(TAG, "cancelGeneration failed", e)
        }
    }

    override fun close() {
        try {
            conversation.close()
            Log.d(TAG, "Conversation closed")
        } catch (e: Exception) {
            Log.w(TAG, "Error closing conversation", e)
        }
    }
}
