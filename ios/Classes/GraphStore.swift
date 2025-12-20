import Foundation
import SQLite3

/// iOS GraphStore implementation for GraphRAG
/// Stores entities, relationships, and communities with embeddings in SQLite
class GraphStore {

    // MARK: - Properties

    private var db: OpaquePointer?
    private var dimension: Int?
    private var detectedDimension: Int?

    // Database schema version
    private static let databaseVersion = 1

    // Entity table
    private static let tableEntities = "entities"
    private static let columnId = "id"
    private static let columnName = "name"
    private static let columnType = "type"
    private static let columnEmbedding = "embedding"
    private static let columnDescription = "description"
    private static let columnMetadata = "metadata"
    private static let columnLastModified = "last_modified"
    private static let columnCreatedAt = "created_at"

    // Relationship table
    private static let tableRelationships = "relationships"
    private static let columnSourceId = "source_id"
    private static let columnTargetId = "target_id"
    private static let columnWeight = "weight"
    // Uses columnId, columnType, columnMetadata from entities

    // Community table
    private static let tableCommunities = "communities"
    private static let columnLevel = "level"
    private static let columnSummary = "summary"
    // Uses columnId, columnEmbedding, columnMetadata

    // Entity-Community membership table
    private static let tableEntityCommunities = "entity_communities"
    private static let columnEntityId = "entity_id"
    private static let columnCommunityId = "community_id"

    // MARK: - Initialization

    /// Initialize GraphStore with optional dimension
    /// - Parameter dimension: Expected embedding dimension (nil = auto-detect)
    init(dimension: Int? = nil) {
        self.dimension = dimension
    }

    /// Initialize database at specified path
    func initialize(databasePath: String) throws {
        // Close existing connection if any
        close()

        // Open SQLite database
        if sqlite3_open(databasePath, &db) != SQLITE_OK {
            throw GraphStoreError.databaseOpenFailed("Failed to open database at: \(databasePath)")
        }

        // Enable foreign keys
        if sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil) != SQLITE_OK {
            throw GraphStoreError.tableCreationFailed("Failed to enable foreign keys")
        }

