//
//  FeedModels.swift
//  Brief
//
//  Feed tabs, pagination cursors, query parameters, and connectivity models.
//

import Foundation

nonisolated enum FeedTab: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case top
    case latest
    case askHN = "ask_hn"
    case showHN = "show_hn"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .top:
            return "Top"
        case .latest:
            return "Latest"
        case .askHN:
            return "Ask HN"
        case .showHN:
            return "Show HN"
        }
    }

    var algoliaTag: String {
        switch self {
        case .top, .latest:
            return "story"
        case .askHN:
            return "ask_hn"
        case .showHN:
            return "show_hn"
        }
    }

    var systemImage: String {
        switch self {
        case .top:
            return "flame"
        case .latest:
            return "clock"
        case .askHN:
            return "questionmark.bubble"
        case .showHN:
            return "sparkles"
        }
    }
}

nonisolated enum FeedSortMode: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case relevance
    case latest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relevance:
            return "Relevance"
        case .latest:
            return "Newest"
        }
    }
}

nonisolated enum FeedCursor: Equatable, Hashable, Sendable {
    case initial
    case frontPage(page: Int)
    case popularArchive(page: Int, minTimestamp: Int)
    case beforeTimestamp(Int)
    case searchPage(Int)
}

nonisolated struct FeedQuery: Equatable, Hashable, Sendable {
    var tab: FeedTab
    var sortMode: FeedSortMode
    var searchText: String

    init(
        tab: FeedTab = .top,
        sortMode: FeedSortMode = .relevance,
        searchText: String = ""
    ) {
        self.tab = tab
        self.sortMode = sortMode
        self.searchText = searchText
    }

    var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only fixed browse tabs persist to the feed cache so transient search typing never pollutes cached feeds.
    var cacheKey: String? {
        trimmedSearchText.isEmpty ? tab.rawValue : nil
    }
}

nonisolated struct FeedPage: Equatable, Sendable {
    let articles: [Article]
    let nextCursor: FeedCursor?
    let hasMore: Bool
    let isFromCache: Bool
    let cachedAt: Date?

    init(
        articles: [Article],
        nextCursor: FeedCursor?,
        hasMore: Bool,
        isFromCache: Bool = false,
        cachedAt: Date? = nil
    ) {
        self.articles = articles
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.isFromCache = isFromCache
        self.cachedAt = cachedAt
    }
}

nonisolated enum NetworkStatus: String, Equatable, Sendable {
    case online
    case offline
    case constrained

    var isConnected: Bool {
        self != .offline
    }
}
