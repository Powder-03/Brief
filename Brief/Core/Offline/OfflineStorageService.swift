//
//  OfflineStorageService.swift
//  Brief
//
//  Coordinates SwiftData persistence, deduplicated offline article extraction,
//  bounded image downloads, crash recovery, and reactive snapshot streaming.
//

import Foundation
import SwiftData

protocol OfflineStorageServiceProtocol {
    func cacheFeedPage(feedKey: String, articles: [Article], startingRank: Int, replaceExisting: Bool) async
    func loadCachedFeed(feedKey: String, searchText: String) async -> FeedPage
    func saveArticle(_ article: Article) async
    func removeSavedArticle(storyID: Int) async
    func retryDownload(storyID: Int) async
    func retryAllFailed() async
    func recoverInterruptedDownloads() async
    func processQueuedDownloads() async
    func observeSavedSnapshots() -> AsyncStream<[Int: SavedArticleSnapshot]>
    func currentSavedSnapshots() async -> [Int: SavedArticleSnapshot]
    func loadOfflineContent(storyID: Int) async -> OfflineArticleContent?
    func saveComments(storyID: Int, comments: [ArticleComment]) async
    func loadCachedComments(storyID: Int) async -> ([ArticleComment], Date)?
    func resolveLocalImageURL(relativePath: String) -> URL
    func storageUsageBytes() async -> Int64
    func clearCachedImages() async
}

final class OfflineStorageService: OfflineStorageServiceProtocol {
    private let apiClient: APIClientProtocol
    private let hnService: HNServiceProtocol
    private let networkMonitor: NetworkMonitorProtocol
    private let fileStore: OfflineFileStore
    private let worker: OfflinePersistenceWorker

    private var inFlightTasks: [Int: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<[Int: SavedArticleSnapshot]>.Continuation] = [:]
    private var latestSnapshots: [Int: SavedArticleSnapshot] = [:]

    init(
        apiClient: APIClientProtocol,
        hnService: HNServiceProtocol,
        networkMonitor: NetworkMonitorProtocol,
        fileStore: OfflineFileStore = OfflineFileStore(),
        worker: OfflinePersistenceWorker
    ) {
        self.apiClient = apiClient
        self.hnService = hnService
        self.networkMonitor = networkMonitor
        self.fileStore = fileStore
        self.worker = worker
    }