        // Create tables
        try createTables()
    }

    // MARK: - Entity Methods

    /// Add entity with embedding to graph store
    func addEntity(
        id: String,
        name: String,
        type: String,
        embedding: [Double],
        description: String?,
        metadata: String?,
        lastModified: Int
    ) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        // Auto-detect dimension from first entity
        if detectedDimension == nil {
            detectedDimension = dimension ?? embedding.count

            if let expectedDim = dimension, expectedDim != embedding.count {
                throw GraphStoreError.dimensionMismatch(
                    expected: expectedDim,
                    actual: embedding.count
                )
            }
        }

        // Validate dimension consistency
        if embedding.count != detectedDimension {
            throw GraphStoreError.dimensionMismatch(
                expected: detectedDimension!,
                actual: embedding.count
            )
        }

        let embeddingBlob = embeddingToBlob(embedding)

        let insertSQL = """
        INSERT OR REPLACE INTO \(Self.tableEntities)
        (\(Self.columnId), \(Self.columnName), \(Self.columnType), \(Self.columnEmbedding),
         \(Self.columnDescription), \(Self.columnMetadata), \(Self.columnLastModified))
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (type as NSString).utf8String, -1, nil)

            embeddingBlob.withUnsafeBytes { ptr in
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(embeddingBlob.count), SQLITE_TRANSIENT)
            }

            if let description = description {
                sqlite3_bind_text(stmt, 5, (description as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let metadata = metadata {
                sqlite3_bind_text(stmt, 6, (metadata as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            sqlite3_bind_int64(stmt, 7, Int64(lastModified))

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.insertFailed("Failed to insert entity")
            }
        } else {
            throw GraphStoreError.insertFailed("Failed to prepare insert statement")
        }

        sqlite3_finalize(stmt)
    }

    /// Update existing entity
    func updateEntity(
        id: String,
        name: String?,
        type: String?,
        embedding: [Double]?,
        description: String?,
        metadata: String?,
        lastModified: Int?
    ) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        var setClauses: [String] = []
        var bindings: [(Int, Any?)] = []
        var bindIndex = 1

        if let name = name {
            setClauses.append("\(Self.columnName) = ?")
            bindings.append((bindIndex, name))
            bindIndex += 1
        }

        if let type = type {
            setClauses.append("\(Self.columnType) = ?")
            bindings.append((bindIndex, type))
            bindIndex += 1
        }

        if let embedding = embedding {
            if let detectedDim = detectedDimension, embedding.count != detectedDim {
                throw GraphStoreError.dimensionMismatch(
                    expected: detectedDim,
                    actual: embedding.count
                )
            }
            setClauses.append("\(Self.columnEmbedding) = ?")
            bindings.append((bindIndex, embeddingToBlob(embedding)))
            bindIndex += 1
        }

        if description != nil {
            setClauses.append("\(Self.columnDescription) = ?")
            bindings.append((bindIndex, description))
            bindIndex += 1
        }

        if metadata != nil {
            setClauses.append("\(Self.columnMetadata) = ?")
            bindings.append((bindIndex, metadata))
            bindIndex += 1
        }

        if let lastModified = lastModified {
            setClauses.append("\(Self.columnLastModified) = ?")
            bindings.append((bindIndex, lastModified))
            bindIndex += 1
        }

        guard !setClauses.isEmpty else { return }

        let updateSQL = """
        UPDATE \(Self.tableEntities)
        SET \(setClauses.joined(separator: ", "))
        WHERE \(Self.columnId) = ?;
        """

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            for (index, value) in bindings {
                if let str = value as? String {
                    sqlite3_bind_text(stmt, Int32(index), (str as NSString).utf8String, -1, nil)
                } else if let data = value as? Data {
                    data.withUnsafeBytes { ptr in
                        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                        sqlite3_bind_blob(stmt, Int32(index), ptr.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                } else if let intVal = value as? Int {
                    sqlite3_bind_int64(stmt, Int32(index), Int64(intVal))
                } else {
                    sqlite3_bind_null(stmt, Int32(index))
                }
            }

            sqlite3_bind_text(stmt, Int32(bindIndex), (id as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.updateFailed("Failed to update entity")
            }
        } else {
            throw GraphStoreError.updateFailed("Failed to prepare update statement")
        }

        sqlite3_finalize(stmt)
    }

    /// Delete entity by ID
    func deleteEntity(id: String) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        // Delete from entity_communities first (foreign key)
        let deleteECSQL = "DELETE FROM \(Self.tableEntityCommunities) WHERE \(Self.columnEntityId) = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, deleteECSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Delete relationships involving this entity
        let deleteRelSQL = """
        DELETE FROM \(Self.tableRelationships)
        WHERE \(Self.columnSourceId) = ? OR \(Self.columnTargetId) = ?;
        """

        if sqlite3_prepare_v2(db, deleteRelSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Delete entity
        let deleteSQL = "DELETE FROM \(Self.tableEntities) WHERE \(Self.columnId) = ?;"

        if sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.deleteFailed("Failed to delete entity")
            }
        }

        sqlite3_finalize(stmt)
    }

    /// Get entity by ID
    func getEntity(id: String) throws -> EntityResult? {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let querySQL = """
        SELECT \(Self.columnId), \(Self.columnName), \(Self.columnType),
               \(Self.columnDescription), \(Self.columnMetadata), \(Self.columnLastModified)
        FROM \(Self.tableEntities)
        WHERE \(Self.columnId) = ?;
        """

        var stmt: OpaquePointer?
        var result: EntityResult? = nil

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_ROW {
                result = extractEntityFromRow(stmt)
            }
        }

        sqlite3_finalize(stmt)
        return result
    }

    /// Get entities by type
    func getEntitiesByType(type: String) throws -> [EntityResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let querySQL = """
        SELECT \(Self.columnId), \(Self.columnName), \(Self.columnType),
               \(Self.columnDescription), \(Self.columnMetadata), \(Self.columnLastModified)
        FROM \(Self.tableEntities)
        WHERE \(Self.columnType) = ?;
        """

        var stmt: OpaquePointer?
        var results: [EntityResult] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (type as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let entity = extractEntityFromRow(stmt) {
                    results.append(entity)
                }
            }
        }

        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - Relationship Methods

    /// Add relationship between entities
    func addRelationship(
        id: String,
        sourceId: String,
        targetId: String,
        type: String,
        weight: Double,
        metadata: String?
    ) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let insertSQL = """
        INSERT OR REPLACE INTO \(Self.tableRelationships)
        (\(Self.columnId), \(Self.columnSourceId), \(Self.columnTargetId),
         \(Self.columnType), \(Self.columnWeight), \(Self.columnMetadata))
        VALUES (?, ?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (sourceId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (targetId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (type as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, weight)

            if let metadata = metadata {
                sqlite3_bind_text(stmt, 6, (metadata as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.insertFailed("Failed to insert relationship")
            }
        } else {
            throw GraphStoreError.insertFailed("Failed to prepare relationship insert")
        }

        sqlite3_finalize(stmt)
    }

    /// Delete relationship by ID
    func deleteRelationship(id: String) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let deleteSQL = "DELETE FROM \(Self.tableRelationships) WHERE \(Self.columnId) = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.deleteFailed("Failed to delete relationship")
            }
        }

        sqlite3_finalize(stmt)
    }

    /// Get relationships for an entity (both incoming and outgoing)
    func getRelationships(entityId: String) throws -> [RelationshipResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let querySQL = """
        SELECT \(Self.columnId), \(Self.columnSourceId), \(Self.columnTargetId),
               \(Self.columnType), \(Self.columnWeight), \(Self.columnMetadata)
        FROM \(Self.tableRelationships)
        WHERE \(Self.columnSourceId) = ? OR \(Self.columnTargetId) = ?;
        """

        var stmt: OpaquePointer?
        var results: [RelationshipResult] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (entityId as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (entityId as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let sourceId = String(cString: sqlite3_column_text(stmt, 1))
                let targetId = String(cString: sqlite3_column_text(stmt, 2))
                let type = String(cString: sqlite3_column_text(stmt, 3))
                let weight = sqlite3_column_double(stmt, 4)

                var metadata: String? = nil
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                    metadata = String(cString: sqlite3_column_text(stmt, 5))
                }

                results.append(RelationshipResult(
                    id: id,
                    sourceId: sourceId,
                    targetId: targetId,
                    type: type,
                    weight: weight,
                    metadata: metadata
                ))
            }
        }

        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - Community Methods

    /// Add community with embedding
    func addCommunity(
        id: String,
        level: Int,
        summary: String,
        entityIds: [String],
        embedding: [Double],
        metadata: String?
    ) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        // Validate embedding dimension
        if let detectedDim = detectedDimension, embedding.count != detectedDim {
            throw GraphStoreError.dimensionMismatch(
                expected: detectedDim,
                actual: embedding.count
            )
        }

        let embeddingBlob = embeddingToBlob(embedding)

        // Insert community
        let insertSQL = """
        INSERT OR REPLACE INTO \(Self.tableCommunities)
        (\(Self.columnId), \(Self.columnLevel), \(Self.columnSummary),
         \(Self.columnEmbedding), \(Self.columnMetadata))
        VALUES (?, ?, ?, ?, ?);
        """

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, Int64(level))
            sqlite3_bind_text(stmt, 3, (summary as NSString).utf8String, -1, nil)

            embeddingBlob.withUnsafeBytes { ptr in
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(embeddingBlob.count), SQLITE_TRANSIENT)
            }

            if let metadata = metadata {
                sqlite3_bind_text(stmt, 5, (metadata as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.insertFailed("Failed to insert community")
            }
        } else {
            throw GraphStoreError.insertFailed("Failed to prepare community insert")
        }

        sqlite3_finalize(stmt)

        // Delete existing entity-community mappings
        let deleteECSQL = "DELETE FROM \(Self.tableEntityCommunities) WHERE \(Self.columnCommunityId) = ?;"
        if sqlite3_prepare_v2(db, deleteECSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        // Insert entity-community mappings
        let insertECSQL = """
        INSERT INTO \(Self.tableEntityCommunities)
        (\(Self.columnEntityId), \(Self.columnCommunityId))
        VALUES (?, ?);
        """

        for entityId in entityIds {
            if sqlite3_prepare_v2(db, insertECSQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (entityId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Update community summary and embedding
    func updateCommunitySummary(id: String, summary: String, embedding: [Double]) throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        if let detectedDim = detectedDimension, embedding.count != detectedDim {
            throw GraphStoreError.dimensionMismatch(
                expected: detectedDim,
                actual: embedding.count
            )
        }

        let embeddingBlob = embeddingToBlob(embedding)

        let updateSQL = """
        UPDATE \(Self.tableCommunities)
        SET \(Self.columnSummary) = ?, \(Self.columnEmbedding) = ?
        WHERE \(Self.columnId) = ?;
        """

        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)

            embeddingBlob.withUnsafeBytes { ptr in
                let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embeddingBlob.count), SQLITE_TRANSIENT)
            }

            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw GraphStoreError.updateFailed("Failed to update community")
            }
        }

        sqlite3_finalize(stmt)
    }

    /// Get communities by level
    func getCommunitiesByLevel(level: Int) throws -> [CommunityResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let querySQL = """
        SELECT c.\(Self.columnId), c.\(Self.columnLevel), c.\(Self.columnSummary), c.\(Self.columnMetadata)
        FROM \(Self.tableCommunities) c
        WHERE c.\(Self.columnLevel) = ?;
        """

        var stmt: OpaquePointer?
        var results: [CommunityResult] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, Int64(level))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let level = Int(sqlite3_column_int64(stmt, 1))
                let summary = String(cString: sqlite3_column_text(stmt, 2))

                var metadata: String? = nil
                if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                    metadata = String(cString: sqlite3_column_text(stmt, 3))
                }

                // Get entity IDs for this community
                let entityIds = try getEntityIdsForCommunity(communityId: id)

                results.append(CommunityResult(
                    id: id,
                    level: Int64(level),
                    summary: summary,
                    entityIds: entityIds,
                    metadata: metadata
                ))
            }
        }

        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - Graph Traversal Methods

    /// Get entity neighbors up to specified depth
    func getEntityNeighbors(entityId: String, depth: Int, relationshipType: String?) throws -> [EntityResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        var visited: Set<String> = [entityId]
        var currentLevel: Set<String> = [entityId]
        var results: [EntityResult] = []

        for _ in 0..<depth {
            var nextLevel: Set<String> = []

            for currentId in currentLevel {
                // Get neighbors from relationships
                var querySQL = """
                SELECT DISTINCT
                    CASE
                        WHEN r.\(Self.columnSourceId) = ? THEN r.\(Self.columnTargetId)
                        ELSE r.\(Self.columnSourceId)
                    END as neighbor_id
                FROM \(Self.tableRelationships) r
                WHERE (r.\(Self.columnSourceId) = ? OR r.\(Self.columnTargetId) = ?)
                """

                if let relType = relationshipType {
                    querySQL += " AND r.\(Self.columnType) = '\(relType)'"
                }

                var stmt: OpaquePointer?

                if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (currentId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (currentId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (currentId as NSString).utf8String, -1, nil)

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let neighborId = String(cString: sqlite3_column_text(stmt, 0))
                        if !visited.contains(neighborId) {
                            visited.insert(neighborId)
                            nextLevel.insert(neighborId)
                        }
                    }
                }

                sqlite3_finalize(stmt)
            }

            currentLevel = nextLevel
        }

        // Fetch entity details for all visited nodes (except starting node)
        visited.remove(entityId)
        for visitedId in visited {
            if let entity = try getEntity(id: visitedId) {
                results.append(entity)
            }
        }

        return results
    }

    // MARK: - Similarity Search Methods

    /// Search entities by embedding similarity
    func searchEntitiesBySimilarity(
        queryEmbedding: [Double],
        topK: Int,
        threshold: Double,
        entityType: String?
    ) throws -> [EntityWithScoreResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        if let detectedDim = detectedDimension, queryEmbedding.count != detectedDim {
            throw GraphStoreError.dimensionMismatch(
                expected: detectedDim,
                actual: queryEmbedding.count
            )
        }

        var querySQL = """
        SELECT \(Self.columnId), \(Self.columnName), \(Self.columnType),
               \(Self.columnEmbedding), \(Self.columnDescription),
               \(Self.columnMetadata), \(Self.columnLastModified)
        FROM \(Self.tableEntities)
        """

        if let type = entityType {
            querySQL += " WHERE \(Self.columnType) = '\(type)'"
        }

        var stmt: OpaquePointer?
        var results: [(result: EntityWithScoreResult, score: Double)] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let type = String(cString: sqlite3_column_text(stmt, 2))

                // Extract embedding BLOB
                if let embeddingBlob = sqlite3_column_blob(stmt, 3) {
                    let embeddingSize = sqlite3_column_bytes(stmt, 3)

                    var embeddingData = Data(count: Int(embeddingSize))
                    embeddingData.withUnsafeMutableBytes { destPtr in
                        destPtr.copyMemory(from: UnsafeRawBufferPointer(start: embeddingBlob, count: Int(embeddingSize)))
                    }

                    let docEmbedding = blobToEmbedding(embeddingData)
                    let similarity = VectorUtils.cosineSimilarity(queryEmbedding, docEmbedding)

                    if similarity >= threshold {
                        var description: String? = nil
                        if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                            description = String(cString: sqlite3_column_text(stmt, 4))
                        }

                        var metadata: String? = nil
                        if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                            metadata = String(cString: sqlite3_column_text(stmt, 5))
                        }

                        let lastModified = Int(sqlite3_column_int64(stmt, 6))

                        let entity = EntityResult(
                            id: id,
                            name: name,
                            type: type,
                            description: description,
                            metadata: metadata,
                            lastModified: Int64(lastModified)
                        )

                        results.append((
                            result: EntityWithScoreResult(entity: entity, score: similarity),
                            score: similarity
                        ))
                    }
                }
            }
        }

        sqlite3_finalize(stmt)

        return results
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.result }
    }

    /// Search communities by embedding similarity
    func searchCommunitiesBySimilarity(
        queryEmbedding: [Double],
        topK: Int,
        level: Int?
    ) throws -> [CommunityWithScoreResult] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        if let detectedDim = detectedDimension, queryEmbedding.count != detectedDim {
            throw GraphStoreError.dimensionMismatch(
                expected: detectedDim,
                actual: queryEmbedding.count
            )
        }

        var querySQL = """
        SELECT \(Self.columnId), \(Self.columnLevel), \(Self.columnSummary),
               \(Self.columnEmbedding), \(Self.columnMetadata)
        FROM \(Self.tableCommunities)
        """

        if let lvl = level {
            querySQL += " WHERE \(Self.columnLevel) = \(lvl)"
        }

        var stmt: OpaquePointer?
        var results: [(result: CommunityWithScoreResult, score: Double)] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let level = Int(sqlite3_column_int64(stmt, 1))
                let summary = String(cString: sqlite3_column_text(stmt, 2))

                // Extract embedding BLOB
                if let embeddingBlob = sqlite3_column_blob(stmt, 3) {
                    let embeddingSize = sqlite3_column_bytes(stmt, 3)

                    var embeddingData = Data(count: Int(embeddingSize))
                    embeddingData.withUnsafeMutableBytes { destPtr in
                        destPtr.copyMemory(from: UnsafeRawBufferPointer(start: embeddingBlob, count: Int(embeddingSize)))
                    }

                    let docEmbedding = blobToEmbedding(embeddingData)
                    let similarity = VectorUtils.cosineSimilarity(queryEmbedding, docEmbedding)

                    var metadata: String? = nil
                    if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                        metadata = String(cString: sqlite3_column_text(stmt, 4))
                    }

                    // Get entity IDs
                    let entityIds = try getEntityIdsForCommunity(communityId: id)

                    let community = CommunityResult(
                        id: id,
                        level: Int64(level),
                        summary: summary,
                        entityIds: entityIds,
                        metadata: metadata
                    )

                    results.append((
                        result: CommunityWithScoreResult(community: community, score: similarity),
                        score: similarity
                    ))
                }
            }
        }

        sqlite3_finalize(stmt)

        return results
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.result }
    }

    // MARK: - Statistics

    /// Get graph store statistics
    func getStats() throws -> GraphStats {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        // Count entities
        var entityCount: Int64 = 0
        var stmt: OpaquePointer?
        let entityCountSQL = "SELECT COUNT(*) FROM \(Self.tableEntities);"
        if sqlite3_prepare_v2(db, entityCountSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                entityCount = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        // Count relationships
        var relationshipCount: Int64 = 0
        let relCountSQL = "SELECT COUNT(*) FROM \(Self.tableRelationships);"
        if sqlite3_prepare_v2(db, relCountSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                relationshipCount = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        // Count communities
        var communityCount: Int64 = 0
        let commCountSQL = "SELECT COUNT(*) FROM \(Self.tableCommunities);"
        if sqlite3_prepare_v2(db, commCountSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                communityCount = sqlite3_column_int64(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)

        // Get max community level
        var maxLevel: Int64 = 0
        let maxLevelSQL = "SELECT MAX(\(Self.columnLevel)) FROM \(Self.tableCommunities);"
        if sqlite3_prepare_v2(db, maxLevelSQL, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                    maxLevel = sqlite3_column_int64(stmt, 0)
                }
            }
        }
        sqlite3_finalize(stmt)

        return GraphStats(
            entityCount: entityCount,
            relationshipCount: relationshipCount,
            communityCount: communityCount,
            maxCommunityLevel: maxLevel,
            vectorDimension: Int64(detectedDimension ?? 0)
        )
    }

    /// Clear all data from graph store
    func clear() throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        // Clear in order (respecting foreign keys)
        let tables = [
            Self.tableEntityCommunities,
            Self.tableCommunities,
            Self.tableRelationships,
            Self.tableEntities
        ]

        for table in tables {
            let deleteSQL = "DELETE FROM \(table);"
            if sqlite3_exec(db, deleteSQL, nil, nil, nil) != SQLITE_OK {
                throw GraphStoreError.deleteFailed("Failed to clear \(table)")
            }
        }

        detectedDimension = nil
    }

    /// Close database connection
    func close() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // MARK: - Private Methods

    private func createTables() throws {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let createEntitiesSQL = """
        CREATE TABLE IF NOT EXISTS \(Self.tableEntities) (
            \(Self.columnId) TEXT PRIMARY KEY,
            \(Self.columnName) TEXT NOT NULL,
            \(Self.columnType) TEXT NOT NULL,
            \(Self.columnEmbedding) BLOB NOT NULL,
            \(Self.columnDescription) TEXT,
            \(Self.columnMetadata) TEXT,
            \(Self.columnLastModified) INTEGER NOT NULL,
            \(Self.columnCreatedAt) INTEGER DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_entities_type ON \(Self.tableEntities)(\(Self.columnType));
        CREATE INDEX IF NOT EXISTS idx_entities_last_modified ON \(Self.tableEntities)(\(Self.columnLastModified));
        """

        let createRelationshipsSQL = """
        CREATE TABLE IF NOT EXISTS \(Self.tableRelationships) (
            \(Self.columnId) TEXT PRIMARY KEY,
            \(Self.columnSourceId) TEXT NOT NULL,
            \(Self.columnTargetId) TEXT NOT NULL,
            \(Self.columnType) TEXT NOT NULL,
            \(Self.columnWeight) REAL DEFAULT 1.0,
            \(Self.columnMetadata) TEXT,
            \(Self.columnCreatedAt) INTEGER DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY (\(Self.columnSourceId)) REFERENCES \(Self.tableEntities)(\(Self.columnId)),
            FOREIGN KEY (\(Self.columnTargetId)) REFERENCES \(Self.tableEntities)(\(Self.columnId))
        );
        CREATE INDEX IF NOT EXISTS idx_rel_source ON \(Self.tableRelationships)(\(Self.columnSourceId));
        CREATE INDEX IF NOT EXISTS idx_rel_target ON \(Self.tableRelationships)(\(Self.columnTargetId));
        CREATE INDEX IF NOT EXISTS idx_rel_type ON \(Self.tableRelationships)(\(Self.columnType));
        """

        let createCommunitiesSQL = """
        CREATE TABLE IF NOT EXISTS \(Self.tableCommunities) (
            \(Self.columnId) TEXT PRIMARY KEY,
            \(Self.columnLevel) INTEGER NOT NULL,
            \(Self.columnSummary) TEXT NOT NULL,
            \(Self.columnEmbedding) BLOB NOT NULL,
            \(Self.columnMetadata) TEXT,
            \(Self.columnCreatedAt) INTEGER DEFAULT (strftime('%s', 'now'))
        );
        CREATE INDEX IF NOT EXISTS idx_comm_level ON \(Self.tableCommunities)(\(Self.columnLevel));
        """

        let createEntityCommunitiesSQL = """
        CREATE TABLE IF NOT EXISTS \(Self.tableEntityCommunities) (
            \(Self.columnEntityId) TEXT NOT NULL,
            \(Self.columnCommunityId) TEXT NOT NULL,
            PRIMARY KEY (\(Self.columnEntityId), \(Self.columnCommunityId)),
            FOREIGN KEY (\(Self.columnEntityId)) REFERENCES \(Self.tableEntities)(\(Self.columnId)),
            FOREIGN KEY (\(Self.columnCommunityId)) REFERENCES \(Self.tableCommunities)(\(Self.columnId))
        );
        """

        let tables = [createEntitiesSQL, createRelationshipsSQL, createCommunitiesSQL, createEntityCommunitiesSQL]

        for sql in tables {
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                throw GraphStoreError.tableCreationFailed("Failed to create tables")
            }
        }
    }

    private func extractEntityFromRow(_ stmt: OpaquePointer?) -> EntityResult? {
        guard let stmt = stmt else { return nil }

        let id = String(cString: sqlite3_column_text(stmt, 0))
        let name = String(cString: sqlite3_column_text(stmt, 1))
        let type = String(cString: sqlite3_column_text(stmt, 2))

        var description: String? = nil
        if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
            description = String(cString: sqlite3_column_text(stmt, 3))
        }

        var metadata: String? = nil
        if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
            metadata = String(cString: sqlite3_column_text(stmt, 4))
        }

        let lastModified = Int(sqlite3_column_int64(stmt, 5))

        return EntityResult(
            id: id,
            name: name,
            type: type,
            description: description,
            metadata: metadata,
            lastModified: Int64(lastModified)
        )
    }

    private func getEntityIdsForCommunity(communityId: String) throws -> [String?] {
        guard let db = db else {
            throw GraphStoreError.databaseNotInitialized
        }

        let querySQL = """
        SELECT \(Self.columnEntityId)
        FROM \(Self.tableEntityCommunities)
        WHERE \(Self.columnCommunityId) = ?;
        """

        var stmt: OpaquePointer?
        var entityIds: [String?] = []

        if sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (communityId as NSString).utf8String, -1, nil)

            while sqlite3_step(stmt) == SQLITE_ROW {
                let entityId = String(cString: sqlite3_column_text(stmt, 0))
                entityIds.append(entityId)
            }
        }

        sqlite3_finalize(stmt)
        return entityIds
    }

    private func embeddingToBlob(_ embedding: [Double]) -> Data {
        var data = Data(count: embedding.count * 4)

        data.withUnsafeMutableBytes { ptr in
            let floatPtr = ptr.bindMemory(to: Float.self)
            for (i, value) in embedding.enumerated() {
                floatPtr[i] = Float(value)
            }
        }

        return data
    }

    private func blobToEmbedding(_ data: Data) -> [Double] {
        return data.withUnsafeBytes { ptr in
            let floatCount = ptr.count / MemoryLayout<Float>.stride
            let floatPtr = ptr.bindMemory(to: Float.self)
            return (0..<floatCount).map { Double(floatPtr[$0]) }
        }
    }

    deinit {
        close()
    }
}

// MARK: - Error Types

enum GraphStoreError: Error, LocalizedError {
    case databaseNotInitialized
    case databaseOpenFailed(String)
    case tableCreationFailed(String)
    case insertFailed(String)
    case updateFailed(String)
    case deleteFailed(String)
    case queryFailed(String)
    case dimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Database not initialized. Call initialize() first."
        case .databaseOpenFailed(let message):
            return "Failed to open database: \(message)"
        case .tableCreationFailed(let message):
            return "Failed to create table: \(message)"
        case .insertFailed(let message):
            return "Failed to insert: \(message)"
        case .updateFailed(let message):
            return "Failed to update: \(message)"
        case .deleteFailed(let message):
            return "Failed to delete: \(message)"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        case .dimensionMismatch(let expected, let actual):
            return "Embedding dimension mismatch: expected \(expected), got \(actual)"
        }
    }
}
