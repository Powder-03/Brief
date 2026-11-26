//
//  FeedTabViewModel.swift
//  Brief
//
//  Observable view model driving infinite-scroll discovery, debounced search,
//  tab/sort filtering, deduplication, and inline pagination retry.
//

import Foundation
import Observation

@Observable
final class FeedTabViewModel {
    enum PaginationState: Equatable {
        case idle
        case loadingInitial
        case loadingNextPage
        case exhausted
        case failedInitial(String)
        case failedPage(String)
    }

    private let hnService: HNServiceProtocol

    var articles: [Article] = []
    var query: FeedQuery = FeedQuery()
    var paginationState: PaginationState = .idle
    var refreshErrorMessage: String?
    var isShowingCachedData: Bool = false
    var lastCachedAt: Date?

    private var nextCursor: FeedCursor?
    private var seenStoryIDs: Set<Int> = []
    private var activeLoadTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var requestGeneration: Int = 0
    private var hasLoadedOnce: Bool = false

    init(hnService: HNServiceProtocol) {
        self.hnService = hnService
    }

    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        await loadInitialFeed(preserveExisting: false)
    }

    func selectTab(_ tab: FeedTab) {
        guard query.tab != tab else { return }
        query.tab = tab
        restartFeedLoad()
    }

    func selectSortMode(_ sortMode: FeedSortMode) {
        guard query.sortMode != sortMode else { return }
        query.sortMode = sortMode
        restartFeedLoad()
    }

    func updateSearchText(_ newText: String) {
        guard query.searchText != newText else { return }
        let previousTrimmed = query.trimmedSearchText
        query.searchText = newText
        let currentTrimmed = query.trimmedSearchText

        searchDebounceTask?.cancel()
        guard previousTrimmed != currentTrimmed else { return }

        if currentTrimmed.isEmpty {
            restartFeedLoad()
            return
        }

        let debounceDuration = AppConfig.searchDebounceMilliseconds
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceDuration))
            guard let self, !Task.isCancelled else { return }
            self.restartFeedLoad(cancelSearchTask: false)
        }
    }

    func refresh() async {
        searchDebounceTask?.cancel()
        await loadInitialFeed(preserveExisting: !articles.isEmpty)
    }

    func retryInitial() {
        restartFeedLoad()
    }

    func loadNextPageIfNeeded(currentArticleID: Int) {
        guard paginationState == .idle,
              let cursor = nextCursor,
              let index = articles.firstIndex(where: { $0.id == currentArticleID }),
              index >= articles.count - AppConfig.prefetchThreshold else {
            return
        }

        startNextPageLoad(cursor: cursor)
    }

    func retryNextPage() {
        guard case .failedPage = paginationState,
              let cursor = nextCursor else {
            return
        }

        startNextPageLoad(cursor: cursor)
    }

    // MARK: - Internal Loading Pipeline

    private func restartFeedLoad(cancelSearchTask: Bool = true) {
        if cancelSearchTask {
            searchDebounceTask?.cancel()
        }
        activeLoadTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        let activeQuery = query

        articles = []
        seenStoryIDs.removeAll()
        nextCursor = nil
        refreshErrorMessage = nil
        isShowingCachedData = false
        lastCachedAt = nil
        paginationState = .loadingInitial

        activeLoadTask = Task { [weak self] in
            await self?.performInitialLoad(
                query: activeQuery,
                generation: generation,
                preserveExisting: false
            )
        }
    }

    private func loadInitialFeed(preserveExisting: Bool) async {
        activeLoadTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        let activeQuery = query

        if !preserveExisting {
            articles = []
            seenStoryIDs.removeAll()
            nextCursor = nil
            isShowingCachedData = false
            lastCachedAt = nil
            paginationState = .loadingInitial
        }
        refreshErrorMessage = nil

        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performInitialLoad(
                query: activeQuery,
                generation: generation,
                preserveExisting: preserveExisting
            )
        }
        activeLoadTask = task
        await task.value
    }

    private func startNextPageLoad(cursor: FeedCursor) {
        activeLoadTask?.cancel()
        let generation = requestGeneration
        let activeQuery = query
        paginationState = .loadingNextPage

        activeLoadTask = Task { [weak self] in
            await self?.performNextPageLoad(
                query: activeQuery,
                cursor: cursor,
                generation: generation
            )
        }
    }

    private func performInitialLoad(
        query: FeedQuery,
        generation: Int,
        preserveExisting: Bool
    ) async {
        do {
            let page = try await hnService.fetchFeed(query: query, cursor: .initial)
            guard generation == requestGeneration, !Task.isCancelled else { return }

            var freshSeen: Set<Int> = []
            let deduped = page.articles.filter { freshSeen.insert($0.id).inserted }

            articles = deduped
            seenStoryIDs = freshSeen
            nextCursor = page.nextCursor
            refreshErrorMessage = nil
            isShowingCachedData = page.isFromCache
            lastCachedAt = page.cachedAt
            hasLoadedOnce = true
            paginationState = (page.hasMore && page.nextCursor != nil) ? .idle : .exhausted
        } catch is CancellationError {
            return
        } catch APIError.cancelled {
            return
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            if preserveExisting && !articles.isEmpty {
                refreshErrorMessage = error.localizedDescription
            } else {
                paginationState = .failedInitial(error.localizedDescription)
            }
        }
    }

    private func performNextPageLoad(
        query: FeedQuery,
        cursor: FeedCursor,
        generation: Int
    ) async {
        do {
            var page = try await hnService.fetchFeed(query: query, cursor: cursor)
            guard generation == requestGeneration, !Task.isCancelled else { return }

            var unseen = page.articles.filter { seenStoryIDs.insert($0.id).inserted }

            // Guard against chronological timestamp ties or full-page overlap stalling pagination.
            if unseen.isEmpty, page.hasMore, let followUpCursor = page.nextCursor {
                if let adjustedCursor = adjustedCursorForTieOrOverlap(
                    previousCursor: cursor,
                    returnedCursor: followUpCursor
                ) {
                    page = try await hnService.fetchFeed(query: query, cursor: adjustedCursor)
                    guard generation == requestGeneration, !Task.isCancelled else { return }
                    unseen = page.articles.filter { seenStoryIDs.insert($0.id).inserted }
                }
            }

            if !unseen.isEmpty {
                articles.append(contentsOf: unseen)
            }

            if unseen.isEmpty || !page.hasMore || page.nextCursor == nil {
                nextCursor = nil
                paginationState = .exhausted
            } else {
                nextCursor = page.nextCursor
                paginationState = .idle
            }
        } catch is CancellationError {
            return
        } catch APIError.cancelled {
            return
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            paginationState = .failedPage(error.localizedDescription)
        }
    }

    private func adjustedCursorForTieOrOverlap(
        previousCursor: FeedCursor,
        returnedCursor: FeedCursor
    ) -> FeedCursor? {
        if case .beforeTimestamp(let previousTS) = previousCursor,
           case .beforeTimestamp(let returnedTS) = returnedCursor,
           returnedTS >= previousTS,
           previousTS > 0 {
            return .beforeTimestamp(previousTS - 1)
        }
        return returnedCursor != previousCursor ? returnedCursor : nil
    }
}