    isolated deinit {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    // MARK: - Feed Cache

    func cacheFeedPage(
        feedKey: String,
        articles: [Article],
        startingRank: Int,
        replaceExisting: Bool
    ) async {
        try? await worker.upsertFeedPage(
            feedKey: feedKey,
            articles: articles,
            startingRank: startingRank,
            replaceExisting: replaceExisting
        )
    }

    func loadCachedFeed(feedKey: String, searchText: String) async -> FeedPage {
        (try? await worker.fetchCachedFeed(feedKey: feedKey, searchText: searchText))
            ?? FeedPage(articles: [], nextCursor: nil, hasMore: false, isFromCache: true)
    }

    // MARK: - Saved Articles & Downloads

    func saveArticle(_ article: Article) async {
        let isConnected = networkMonitor.currentStatus.isConnected
        let initialStatus: OfflineStatus = isConnected ? .downloading : .queued

        if let snapshot = try? await worker.upsertSavedArticle(article, status: initialStatus) {
            latestSnapshots[article.id] = snapshot
            broadcastSnapshots()
        }

        if isConnected {
            startDownload(for: article)
        }
    }

    func removeSavedArticle(storyID: Int) async {
        if let activeTask = inFlightTasks.removeValue(forKey: storyID) {
            activeTask.cancel()
            await activeTask.value
        }

        try? await worker.deleteSavedArticle(storyID: storyID)
        try? await fileStore.deleteFolder(for: storyID)
        latestSnapshots.removeValue(forKey: storyID)
        broadcastSnapshots()
    }

    func retryDownload(storyID: Int) async {
        guard let article = try? await worker.fetchSavedArticle(storyID: storyID) else { return }

        guard networkMonitor.currentStatus.isConnected else {
            if let updated = try? await worker.upsertSavedArticle(article, status: .queued) {
                latestSnapshots[storyID] = updated
                broadcastSnapshots()
            }
            return
        }

        if let updated = try? await worker.upsertSavedArticle(article, status: .downloading) {
            latestSnapshots[storyID] = updated
            broadcastSnapshots()
        }
        startDownload(for: article)
    }

    func retryAllFailed() async {
        let failedArticles = (try? await worker.fetchArticles(withStatus: .failed)) ?? []
        let partialArticles = (try? await worker.fetchArticles(withStatus: .partial)) ?? []
        for article in failedArticles + partialArticles {
            await retryDownload(storyID: article.id)
        }
    }

    func recoverInterruptedDownloads() async {
        _ = try? await worker.resetInterruptedDownloadsToQueued()
        await refreshAndBroadcastSnapshots()
        await processQueuedDownloads()
    }

    func processQueuedDownloads() async {
        guard networkMonitor.currentStatus == .online else { return }
        let queued = (try? await worker.fetchArticles(withStatus: .queued)) ?? []
        for article in queued {
            guard networkMonitor.currentStatus == .online else { break }
            if let updated = try? await worker.upsertSavedArticle(article, status: .downloading) {
                latestSnapshots[article.id] = updated
                broadcastSnapshots()
            }
            startDownload(for: article)
        }
    }

    func observeSavedSnapshots() -> AsyncStream<[Int: SavedArticleSnapshot]> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(latestSnapshots)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeContinuation(id: id)
                }
            }
        }
    }

    func currentSavedSnapshots() async -> [Int: SavedArticleSnapshot] {
        await refreshAndBroadcastSnapshots()
        return latestSnapshots
    }

    // MARK: - Reader & Assets

    func loadOfflineContent(storyID: Int) async -> OfflineArticleContent? {
        try? await worker.fetchOfflineContent(storyID: storyID)
    }

    func saveComments(storyID: Int, comments: [ArticleComment]) async {
        try? await worker.upsertComments(storyID: storyID, comments: comments)
    }

    func loadCachedComments(storyID: Int) async -> ([ArticleComment], Date)? {
        try? await worker.fetchCachedComments(storyID: storyID)
    }

    func resolveLocalImageURL(relativePath: String) -> URL {
        fileStore.resolveURL(relativePath: relativePath)
    }

    func storageUsageBytes() async -> Int64 {
        await fileStore.totalDiskUsageBytes()
    }

    func clearCachedImages() async {
        try? await fileStore.clearAll()
        try? await worker.clearAllCachedImageMetadata()
        await refreshAndBroadcastSnapshots()
    }

    // MARK: - Download Pipeline

    private func startDownload(for article: Article) {
        guard inFlightTasks[article.id] == nil else { return }

        let storyID = article.id
        inFlightTasks[storyID] = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performDownload(for: article)
            self.inFlightTasks.removeValue(forKey: storyID)
        }
    }

    private func performDownload(for article: Article) async {
        let storyID = article.id

        do {
            try Task.checkCancellation()

            // Pre-cache discussion thread concurrently where possible.
            async let commentCacheTask: Void = cacheCommentsIfOnline(storyID: storyID)

            let finalStatus: OfflineStatus
            let finalContent: OfflineArticleContent
            let savedAssets: [OfflineAssetRecord]
            let errorNote: String?

            if article.kind == .selfPost || article.url == nil {
                finalContent = await HTMLContentExtractor.extractSelfPost(
                    storyTextHTML: article.storyTextHTML ?? "",
                    title: article.title,
                    canonicalURL: article.canonicalDiscussionURL,
                    author: article.author
                )
                savedAssets = []
                finalStatus = .ready
                errorNote = nil
            } else if let externalURL = article.url {
                let (data, httpResponse) = try await apiClient.fetchData(
                    from: externalURL,
                    maxBytes: AppConfig.maxHTMLBytes
                )
                try Task.checkCancellation()

                if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                   !Self.isSupportedHTMLContentType(contentType) {
                    _ = await commentCacheTask
                    await persistFallbackStatus(
                        storyID: storyID,
                        status: .partial,
                        message: "Original page is not an HTML article (\(contentType))."
                    )
                    return
                }

                let extracted = try await HTMLContentExtractor.extract(
                    htmlData: data,
                    responseEncodingName: httpResponse.textEncodingName,
                    sourceURL: httpResponse.url ?? externalURL,
                    fallbackTitle: article.title,
                    fallbackAuthor: article.author
                )
                try Task.checkCancellation()

                let downloadedAssets = await downloadImagesBounded(
                    urls: extracted.inlineImageURLs,
                    storyID: storyID
                )
                try Task.checkCancellation()

                finalContent = Self.applyingDownloadedAssets(downloadedAssets, to: extracted.content)
                savedAssets = downloadedAssets
                finalStatus = finalContent.isSparseOrBlocked ? .partial : .ready
                errorNote = finalContent.isSparseOrBlocked
                    ? "Limited readable text was extracted; open original online for full view."
                    : nil
            } else {
                _ = await commentCacheTask
                return
            }

            _ = await commentCacheTask
            try Task.checkCancellation()

            guard (try? await worker.fetchSavedArticle(storyID: storyID)) != nil else {
                return
            }

            if let snapshot = try? await worker.updateOfflineContent(
                storyID: storyID,
                status: finalStatus,
                content: finalContent,
                assets: savedAssets,
                replaceAssets: true,
                errorMessage: errorNote
            ) {
                latestSnapshots[storyID] = snapshot
                broadcastSnapshots()
            }
        } catch is CancellationError {
            return
        } catch APIError.cancelled {
            return
        } catch {
            await cacheCommentsIfOnline(storyID: storyID)
            guard !Task.isCancelled,
                  (try? await worker.fetchSavedArticle(storyID: storyID)) != nil else {
                return
            }

            let fallbackStatus = Self.fallbackStatus(for: error)
            await persistFallbackStatus(
                storyID: storyID,
                status: fallbackStatus,
                message: error.localizedDescription
            )
        }
    }

    private func downloadImagesBounded(urls: [URL], storyID: Int) async -> [OfflineAssetRecord] {
        guard !urls.isEmpty else { return [] }

        let cappedURLs = Array(urls.prefix(AppConfig.maxImagesPerArticle))
        var results: [OfflineAssetRecord] = []
        var nextIndex = 0

        await withTaskGroup(of: OfflineAssetRecord?.self) { group in
            let initialBatch = min(AppConfig.maxConcurrentImageDownloads, cappedURLs.count)
            while nextIndex < initialBatch {
                let imageURL = cappedURLs[nextIndex]
                nextIndex += 1
                group.addTask { @MainActor [apiClient, fileStore] in
                    await Self.fetchAndStoreSingleImage(
                        url: imageURL,
                        storyID: storyID,
                        apiClient: apiClient,
                        fileStore: fileStore
                    )
                }
            }

            for await record in group {
                if let record {
                    results.append(record)
                }
                if nextIndex < cappedURLs.count && !Task.isCancelled {
                    let imageURL = cappedURLs[nextIndex]
                    nextIndex += 1
                    group.addTask { @MainActor [apiClient, fileStore] in
                        await Self.fetchAndStoreSingleImage(
                            url: imageURL,
                            storyID: storyID,
                            apiClient: apiClient,
                            fileStore: fileStore
                        )
                    }
                }
            }
        }

        return results
    }

    private static func fetchAndStoreSingleImage(
        url: URL,
        storyID: Int,
        apiClient: APIClientProtocol,
        fileStore: OfflineFileStore
    ) async -> OfflineAssetRecord? {
        do {
            let (data, response) = try await apiClient.fetchData(
                from: url,
                maxBytes: AppConfig.maxImageBytes
            )
            let mimeType = response.value(forHTTPHeaderField: "Content-Type")
            let assetID = HTMLContentExtractor.stableAssetID(for: url)
            return try await fileStore.saveImageData(
                data,
                storyID: storyID,
                assetID: assetID,
                remoteURLString: url.absoluteString,
                mimeType: mimeType
            )
        } catch {
            return nil
        }
    }

    private func cacheCommentsIfOnline(storyID: Int) async {
        guard networkMonitor.currentStatus.isConnected else { return }
        if let comments = try? await hnService.fetchComments(storyID: storyID) {
            try? await worker.upsertComments(storyID: storyID, comments: comments)
        }
    }

    private func persistFallbackStatus(
        storyID: Int,
        status: OfflineStatus,
        message: String
    ) async {
        if let snapshot = try? await worker.updateOfflineContent(
            storyID: storyID,
            status: status,
            content: nil,
            assets: [],
            replaceAssets: false,
            errorMessage: message
        ) {
            latestSnapshots[storyID] = snapshot
            broadcastSnapshots()
        }
    }

    private func refreshAndBroadcastSnapshots() async {
        if let refreshed = try? await worker.fetchAllSavedSnapshots() {
            latestSnapshots = refreshed
            broadcastSnapshots()
        }
    }

    private func broadcastSnapshots() {
        for continuation in continuations.values {
            continuation.yield(latestSnapshots)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // MARK: - Helpers

    private static func isSupportedHTMLContentType(_ contentType: String) -> Bool {
        let base = contentType.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty { return true }
        return base == "text/html" || base == "application/xhtml+xml" || base == "text/plain"
    }

    private static func applyingDownloadedAssets(
        _ assets: [OfflineAssetRecord],
        to content: OfflineArticleContent
    ) -> OfflineArticleContent {
        let byRemoteURL = Dictionary(
            assets.map { ($0.remoteURLString, $0.relativeLocalPath) },
            uniquingKeysWith: { first, _ in first }
        )

        let heroPath = content.heroImageRemoteURL.flatMap { byRemoteURL[$0.absoluteString] }
        let updatedBlocks = content.blocks.map { block -> ContentBlock in
            guard case .image(let id, let assetID, let remoteURL, _, let caption) = block else {
                return block
            }
            return .image(
                id: id,
                assetID: assetID,
                remoteURL: remoteURL,
                relativeLocalPath: byRemoteURL[remoteURL.absoluteString],
                caption: caption
            )
        }

        return OfflineArticleContent(
            title: content.title,
            author: content.author,
            sourceURL: content.sourceURL,
            heroImageAssetID: content.heroImageAssetID,
            heroImageRemoteURL: content.heroImageRemoteURL,
            heroImageRelativePath: heroPath,
            blocks: updatedBlocks,
            plainTextIndex: content.plainTextIndex,
            excerpt: content.excerpt,
            estimatedReadingMinutes: content.estimatedReadingMinutes,
            isSparseOrBlocked: content.isSparseOrBlocked,
            extractedAt: content.extractedAt
        )
    }

    private static func fallbackStatus(for error: Error) -> OfflineStatus {
        guard let apiError = error as? APIError else {
            return .failed
        }
        switch apiError {
        case .httpError(let statusCode, _) where [401, 403, 429, 451].contains(statusCode):
            return .partial
        case .extractionError:
            return .partial
        case .rateLimited:
            return .partial
        case .networkError, .timeout, .decodingError, .invalidURL, .httpError, .cancelled:
            return .failed
        }
    }
}
