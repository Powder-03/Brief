//
//  HNService.swift
//  Brief
//
//  Hacker News Algolia service converting search feeds and item trees into unified models.
//

import Foundation

protocol HNServiceProtocol {
    func fetchFeed(query: FeedQuery, cursor: FeedCursor) async throws -> FeedPage
    func fetchComments(storyID: Int) async throws -> [ArticleComment]
}

final class HNService: HNServiceProtocol {
    private let apiClient: APIClientProtocol
    private let nowProvider: () -> Date

    init(
        apiClient: APIClientProtocol,
        nowProvider: @escaping () -> Date = { .now }
    ) {
        self.apiClient = apiClient
        self.nowProvider = nowProvider
    }

    func fetchFeed(query: FeedQuery, cursor: FeedCursor) async throws -> FeedPage {
        let requestTime = nowProvider()
        let endpoint = Endpoint.feed(query: query, cursor: cursor, now: requestTime)
        let response: HNSearchResponse = try await apiClient.request(endpoint)
        return await HNServiceMapper.mapFeedPage(
            response: response,
            query: query,
            cursor: cursor,
            now: requestTime
        )
    }

    func fetchComments(storyID: Int) async throws -> [ArticleComment] {
        let item: HNItem = try await apiClient.request(.item(id: storyID))
        return await HNServiceMapper.mapComments(from: item, maxDepth: AppConfig.maxCommentDepth)
    }
}

// MARK: - Off-Main-Actor Mapping

nonisolated enum HNServiceMapper {
    @concurrent
    static func mapFeedPage(
        response: HNSearchResponse,
        query: FeedQuery,
        cursor: FeedCursor,
        now: Date
    ) async -> FeedPage {
        let articles = response.hits.compactMap(mapArticle(from:))
        let (nextCursor, hasMore) = resolvePagination(
            response: response,
            mappedArticlesCount: articles.count,
            query: query,
            cursor: cursor,
            now: now
        )
        return FeedPage(
            articles: articles,
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    @concurrent
    static func mapComments(from rootItem: HNItem, maxDepth: Int) async -> [ArticleComment] {
        var flattened: [ArticleComment] = []
        appendComments(rootItem.children ?? [], depth: 0, maxDepth: maxDepth, into: &flattened)
        return flattened
    }

    private static func mapArticle(from hit: HNHit) -> Article? {
        guard let storyID = Int(hit.objectID) else {
            return nil
        }

        let rawTitle = (hit.title ?? hit.storyTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else {
            return nil
        }

        let decodedTitle = HTMLEntityDecoder.decode(rawTitle)
        let rawURLString = (hit.url ?? hit.storyURLString)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedURL = rawURLString.flatMap { candidate -> URL? in
            guard !candidate.isEmpty,
                  let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                return nil
            }
            return url
        }

        let kind: ArticleKind
        let domainLabel: String
        if let parsedURL, let host = parsedURL.host {
            kind = .externalLink
            domainLabel = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            kind = .selfPost
            domainLabel = "HN Post"
        }

        let authorName = hit.author?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAuthor = (authorName?.isEmpty == false) ? authorName! : "unknown"
        let createdAt = Date(timeIntervalSince1970: TimeInterval(hit.createdAtI ?? 0))

        return Article(
            id: storyID,
            title: decodedTitle,
            url: parsedURL,
            domainLabel: domainLabel,
            author: resolvedAuthor,
            points: max(0, hit.points ?? 0),
            commentCount: max(0, hit.numComments ?? 0),
            createdAt: createdAt,
            storyTextHTML: hit.storyText,
            kind: kind
        )
    }

    private static func resolvePagination(
        response: HNSearchResponse,
        mappedArticlesCount: Int,
        query: FeedQuery,
        cursor: FeedCursor,
        now: Date
    ) -> (FeedCursor?, Bool) {
        if !query.trimmedSearchText.isEmpty {
            let hasMore = canPaginateOffsetWindow(
                response: response,
                mappedArticlesCount: mappedArticlesCount
            )
            return (hasMore ? .searchPage(response.page + 1) : nil, hasMore)
        }

        switch query.tab {
        case .top:
            switch cursor {
            case .initial, .frontPage:
                if (response.page + 1) < response.nbPages {
                    return (.frontPage(page: response.page + 1), true)
                }
                let cutoff = Endpoint.popularArchiveStartTimestamp(relativeTo: now)
                return (.popularArchive(page: 0, minTimestamp: cutoff), true)

            case .popularArchive(_, let minTimestamp):
                let hasMore = canPaginateOffsetWindow(
                    response: response,
                    mappedArticlesCount: mappedArticlesCount
                )
                return (hasMore ? .popularArchive(page: response.page + 1, minTimestamp: minTimestamp) : nil, hasMore)

            case .beforeTimestamp, .searchPage:
                return (nil, false)
            }

        case .latest, .askHN, .showHN:
            guard !response.hits.isEmpty,
                  let oldestTimestamp = response.hits.compactMap(\.createdAtI).min(),
                  response.nbHits > response.hits.count else {
                return (nil, false)
            }
            return (.beforeTimestamp(oldestTimestamp), true)
        }
    }

    private static func canPaginateOffsetWindow(
        response: HNSearchResponse,
        mappedArticlesCount: Int
    ) -> Bool {
        guard mappedArticlesCount > 0, (response.page + 1) < response.nbPages else {
            return false
        }
        let perPage = max(1, response.hitsPerPage)
        let fetchedSoFar = (response.page + 1) * perPage
        let cappedMax = min(response.nbHits, AppConfig.algoliaMaxSearchWindow)
        return fetchedSoFar < cappedMax
    }

    private static func appendComments(
        _ items: [HNItem],
        depth: Int,
        maxDepth: Int,
        into output: inout [ArticleComment]
    ) {
        guard depth <= maxDepth else { return }

        for item in items {
            let trimmedAuthor = item.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let plainText = HTMLEntityDecoder.stripHTMLToPlainText(item.text ?? "")
            let isDeleted = trimmedAuthor.isEmpty || plainText.isEmpty
            let replies = item.children ?? []

            if isDeleted && replies.isEmpty {
                continue
            }

            let comment = ArticleComment(
                id: item.id,
                author: isDeleted ? "[deleted]" : trimmedAuthor,
                plainText: isDeleted ? "[deleted]" : plainText,
                createdAt: Date(timeIntervalSince1970: TimeInterval(item.createdAtI ?? 0)),
                depth: depth,
                isDeleted: isDeleted,
                childCount: replies.count
            )
            output.append(comment)

            if !replies.isEmpty && depth < maxDepth {
                appendComments(replies, depth: depth + 1, maxDepth: maxDepth, into: &output)
            }
        }
    }
}
