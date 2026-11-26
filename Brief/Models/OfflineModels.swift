//
//  OfflineModels.swift
//  Brief
//
//  Offline extraction blocks, asset metadata, saved snapshots, and reader settings.
//

import Foundation

nonisolated enum OfflineStatus: String, Codable, Hashable, Sendable {
    case none
    case queued
    case downloading
    case ready
    case partial
    case failed

    var displayTitle: String {
        switch self {
        case .none:
            return "Not Saved"
        case .queued:
            return "Queued"
        case .downloading:
            return "Saving..."
        case .ready:
            return "Offline Ready"
        case .partial:
            return "Partial Offline"
        case .failed:
            return "Save Failed"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .none:
            return "Not saved for offline reading"
        case .queued:
            return "Queued for offline download"
        case .downloading:
            return "Downloading for offline reading"
        case .ready:
            return "Saved and ready for offline reading"
        case .partial:
            return "Partially saved for offline reading"
        case .failed:
            return "Offline download failed"
        }
    }

    var isPendingOrFailed: Bool {
        switch self {
        case .queued, .downloading, .partial, .failed:
            return true
        case .none, .ready:
            return false
        }
    }
}

nonisolated enum ContentBlock: Identifiable, Codable, Equatable, Hashable, Sendable {
    case heading(id: String, level: Int, text: String)
    case paragraph(id: String, text: String)
    case blockquote(id: String, text: String)
    case codeBlock(id: String, text: String)
    case listItem(id: String, ordered: Bool, index: Int, text: String)
    case image(id: String, assetID: String, remoteURL: URL, relativeLocalPath: String?, caption: String?)

    var id: String {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .blockquote(let id, _),
             .codeBlock(let id, _),
             .listItem(let id, _, _, _),
             .image(let id, _, _, _, _):
            return id
        }
    }
}

nonisolated struct OfflineArticleContent: Codable, Equatable, Sendable {
    let title: String
    let author: String?
    let sourceURL: URL
    let heroImageAssetID: String?
    let heroImageRemoteURL: URL?
    let heroImageRelativePath: String?
    let blocks: [ContentBlock]
    let plainTextIndex: String
    let excerpt: String
    let estimatedReadingMinutes: Int
    let isSparseOrBlocked: Bool
    let extractedAt: Date
}

nonisolated struct OfflineAssetRecord: Codable, Equatable, Sendable {
    let assetID: String
    let storyID: Int
    let remoteURLString: String
    let relativeLocalPath: String
    let mimeType: String
    let byteSize: Int64
    let downloadedAt: Date
}

nonisolated struct SavedArticleSnapshot: Identifiable, Equatable, Sendable {
    var id: Int { article.id }
    var article: Article
    let savedAt: Date
    let estimatedReadingMinutes: Int
    let byteSize: Int64
    let excerpt: String
    let heroImageRelativePath: String?
    let lastErrorMessage: String?
}

nonisolated enum SavedFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case readyOffline
    case pendingOrFailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .readyOffline:
            return "Ready Offline"
        case .pendingOrFailed:
            return "Pending & Failed"
        }
    }
}

nonisolated enum ReaderFontSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case compact
    case standard
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact:
            return "Compact"
        case .standard:
            return "Standard"
        case .large:
            return "Large"
        }
    }

    var bodyPointSize: Double {
        switch self {
        case .compact:
            return 15
        case .standard:
            return 17
        case .large:
            return 20
        }
    }

    var titlePointSize: Double {
        switch self {
        case .compact:
            return 22
        case .standard:
            return 25
        case .large:
            return 29
        }
    }
}
