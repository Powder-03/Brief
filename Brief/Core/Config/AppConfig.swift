//
//  AppConfig.swift
//  Brief
//
//  Centralized API endpoints, pagination limits, and offline storage quotas.
//

import Foundation

nonisolated enum AppConfig {
    /// Public Hacker News Algolia REST API base URL.
    static let baseURL = URL(string: "https://hn.algolia.com/api/v1")!

    /// Standard HTTP request timeout in seconds.
    static let requestTimeout: TimeInterval = 15

    /// User-Agent header sent for API and offline article fetches.
    static let userAgent = "Brief-iOS/1.0"

    /// Default page size requested per feed page.
    static let hitsPerPage = 30

    /// Algolia caps offset-based search pagination at 1,000 total hits.
    static let algoliaMaxSearchWindow = 1000

    /// Minimum points and recency window used for Top feed continuation past the live front page.
    static let topPopularMinPoints = 20
    static let topPopularWindowDays = 14

    /// Feed discovery interaction tuning.
    static let searchDebounceMilliseconds = 350
    static let prefetchThreshold = 5
    static let maxCommentDepth = 12

    /// SwiftData feed cache retention limits (never applies to saved articles).
    static let maxCachedItemsPerTab = 150
    static let maxCachedAgeDays = 7

    /// Offline article extraction and image asset quotas.
    static let maxHTMLBytes = 5_000_000
    static let maxImagesPerArticle = 12
    static let maxImageBytes = 5_000_000
    static let maxArticleAssetsBytes = 15_000_000
    static let minExtractedProseChars = 150
    static let maxConcurrentImageDownloads = 3

    /// Storage folder and UserDefaults keys.
    static let offlineAssetsFolderName = "BriefOfflineAssets"
    static let readerFontSizeDefaultsKey = "brief.reader.fontSize"
}
