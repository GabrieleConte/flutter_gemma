package dev.flutterberlin.flutter_gemma_example

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * BroadcastReceiver that copies the GraphRAG database to/from the app's
 * external files directory so it can be pulled/pushed via `adb` even when
 * the app is running in release mode (where `run-as` is unavailable).
 *
 * Usage from adb:
 *   # Export DB → external files (for pull)
 *   adb shell am broadcast -a dev.flutterberlin.flutter_gemma_example.DB_EXPORT
 *
 *   # Import DB ← external files (for push)
 *   adb shell am broadcast -a dev.flutterberlin.flutter_gemma_example.DB_IMPORT
 */
class DbSyncReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "DbSyncReceiver"
        private const val ACTION_EXPORT = "dev.flutterberlin.flutter_gemma_example.DB_EXPORT"
        private const val ACTION_IMPORT = "dev.flutterberlin.flutter_gemma_example.DB_IMPORT"

        /** Must match GraphStore.DATABASE_NAME */
        private const val GRAPH_DB_NAME = "flutter_gemma_graph.db"

        /** Staging filename used in the external files directory */
        private const val STAGING_NAME = "flutter_gemma_graph_sync.db"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_EXPORT -> exportDb(context)
            ACTION_IMPORT -> importDb(context)
            else -> Log.w(TAG, "Unknown action: ${intent.action}")
        }
    }

    /** Copy internal DB → external files dir so `adb pull` can reach it. */
    private fun exportDb(context: Context) {
        try {
            val internalDb = context.getDatabasePath(GRAPH_DB_NAME)
            if (!internalDb.exists()) {
                Log.e(TAG, "EXPORT_FAIL: Internal DB does not exist at ${internalDb.absolutePath}")
                return
            }

            val extDir = context.getExternalFilesDir(null)
            if (extDir == null) {
                Log.e(TAG, "EXPORT_FAIL: External files directory unavailable")
                return
            }

            val staging = File(extDir, STAGING_NAME)
            FileInputStream(internalDb).use { input ->
                FileOutputStream(staging).use { output ->
                    input.copyTo(output)
                }
            }

            Log.i(TAG, "EXPORT_OK: ${internalDb.length()} bytes → ${staging.absolutePath}")
        } catch (e: Exception) {
            Log.e(TAG, "EXPORT_FAIL: ${e.message}", e)
        }
    }

    /** Copy external staging file → internal DB location. */
    private fun importDb(context: Context) {
        try {
            val extDir = context.getExternalFilesDir(null)
            if (extDir == null) {
                Log.e(TAG, "IMPORT_FAIL: External files directory unavailable")
                return
            }

            val staging = File(extDir, STAGING_NAME)
            if (!staging.exists()) {
                Log.e(TAG, "IMPORT_FAIL: Staging file not found at ${staging.absolutePath}")
                return
            }

            // Verify it looks like a SQLite file (magic bytes: "SQLite format 3\0")
            val header = ByteArray(16)
            FileInputStream(staging).use { it.read(header) }
            val magic = String(header, 0, 6)
            if (!magic.startsWith("SQLite")) {
                Log.e(TAG, "IMPORT_FAIL: Staging file is not a valid SQLite database")
                return
            }

            val internalDb = context.getDatabasePath(GRAPH_DB_NAME)
            internalDb.parentFile?.mkdirs()

            FileInputStream(staging).use { input ->
                FileOutputStream(internalDb).use { output ->
                    input.copyTo(output)
                }
            }

            // Clean up staging file
            staging.delete()

            Log.i(TAG, "IMPORT_OK: ${internalDb.length()} bytes → ${internalDb.absolutePath}")
            Log.i(TAG, "IMPORT_OK: Restart the app for changes to take effect")
        } catch (e: Exception) {
            Log.e(TAG, "IMPORT_FAIL: ${e.message}", e)
        }
    }
}
