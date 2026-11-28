//
//  OfflineEntities.swift
//  Brief
//
//  SwiftData @Model schema, resilient container factory, and background @ModelActor worker.
//

import Foundation
import SwiftData

@Model
nonisolated final class CachedFeedItemEntity {
    @Attribute(.unique) var compositeKey: String
    var storyID: Int
    var feedKey: String
    var sortIndex: Int
    var title: String
    var urlString: String?
    var domainLabel: String
    var author: String
    var points: Int
    var commentCount: Int
    var createdAt: Date
    var storyTextHTML: String?
    var kindRaw: String
    var cachedAt: Date

    init(
        compositeKey: String,
        storyID: Int,
        feedKey: String,
        sortIndex: Int,
        title: String,
        urlString: String?,
        domainLabel: String,
        author: String,
        points: Int,
        commentCount: Int,
        createdAt: Date,
        storyTextHTML: String?,
        kindRaw: String,
        cachedAt: Date
    ) {
        self.compositeKey = compositeKey
        self.storyID = storyID
        self.feedKey = feedKey
        self.sortIndex = sortIndex
        self.title = title
        self.urlString = urlString
        self.domainLabel = domainLabel
        self.author = author
        self.points = points
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.storyTextHTML = storyTextHTML
        self.kindRaw = kindRaw
        self.cachedAt = cachedAt
    }
}

@Model
nonisolated final class SavedArticleEntity {
    @Attribute(.unique) var storyID: Int
    var title: String
    var urlString: String?
    var domainLabel: String
    var author: String
    var points: Int
    var commentCount: Int
    var createdAt: Date
    var storyTextHTML: String?
    var kindRaw: String
    var savedAt: Date
    var offlineStatusRaw: String
    var contentJSONData: Data?
    var plainTextIndex: String
    var excerpt: String
    var estimatedReadingMinutes: Int
    var heroImageRelativePath: String?
    var totalAssetBytes: Int64
    var lastErrorMessage: String?

    init(
        storyID: Int,
        title: String,
        urlString: String?,
        domainLabel: String,
        author: String,
        points: Int,
        commentCount: Int,
        createdAt: Date,
        storyTextHTML: String?,
        kindRaw: String,
        savedAt: Date,
        offlineStatusRaw: String,
        contentJSONData: Data? = nil,
        plainTextIndex: String,
        excerpt: String,
        estimatedReadingMinutes: Int = 1,
        heroImageRelativePath: String? = nil,
        totalAssetBytes: Int64 = 0,
        lastErrorMessage: String? = nil
    ) {
        self.storyID = storyID
        self.title = title
        self.urlString = urlString
        self.domainLabel = domainLabel
        self.author = author
        self.points = points
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.storyTextHTML = storyTextHTML
        self.kindRaw = kindRaw
        self.savedAt = savedAt
        self.offlineStatusRaw = offlineStatusRaw
        self.contentJSONData = contentJSONData
        self.plainTextIndex = plainTextIndex
        self.excerpt = excerpt
        self.estimatedReadingMinutes = estimatedReadingMinutes
        self.heroImageRelativePath = heroImageRelativePath
        self.totalAssetBytes = totalAssetBytes
        self.lastErrorMessage = lastErrorMessage
    }
}

@Model
nonisolated final class OfflineAssetEntity {
    @Attribute(.unique) var assetID: String
    var storyID: Int
    var remoteURLString: String
    var relativeLocalPath: String
    var mimeType: String
    var byteSize: Int64
    var downloadedAt: Date

    init(
        assetID: String,
        storyID: Int,
        remoteURLString: String,
        relativeLocalPath: String,
        mimeType: String,
        byteSize: Int64,
        downloadedAt: Date
    ) {
        self.assetID = assetID
        self.storyID = storyID
        self.remoteURLString = remoteURLString
        self.relativeLocalPath = relativeLocalPath
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.downloadedAt = downloadedAt
    }
}

@Model
nonisolated final class CachedCommentThreadEntity {
    @Attribute(.unique) var storyID: Int
    var commentsJSONData: Data
    var cachedAt: Date

    init(storyID: Int, commentsJSONData: Data, cachedAt: Date) {
        self.storyID = storyID
        self.commentsJSONData = commentsJSONData
        self.cachedAt = cachedAt
    }
}

