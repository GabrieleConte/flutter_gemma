package dev.flutterberlin.flutter_gemma

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import kotlin.math.sqrt

/**
 * Android GraphStore implementation for GraphRAG
 * Stores entities, relationships, and communities with embeddings in SQLite
 */
class GraphStore(
    private val context: Context,
    private val dimension: Int? = null
) {
    private var dbHelper: GraphDatabaseHelper? = null
    private var database: SQLiteDatabase? = null
    private var detectedDimension: Int? = null

    companion object {
        const val DATABASE_NAME = "flutter_gemma_graph.db"
        const val DATABASE_VERSION = 1

        // Entity table
        const val TABLE_ENTITIES = "entities"
        const val COLUMN_ID = "id"
        const val COLUMN_NAME = "name"
        const val COLUMN_TYPE = "type"
        const val COLUMN_EMBEDDING = "embedding"
        const val COLUMN_DESCRIPTION = "description"
        const val COLUMN_METADATA = "metadata"
        const val COLUMN_LAST_MODIFIED = "last_modified"
        const val COLUMN_CREATED_AT = "created_at"

        // Relationship table
        const val TABLE_RELATIONSHIPS = "relationships"
        const val COLUMN_SOURCE_ID = "source_id"
        const val COLUMN_TARGET_ID = "target_id"
        const val COLUMN_WEIGHT = "weight"

        // Community table
        const val TABLE_COMMUNITIES = "communities"
        const val COLUMN_LEVEL = "level"
        const val COLUMN_SUMMARY = "summary"

        // Entity-Community membership table
        const val TABLE_ENTITY_COMMUNITIES = "entity_communities"
        const val COLUMN_ENTITY_ID = "entity_id"
        const val COLUMN_COMMUNITY_ID = "community_id"
    }

    private inner class GraphDatabaseHelper(context: Context) : 
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {
        
        override fun onCreate(db: SQLiteDatabase) {
            // Enable foreign keys
            db.execSQL("PRAGMA foreign_keys = ON;")

            // Create entities table
            db.execSQL("""
                CREATE TABLE $TABLE_ENTITIES (
                    $COLUMN_ID TEXT PRIMARY KEY,
                    $COLUMN_NAME TEXT NOT NULL,
                    $COLUMN_TYPE TEXT NOT NULL,
                    $COLUMN_EMBEDDING BLOB NOT NULL,
                    $COLUMN_DESCRIPTION TEXT,
                    $COLUMN_METADATA TEXT,
                    $COLUMN_LAST_MODIFIED INTEGER NOT NULL,
                    $COLUMN_CREATED_AT INTEGER DEFAULT (strftime('%s', 'now'))
                )
            """.trimIndent())
            db.execSQL("CREATE INDEX idx_entities_type ON $TABLE_ENTITIES($COLUMN_TYPE)")
            db.execSQL("CREATE INDEX idx_entities_last_modified ON $TABLE_ENTITIES($COLUMN_LAST_MODIFIED)")

            // Create relationships table
            db.execSQL("""
                CREATE TABLE $TABLE_RELATIONSHIPS (
                    $COLUMN_ID TEXT PRIMARY KEY,
                    $COLUMN_SOURCE_ID TEXT NOT NULL,
                    $COLUMN_TARGET_ID TEXT NOT NULL,
                    $COLUMN_TYPE TEXT NOT NULL,
                    $COLUMN_WEIGHT REAL DEFAULT 1.0,
                    $COLUMN_METADATA TEXT,
                    $COLUMN_CREATED_AT INTEGER DEFAULT (strftime('%s', 'now')),
                    FOREIGN KEY ($COLUMN_SOURCE_ID) REFERENCES $TABLE_ENTITIES($COLUMN_ID),
                    FOREIGN KEY ($COLUMN_TARGET_ID) REFERENCES $TABLE_ENTITIES($COLUMN_ID)
                )
            """.trimIndent())
            db.execSQL("CREATE INDEX idx_rel_source ON $TABLE_RELATIONSHIPS($COLUMN_SOURCE_ID)")
            db.execSQL("CREATE INDEX idx_rel_target ON $TABLE_RELATIONSHIPS($COLUMN_TARGET_ID)")
            db.execSQL("CREATE INDEX idx_rel_type ON $TABLE_RELATIONSHIPS($COLUMN_TYPE)")

            // Create communities table
            db.execSQL("""
                CREATE TABLE $TABLE_COMMUNITIES (
                    $COLUMN_ID TEXT PRIMARY KEY,
                    $COLUMN_LEVEL INTEGER NOT NULL,
                    $COLUMN_SUMMARY TEXT NOT NULL,
                    $COLUMN_EMBEDDING BLOB NOT NULL,
                    $COLUMN_METADATA TEXT,
                    $COLUMN_CREATED_AT INTEGER DEFAULT (strftime('%s', 'now'))
                )
            """.trimIndent())
            db.execSQL("CREATE INDEX idx_comm_level ON $TABLE_COMMUNITIES($COLUMN_LEVEL)")

            // Create entity-community membership table
            db.execSQL("""
                CREATE TABLE $TABLE_ENTITY_COMMUNITIES (
                    $COLUMN_ENTITY_ID TEXT NOT NULL,
                    $COLUMN_COMMUNITY_ID TEXT NOT NULL,
                    PRIMARY KEY ($COLUMN_ENTITY_ID, $COLUMN_COMMUNITY_ID),
                    FOREIGN KEY ($COLUMN_ENTITY_ID) REFERENCES $TABLE_ENTITIES($COLUMN_ID),
                    FOREIGN KEY ($COLUMN_COMMUNITY_ID) REFERENCES $TABLE_COMMUNITIES($COLUMN_ID)
                )
            """.trimIndent())
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            db.execSQL("DROP TABLE IF EXISTS $TABLE_ENTITY_COMMUNITIES")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_COMMUNITIES")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_RELATIONSHIPS")
            db.execSQL("DROP TABLE IF EXISTS $TABLE_ENTITIES")
            onCreate(db)
        }

        override fun onOpen(db: SQLiteDatabase) {
            super.onOpen(db)
            db.execSQL("PRAGMA foreign_keys = ON;")
        }
    }

    fun initialize(databasePath: String) {
        dbHelper = GraphDatabaseHelper(context)
        database = dbHelper?.writableDatabase
    }

    // MARK: - Entity Methods

    fun addEntity(
        id: String,
        name: String,
        type: String,
        embedding: List<Double>,
        description: String?,
        metadata: String?,
        lastModified: Long
    ) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        // Auto-detect dimension
        if (detectedDimension == null) {
            detectedDimension = dimension ?: embedding.size
            if (dimension != null && dimension != embedding.size) {
                throw IllegalArgumentException(
                    "Embedding dimension mismatch: expected $dimension, got ${embedding.size}"
                )
            }
        }

        if (embedding.size != detectedDimension) {
            throw IllegalArgumentException(
                "Embedding dimension mismatch: expected $detectedDimension, got ${embedding.size}"
            )
        }

        val embeddingBlob = embeddingToBlob(embedding)

        val values = ContentValues().apply {
            put(COLUMN_ID, id)
            put(COLUMN_NAME, name)
            put(COLUMN_TYPE, type)
            put(COLUMN_EMBEDDING, embeddingBlob)
            put(COLUMN_DESCRIPTION, description)
            put(COLUMN_METADATA, metadata)
            put(COLUMN_LAST_MODIFIED, lastModified)
        }

        db.insertWithOnConflict(TABLE_ENTITIES, null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun updateEntity(
        id: String,
        name: String?,
        type: String?,
        embedding: List<Double>?,
        description: String?,
        metadata: String?,
        lastModified: Long?
    ) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val values = ContentValues()
        name?.let { values.put(COLUMN_NAME, it) }
        type?.let { values.put(COLUMN_TYPE, it) }
        embedding?.let { 
            if (detectedDimension != null && it.size != detectedDimension) {
                throw IllegalArgumentException(
                    "Embedding dimension mismatch: expected $detectedDimension, got ${it.size}"
                )
            }
            values.put(COLUMN_EMBEDDING, embeddingToBlob(it)) 
        }
        description?.let { values.put(COLUMN_DESCRIPTION, it) }
        metadata?.let { values.put(COLUMN_METADATA, it) }
        lastModified?.let { values.put(COLUMN_LAST_MODIFIED, it) }

        if (values.size() > 0) {
            db.update(TABLE_ENTITIES, values, "$COLUMN_ID = ?", arrayOf(id))
        }
    }

    fun deleteEntity(id: String) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        // Delete from entity_communities first
        db.delete(TABLE_ENTITY_COMMUNITIES, "$COLUMN_ENTITY_ID = ?", arrayOf(id))

        // Delete relationships involving this entity
        db.delete(TABLE_RELATIONSHIPS, "$COLUMN_SOURCE_ID = ? OR $COLUMN_TARGET_ID = ?", arrayOf(id, id))

        // Delete entity
        db.delete(TABLE_ENTITIES, "$COLUMN_ID = ?", arrayOf(id))
    }

    fun getEntity(id: String): EntityResult? {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val cursor = db.query(
            TABLE_ENTITIES,
            arrayOf(COLUMN_ID, COLUMN_NAME, COLUMN_TYPE, COLUMN_DESCRIPTION, COLUMN_METADATA, COLUMN_LAST_MODIFIED),
            "$COLUMN_ID = ?",
            arrayOf(id),
            null, null, null
        )

        return cursor.use {
            if (it.moveToFirst()) {
                EntityResult(
                    id = it.getString(0),
                    name = it.getString(1),
                    type = it.getString(2),
                    description = it.getString(3),
                    metadata = it.getString(4),
                    lastModified = it.getLong(5)
                )
            } else null
        }
    }

    fun getEntitiesByType(type: String): List<EntityResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val cursor = db.query(
            TABLE_ENTITIES,
            arrayOf(COLUMN_ID, COLUMN_NAME, COLUMN_TYPE, COLUMN_DESCRIPTION, COLUMN_METADATA, COLUMN_LAST_MODIFIED),
            "$COLUMN_TYPE = ?",
            arrayOf(type),
            null, null, null
        )

        val results = mutableListOf<EntityResult>()
        cursor.use {
            while (it.moveToNext()) {
                results.add(EntityResult(
                    id = it.getString(0),
                    name = it.getString(1),
                    type = it.getString(2),
                    description = it.getString(3),
                    metadata = it.getString(4),
                    lastModified = it.getLong(5)
                ))
            }
        }
        return results
    }

    // MARK: - Relationship Methods

    fun addRelationship(
        id: String,
        sourceId: String,
        targetId: String,
        type: String,
        weight: Double,
        metadata: String?
    ) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val values = ContentValues().apply {
            put(COLUMN_ID, id)
            put(COLUMN_SOURCE_ID, sourceId)
            put(COLUMN_TARGET_ID, targetId)
            put(COLUMN_TYPE, type)
            put(COLUMN_WEIGHT, weight)
            put(COLUMN_METADATA, metadata)
        }

        db.insertWithOnConflict(TABLE_RELATIONSHIPS, null, values, SQLiteDatabase.CONFLICT_REPLACE)
    }

    fun deleteRelationship(id: String) {
        val db = database ?: throw IllegalStateException("Database not initialized")
        db.delete(TABLE_RELATIONSHIPS, "$COLUMN_ID = ?", arrayOf(id))
    }

    fun getRelationships(entityId: String): List<RelationshipResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val cursor = db.query(
            TABLE_RELATIONSHIPS,
            arrayOf(COLUMN_ID, COLUMN_SOURCE_ID, COLUMN_TARGET_ID, COLUMN_TYPE, COLUMN_WEIGHT, COLUMN_METADATA),
            "$COLUMN_SOURCE_ID = ? OR $COLUMN_TARGET_ID = ?",
            arrayOf(entityId, entityId),
            null, null, null
        )

        val results = mutableListOf<RelationshipResult>()
        cursor.use {
            while (it.moveToNext()) {
                results.add(RelationshipResult(
                    id = it.getString(0),
                    sourceId = it.getString(1),
                    targetId = it.getString(2),
                    type = it.getString(3),
                    weight = it.getDouble(4),
                    metadata = it.getString(5)
                ))
            }
        }
        return results
    }

    // MARK: - Community Methods

    fun addCommunity(
        id: String,
        level: Long,
        summary: String,
        entityIds: List<String>,
        embedding: List<Double>,
        metadata: String?
    ) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        // Allow empty embeddings for initial community creation (will be updated later with real embeddings)
        if (embedding.isNotEmpty() && detectedDimension != null && embedding.size != detectedDimension) {
            throw IllegalArgumentException(
                "Embedding dimension mismatch: expected $detectedDimension, got ${embedding.size}"
            )
        }

        val embeddingBlob = embeddingToBlob(embedding)

        val values = ContentValues().apply {
            put(COLUMN_ID, id)
            put(COLUMN_LEVEL, level)
            put(COLUMN_SUMMARY, summary)
            put(COLUMN_EMBEDDING, embeddingBlob)
            put(COLUMN_METADATA, metadata)
        }

        db.insertWithOnConflict(TABLE_COMMUNITIES, null, values, SQLiteDatabase.CONFLICT_REPLACE)

        // Delete existing entity-community mappings
        db.delete(TABLE_ENTITY_COMMUNITIES, "$COLUMN_COMMUNITY_ID = ?", arrayOf(id))

        // Insert entity-community mappings
        for (entityId in entityIds) {
            val ecValues = ContentValues().apply {
                put(COLUMN_ENTITY_ID, entityId)
                put(COLUMN_COMMUNITY_ID, id)
            }
            db.insertWithOnConflict(TABLE_ENTITY_COMMUNITIES, null, ecValues, SQLiteDatabase.CONFLICT_IGNORE)
        }
    }

    fun updateCommunitySummary(id: String, summary: String, embedding: List<Double>) {
        val db = database ?: throw IllegalStateException("Database not initialized")

        if (detectedDimension != null && embedding.size != detectedDimension) {
            throw IllegalArgumentException(
                "Embedding dimension mismatch: expected $detectedDimension, got ${embedding.size}"
            )
        }

        val values = ContentValues().apply {
            put(COLUMN_SUMMARY, summary)
            put(COLUMN_EMBEDDING, embeddingToBlob(embedding))
        }

        db.update(TABLE_COMMUNITIES, values, "$COLUMN_ID = ?", arrayOf(id))
    }

    fun getCommunitiesByLevel(level: Long): List<CommunityResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val cursor = db.query(
            TABLE_COMMUNITIES,
            arrayOf(COLUMN_ID, COLUMN_LEVEL, COLUMN_SUMMARY, COLUMN_METADATA),
            "$COLUMN_LEVEL = ?",
            arrayOf(level.toString()),
            null, null, null
        )

        val results = mutableListOf<CommunityResult>()
        cursor.use {
            while (it.moveToNext()) {
                val communityId = it.getString(0)
                val entityIds = getEntityIdsForCommunity(communityId)

                results.add(CommunityResult(
                    id = communityId,
                    level = it.getLong(1),
                    summary = it.getString(2),
                    entityIds = entityIds,
                    metadata = it.getString(3)
                ))
            }
        }
        return results
    }

    private fun getEntityIdsForCommunity(communityId: String): List<String?> {
        val db = database ?: return emptyList()

        val cursor = db.query(
            TABLE_ENTITY_COMMUNITIES,
            arrayOf(COLUMN_ENTITY_ID),
            "$COLUMN_COMMUNITY_ID = ?",
            arrayOf(communityId),
            null, null, null
        )

        val entityIds = mutableListOf<String?>()
        cursor.use {
            while (it.moveToNext()) {
                entityIds.add(it.getString(0))
            }
        }
        return entityIds
    }

    // MARK: - Graph Traversal Methods

    fun getEntityNeighbors(entityId: String, depth: Int, relationshipType: String?): List<EntityResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val visited = mutableSetOf(entityId)
        var currentLevel = setOf(entityId)
        val results = mutableListOf<EntityResult>()

        repeat(depth) {
            val nextLevel = mutableSetOf<String>()

            for (currentId in currentLevel) {
                val typeClause = if (relationshipType != null) " AND $COLUMN_TYPE = ?" else ""
                val selectionArgs = if (relationshipType != null) {
                    arrayOf(currentId, currentId, relationshipType)
                } else {
                    arrayOf(currentId, currentId)
                }

                val cursor = db.rawQuery("""
                    SELECT DISTINCT
                        CASE
                            WHEN $COLUMN_SOURCE_ID = ? THEN $COLUMN_TARGET_ID
                            ELSE $COLUMN_SOURCE_ID
                        END as neighbor_id
                    FROM $TABLE_RELATIONSHIPS
                    WHERE ($COLUMN_SOURCE_ID = ? OR $COLUMN_TARGET_ID = ?)$typeClause
                """.trimIndent(), selectionArgs)

                cursor.use {
                    while (it.moveToNext()) {
                        val neighborId = it.getString(0)
                        if (neighborId !in visited) {
                            visited.add(neighborId)
                            nextLevel.add(neighborId)
                        }
                    }
                }
            }

            currentLevel = nextLevel
        }

        // Fetch entity details for all visited nodes
        visited.remove(entityId)
        for (visitedId in visited) {
            getEntity(visitedId)?.let { results.add(it) }
        }

        return results
    }

    // MARK: - Similarity Search Methods

    fun searchEntitiesBySimilarity(
        queryEmbedding: List<Double>,
        topK: Int,
        threshold: Double,
        entityType: String?
    ): List<EntityWithScoreResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        if (detectedDimension != null && queryEmbedding.size != detectedDimension) {
            throw IllegalArgumentException(
                "Query embedding dimension mismatch: expected $detectedDimension, got ${queryEmbedding.size}"
            )
        }

        val selection = if (entityType != null) "$COLUMN_TYPE = ?" else null
        val selectionArgs = if (entityType != null) arrayOf(entityType) else null

        val cursor = db.query(
            TABLE_ENTITIES,
            arrayOf(COLUMN_ID, COLUMN_NAME, COLUMN_TYPE, COLUMN_EMBEDDING, COLUMN_DESCRIPTION, COLUMN_METADATA, COLUMN_LAST_MODIFIED),
            selection,
            selectionArgs,
            null, null, null
        )

        val results = mutableListOf<Pair<EntityWithScoreResult, Double>>()

        cursor.use {
            while (it.moveToNext()) {
                val embeddingBlob = it.getBlob(3)
                val docEmbedding = blobToEmbedding(embeddingBlob)
                val similarity = cosineSimilarity(queryEmbedding, docEmbedding)

                if (similarity >= threshold) {
                    val entity = EntityResult(
                        id = it.getString(0),
                        name = it.getString(1),
                        type = it.getString(2),
                        description = it.getString(4),
                        metadata = it.getString(5),
                        lastModified = it.getLong(6)
                    )

                    results.add(EntityWithScoreResult(entity = entity, score = similarity) to similarity)
                }
            }
        }

        return results
            .sortedByDescending { it.second }
            .take(topK)
            .map { it.first }
    }

    fun searchCommunitiesBySimilarity(
        queryEmbedding: List<Double>,
        topK: Int,
        level: Long?
    ): List<CommunityWithScoreResult> {
        val db = database ?: throw IllegalStateException("Database not initialized")

        if (detectedDimension != null && queryEmbedding.size != detectedDimension) {
            throw IllegalArgumentException(
                "Query embedding dimension mismatch: expected $detectedDimension, got ${queryEmbedding.size}"
            )
        }

        val selection = if (level != null) "$COLUMN_LEVEL = ?" else null
        val selectionArgs = if (level != null) arrayOf(level.toString()) else null

        val cursor = db.query(
            TABLE_COMMUNITIES,
            arrayOf(COLUMN_ID, COLUMN_LEVEL, COLUMN_SUMMARY, COLUMN_EMBEDDING, COLUMN_METADATA),
            selection,
            selectionArgs,
            null, null, null
        )

        val results = mutableListOf<Pair<CommunityWithScoreResult, Double>>()

        cursor.use {
            while (it.moveToNext()) {
                val embeddingBlob = it.getBlob(3)
                val docEmbedding = blobToEmbedding(embeddingBlob)
                val similarity = cosineSimilarity(queryEmbedding, docEmbedding)

                val communityId = it.getString(0)
                val entityIds = getEntityIdsForCommunity(communityId)

                val community = CommunityResult(
                    id = communityId,
                    level = it.getLong(1),
                    summary = it.getString(2),
                    entityIds = entityIds,
                    metadata = it.getString(4)
                )

                results.add(CommunityWithScoreResult(community = community, score = similarity) to similarity)
            }
        }

        return results
            .sortedByDescending { it.second }
            .take(topK)
            .map { it.first }
    }

    // MARK: - Statistics

    fun getStats(): GraphStats {
        val db = database ?: throw IllegalStateException("Database not initialized")

        val entityCount = db.rawQuery("SELECT COUNT(*) FROM $TABLE_ENTITIES", null).use {
            if (it.moveToFirst()) it.getLong(0) else 0L
        }

        val relationshipCount = db.rawQuery("SELECT COUNT(*) FROM $TABLE_RELATIONSHIPS", null).use {
            if (it.moveToFirst()) it.getLong(0) else 0L
        }

        val communityCount = db.rawQuery("SELECT COUNT(*) FROM $TABLE_COMMUNITIES", null).use {
            if (it.moveToFirst()) it.getLong(0) else 0L
        }

        val maxLevel = db.rawQuery("SELECT MAX($COLUMN_LEVEL) FROM $TABLE_COMMUNITIES", null).use {
            if (it.moveToFirst()) it.getLong(0) else 0L
        }

        return GraphStats(
            entityCount = entityCount,
            relationshipCount = relationshipCount,
            communityCount = communityCount,
            maxCommunityLevel = maxLevel,
            vectorDimension = (detectedDimension ?: 0).toLong()
        )
    }

    fun clear() {
        val db = database ?: throw IllegalStateException("Database not initialized")

        db.delete(TABLE_ENTITY_COMMUNITIES, null, null)
        db.delete(TABLE_COMMUNITIES, null, null)
        db.delete(TABLE_RELATIONSHIPS, null, null)
        db.delete(TABLE_ENTITIES, null, null)

        detectedDimension = null
    }

    fun close() {
        database?.close()
        database = null
        dbHelper?.close()
        dbHelper = null
        detectedDimension = null
    }

    // MARK: - Private Utilities

    private fun cosineSimilarity(a: List<Double>, b: List<Double>): Double {
        if (a.size != b.size) return 0.0

        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0

        for (i in a.indices) {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        return if (normA != 0.0 && normB != 0.0) {
            dotProduct / (sqrt(normA) * sqrt(normB))
        } else 0.0
    }

    private fun embeddingToBlob(embedding: List<Double>): ByteArray {
        val buffer = java.nio.ByteBuffer.allocate(embedding.size * 4)
        buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        embedding.forEach { buffer.putFloat(it.toFloat()) }
        return buffer.array()
    }

    private fun blobToEmbedding(blob: ByteArray): List<Double> {
        val buffer = java.nio.ByteBuffer.wrap(blob)
        buffer.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        return (0 until blob.size / 4).map {
            buffer.getFloat(it * 4).toDouble()
        }
    }
}
