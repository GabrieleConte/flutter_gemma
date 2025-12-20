package dev.flutterberlin.flutter_gemma

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Binder
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service for background indexing operations.
 * Keeps the indexing process alive when the app is in the background.
 */
class IndexingForegroundService : Service() {
    
    companion object {
        const val CHANNEL_ID = "flutter_gemma_indexing"
        const val CHANNEL_NAME = "GraphRAG Indexing"
        const val NOTIFICATION_ID = 1001
        
        const val ACTION_START = "dev.flutterberlin.flutter_gemma.START_INDEXING"
        const val ACTION_STOP = "dev.flutterberlin.flutter_gemma.STOP_INDEXING"
        const val ACTION_UPDATE_PROGRESS = "dev.flutterberlin.flutter_gemma.UPDATE_PROGRESS"
        
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_PHASE = "phase"
        const val EXTRA_ENTITIES = "entities"
        const val EXTRA_RELATIONSHIPS = "relationships"
        
        private var instance: IndexingForegroundService? = null
        
        fun isRunning(): Boolean = instance != null
        
        fun startService(context: Context) {
            val intent = Intent(context, IndexingForegroundService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
        
        fun stopService(context: Context) {
            val intent = Intent(context, IndexingForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
        
        fun updateProgress(
            context: Context,
            progress: Float,
            phase: String,
            entities: Int,
            relationships: Int
        ) {
            instance?.updateNotification(progress, phase, entities, relationships)
        }
    }
    
    private val binder = LocalBinder()
    private var notificationManager: NotificationManager? = null
    
    inner class LocalBinder : Binder() {
        fun getService(): IndexingForegroundService = this@IndexingForegroundService
    }
    
    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }
    
    override fun onBind(intent: Intent?): IBinder = binder
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForegroundWithNotification()
            }
            ACTION_STOP -> {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        // START_NOT_STICKY: Don't restart service if process is killed
        // The indexing is managed by Flutter and can't continue without the Dart isolate
        return START_NOT_STICKY
    }
    
    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows progress of GraphRAG indexing"
                setShowBadge(false)
            }
            
            notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager?.createNotificationChannel(channel)
        }
    }
    
    private fun startForegroundWithNotification() {
        val notification = buildNotification(0f, "Starting indexing...", 0, 0)
        startForeground(NOTIFICATION_ID, notification)
    }
    
    fun updateNotification(progress: Float, phase: String, entities: Int, relationships: Int) {
        val notification = buildNotification(progress, phase, entities, relationships)
        notificationManager?.notify(NOTIFICATION_ID, notification)
    }
    
    private fun buildNotification(
        progress: Float,
        phase: String,
        entities: Int,
        relationships: Int
    ): Notification {
        // Create intent to open app when notification is tapped
        val packageManager = applicationContext.packageManager
        val launchIntent = packageManager.getLaunchIntentForPackage(applicationContext.packageName)
        val pendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        } else null
        
        val progressPercent = (progress * 100).toInt()
        val contentText = if (entities > 0 || relationships > 0) {
            "$phase • $entities entities, $relationships relationships"
        } else {
            phase
        }
        
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("GraphRAG Indexing")
            .setContentText(contentText)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setProgress(100, progressPercent, progress == 0f)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .apply {
                if (pendingIntent != null) {
                    setContentIntent(pendingIntent)
                }
            }
            .build()
    }
}