nonisolated enum BriefModelContainerFactory {
    static func makeContainer(inMemory: Bool = false) -> (container: ModelContainer, warningMessage: String?) {
        let schema = Schema([
            CachedFeedItemEntity.self,
            SavedArticleEntity.self,
            OfflineAssetEntity.self,
            CachedCommentThreadEntity.self
        ])

        do {
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
            let container = try ModelContainer(for: schema, configurations: [config])
            return (container, nil)
        } catch {
            let fallbackConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                let fallback = try ModelContainer(for: schema, configurations: [fallbackConfig])
                return (
                    fallback,
                    "Offline database could not be opened on disk; using temporary in-memory storage."
                )
            } catch let fallbackError {
                fatalError("Unable to initialize SwiftData ModelContainer: \(fallbackError)")
            }
        }
    }
}

@ModelActor
actor OfflinePersistenceWorker {
    func upsertFeedPage(
        feedKey: String,
        articles: [Article],
        startingRank: Int,
        replaceExisting: Bool
    ) throws {
        if replaceExisting {
            let existingDescriptor = FetchDescriptor<CachedFeedItemEntity>(
                predicate: #Predicate { $0.feedKey == feedKey }
            )
            let existingRows = try modelContext.fetch(existingDescriptor)
            for row in existingRows {
                modelContext.delete(row)
            }
        }

        let now = Date.now
        for (offset, article) in articles.enumerated() {
            let key = "\(feedKey)::\(article.id)"
            let rank = startingRank + offset

            let existingDescriptor = FetchDescriptor<CachedFeedItemEntity>(
                predicate: #Predicate { $0.compositeKey == key }
            )
            if let existing = try modelContext.fetch(existingDescriptor).first {
                existing.sortIndex = rank
                existing.title = article.title
                existing.urlString = article.url?.absoluteString
                existing.domainLabel = article.domainLabel
                existing.author = article.author
                existing.points = article.points
                existing.commentCount = article.commentCount
                existing.createdAt = article.createdAt
                existing.storyTextHTML = article.storyTextHTML
                existing.kindRaw = article.kind.rawValue
                existing.cachedAt = now
            } else {
                let entity = CachedFeedItemEntity(
                    compositeKey: key,
                    storyID: article.id,
                    feedKey: feedKey,
                    sortIndex: rank,
                    title: article.title,
                    urlString: article.url?.absoluteString,
                    domainLabel: article.domainLabel,
                    author: article.author,
                    points: article.points,
                    commentCount: article.commentCount,
                    createdAt: article.createdAt,
                    storyTextHTML: article.storyTextHTML,
                    kindRaw: article.kind.rawValue,
                    cachedAt: now
                )
                modelContext.insert(entity)
            }
        }

        try pruneFeedCache(
            feedKey: feedKey,
            maxItems: AppConfig.maxCachedItemsPerTab,
            maxAgeDays: AppConfig.maxCachedAgeDays
        )
        try modelContext.save()
    }

    func fetchCachedFeed(feedKey: String, searchText: String) throws -> FeedPage {
        let descriptor = FetchDescriptor<CachedFeedItemEntity>(
            predicate: #Predicate { $0.feedKey == feedKey },
            sortBy: [SortDescriptor(\CachedFeedItemEntity.sortIndex, order: .forward)]
        )
        let rows = try modelContext.fetch(descriptor)
        let savedSnapshots = try fetchAllSavedSnapshots()
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        let filteredRows: [CachedFeedItemEntity]
        if trimmedSearch.isEmpty {
            filteredRows = rows
        } else {
            filteredRows = rows.filter { row in
                row.title.localizedCaseInsensitiveContains(trimmedSearch)
                    || row.domainLabel.localizedCaseInsensitiveContains(trimmedSearch)
                    || row.author.localizedCaseInsensitiveContains(trimmedSearch)
                    || (row.storyTextHTML?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
            }
        }

        let articles = filteredRows.map { row in
            let saved = savedSnapshots[row.storyID]
            return Article(
                id: row.storyID,
                title: row.title,
                url: row.urlString.flatMap(URL.init(string:)),
                domainLabel: row.domainLabel,
                author: row.author,
                points: row.points,
                commentCount: row.commentCount,
                createdAt: row.createdAt,
                storyTextHTML: row.storyTextHTML,
                kind: ArticleKind(rawValue: row.kindRaw) ?? .externalLink,
                isSaved: saved != nil,
                offlineStatus: saved?.article.offlineStatus ?? .none
            )
        }

        return FeedPage(
            articles: articles,
            nextCursor: nil,
            hasMore: false,
            isFromCache: true,
            cachedAt: filteredRows.map(\.cachedAt).max()
        )
    }

    func upsertSavedArticle(_ article: Article, status: OfflineStatus) throws -> SavedArticleSnapshot {
        let targetID = article.id
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.storyID == targetID }
        )

        let entity: SavedArticleEntity
        if let existing = try modelContext.fetch(descriptor).first {
            existing.title = article.title
            existing.urlString = article.url?.absoluteString
            existing.domainLabel = article.domainLabel
            existing.author = article.author
            existing.points = article.points
            existing.commentCount = article.commentCount
            existing.storyTextHTML = article.storyTextHTML
            existing.kindRaw = article.kind.rawValue
            existing.offlineStatusRaw = status.rawValue
            if status == .queued || status == .downloading {
                existing.lastErrorMessage = nil
            }
            entity = existing
        } else {
            let newEntity = SavedArticleEntity(
                storyID: article.id,
                title: article.title,
                urlString: article.url?.absoluteString,
                domainLabel: article.domainLabel,
                author: article.author,
                points: article.points,
                commentCount: article.commentCount,
                createdAt: article.createdAt,
                storyTextHTML: article.storyTextHTML,
                kindRaw: article.kind.rawValue,
                savedAt: .now,
                offlineStatusRaw: status.rawValue,
                plainTextIndex: "\(article.title)\n\(article.domainLabel)\n\(article.author)",
                excerpt: article.title
            )
            modelContext.insert(newEntity)
            entity = newEntity
        }

        try modelContext.save()
        return Self.snapshot(from: entity)
    }

    func resetInterruptedDownloadsToQueued() throws -> Int {
        let downloadingRaw = OfflineStatus.downloading.rawValue
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.offlineStatusRaw == downloadingRaw }
        )
        let stuck = try modelContext.fetch(descriptor)
        for item in stuck {
            item.offlineStatusRaw = OfflineStatus.queued.rawValue
        }
        if !stuck.isEmpty {
            try modelContext.save()
        }
        return stuck.count
    }

    func fetchArticles(withStatus status: OfflineStatus) throws -> [Article] {
        let statusRaw = status.rawValue
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.offlineStatusRaw == statusRaw },
            sortBy: [SortDescriptor(\SavedArticleEntity.savedAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(Self.article(from:))
    }

    func fetchSavedArticle(storyID: Int) throws -> Article? {
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        return try modelContext.fetch(descriptor).first.map(Self.article(from:))
    }

    func updateOfflineContent(
        storyID: Int,
        status: OfflineStatus,
        content: OfflineArticleContent?,
        assets: [OfflineAssetRecord],
        replaceAssets: Bool,
        errorMessage: String?
    ) throws -> SavedArticleSnapshot? {
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        guard let entity = try modelContext.fetch(descriptor).first else {
            return nil
        }

        entity.offlineStatusRaw = status.rawValue
        entity.lastErrorMessage = errorMessage

        if let content {
            entity.contentJSONData = try JSONCoders.encode(content)
            entity.plainTextIndex = content.plainTextIndex
            entity.excerpt = content.excerpt
            entity.estimatedReadingMinutes = content.estimatedReadingMinutes
            entity.heroImageRelativePath = content.heroImageRelativePath
        }

        if replaceAssets {
            let assetDescriptor = FetchDescriptor<OfflineAssetEntity>(
                predicate: #Predicate { $0.storyID == storyID }
            )
            for oldAsset in try modelContext.fetch(assetDescriptor) {
                modelContext.delete(oldAsset)
            }
            for record in assets {
                let assetEntity = OfflineAssetEntity(
                    assetID: record.assetID,
                    storyID: record.storyID,
                    remoteURLString: record.remoteURLString,
                    relativeLocalPath: record.relativeLocalPath,
                    mimeType: record.mimeType,
                    byteSize: record.byteSize,
                    downloadedAt: record.downloadedAt
                )
                modelContext.insert(assetEntity)
            }
            entity.totalAssetBytes = assets.reduce(0) { $0 + $1.byteSize }
        }

        try modelContext.save()
        return Self.snapshot(from: entity)
    }

    func deleteSavedArticle(storyID: Int) throws {
        let savedDescriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        for row in try modelContext.fetch(savedDescriptor) {
            modelContext.delete(row)
        }

        let assetDescriptor = FetchDescriptor<OfflineAssetEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        for row in try modelContext.fetch(assetDescriptor) {
            modelContext.delete(row)
        }

        let commentsDescriptor = FetchDescriptor<CachedCommentThreadEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        for row in try modelContext.fetch(commentsDescriptor) {
            modelContext.delete(row)
        }

        try modelContext.save()
    }

    func clearAllCachedImageMetadata() throws {
        let assets = try modelContext.fetch(FetchDescriptor<OfflineAssetEntity>())
        for asset in assets {
            modelContext.delete(asset)
        }

        let savedArticles = try modelContext.fetch(FetchDescriptor<SavedArticleEntity>())
        for article in savedArticles {
            article.totalAssetBytes = 0
            article.heroImageRelativePath = nil
            if let data = article.contentJSONData,
               let content = try? JSONDecoder().decode(OfflineArticleContent.self, from: data) {
                let updatedBlocks = content.blocks.map { block -> ContentBlock in
                    if case .image(let id, let assetID, let remoteURL, _, let caption) = block {
                        return .image(
                            id: id,
                            assetID: assetID,
                            remoteURL: remoteURL,
                            relativeLocalPath: nil,
                            caption: caption
                        )
                    }
                    return block
                }
                let strippedContent = OfflineArticleContent(
                    title: content.title,
                    author: content.author,
                    sourceURL: content.sourceURL,
                    heroImageAssetID: content.heroImageAssetID,
                    heroImageRemoteURL: content.heroImageRemoteURL,
                    heroImageRelativePath: nil,
                    blocks: updatedBlocks,
                    plainTextIndex: content.plainTextIndex,
                    excerpt: content.excerpt,
                    estimatedReadingMinutes: content.estimatedReadingMinutes,
                    isSparseOrBlocked: content.isSparseOrBlocked,
                    extractedAt: content.extractedAt
                )
                article.contentJSONData = try? JSONCoders.encode(strippedContent)
            }
        }

        try modelContext.save()
    }

    func fetchAllSavedSnapshots() throws -> [Int: SavedArticleSnapshot] {
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            sortBy: [SortDescriptor(\SavedArticleEntity.savedAt, order: .reverse)]
        )
        let rows = try modelContext.fetch(descriptor)
        var map: [Int: SavedArticleSnapshot] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            map[row.storyID] = Self.snapshot(from: row)
        }
        return map
    }

    func fetchOfflineContent(storyID: Int) throws -> OfflineArticleContent? {
        let descriptor = FetchDescriptor<SavedArticleEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        guard let entity = try modelContext.fetch(descriptor).first,
              let data = entity.contentJSONData else {
            return nil
        }
        return try JSONDecoder().decode(OfflineArticleContent.self, from: data)
    }

    func upsertComments(storyID: Int, comments: [ArticleComment]) throws {
        let encoded = try JSONCoders.encode(comments)
        let now = Date.now
        let descriptor = FetchDescriptor<CachedCommentThreadEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.commentsJSONData = encoded
            existing.cachedAt = now
        } else {
            modelContext.insert(
                CachedCommentThreadEntity(
                    storyID: storyID,
                    commentsJSONData: encoded,
                    cachedAt: now
                )
            )
        }
        try modelContext.save()
    }

    func fetchCachedComments(storyID: Int) throws -> ([ArticleComment], Date)? {
        let descriptor = FetchDescriptor<CachedCommentThreadEntity>(
            predicate: #Predicate { $0.storyID == storyID }
        )
        guard let entity = try modelContext.fetch(descriptor).first else {
            return nil
        }
        let comments = try JSONDecoder().decode([ArticleComment].self, from: entity.commentsJSONData)
        return (comments, entity.cachedAt)
    }

    // MARK: - Private Helpers

    private func pruneFeedCache(feedKey: String, maxItems: Int, maxAgeDays: Int) throws {
        let descriptor = FetchDescriptor<CachedFeedItemEntity>(
            predicate: #Predicate { $0.feedKey == feedKey },
            sortBy: [SortDescriptor(\CachedFeedItemEntity.sortIndex, order: .forward)]
        )
        let rows = try modelContext.fetch(descriptor)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: .now) ?? .distantPast

        for (index, row) in rows.enumerated() {
            if index >= maxItems || row.cachedAt < cutoffDate {
                modelContext.delete(row)
            }
        }
    }

    private static func article(from entity: SavedArticleEntity) -> Article {
        Article(
            id: entity.storyID,
            title: entity.title,
            url: entity.urlString.flatMap(URL.init(string:)),
            domainLabel: entity.domainLabel,
            author: entity.author,
            points: entity.points,
            commentCount: entity.commentCount,
            createdAt: entity.createdAt,
            storyTextHTML: entity.storyTextHTML,
            kind: ArticleKind(rawValue: entity.kindRaw) ?? .externalLink,
            isSaved: true,
            offlineStatus: OfflineStatus(rawValue: entity.offlineStatusRaw) ?? .queued
        )
    }

    private static func snapshot(from entity: SavedArticleEntity) -> SavedArticleSnapshot {
        SavedArticleSnapshot(
            article: article(from: entity),
            savedAt: entity.savedAt,
            estimatedReadingMinutes: entity.estimatedReadingMinutes,
            byteSize: entity.totalAssetBytes + Int64(entity.contentJSONData?.count ?? 0),
            excerpt: entity.excerpt,
            heroImageRelativePath: entity.heroImageRelativePath,
            lastErrorMessage: entity.lastErrorMessage
        )
    }
}
