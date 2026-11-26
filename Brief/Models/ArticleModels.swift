//
//  ArticleModels.swift
//  Brief
//
//  Unified Sendable article, Hacker News Algolia DTO, and comment models.
//

import Foundation

nonisolated enum ArticleKind: String, Codable, Hashable, Sendable {
    case externalLink
    case selfPost
}

nonisolated struct Article: Identifiable, Hashable, Codable, Sendable {
    let id: Int
    let title: String
    let url: URL?
    let domainLabel: String
    let author: String
    let points: Int
    let commentCount: Int
    let createdAt: Date
    let storyTextHTML: String?
    let kind: ArticleKind
    var isSaved: Bool
    var offlineStatus: OfflineStatus

    init(
        id: Int,
        title: String,
        url: URL? = nil,
        domainLabel: String,
        author: String,
        points: Int,
        commentCount: Int,
        createdAt: Date,
        storyTextHTML: String? = nil,
        kind: ArticleKind,
        isSaved: Bool = false,
        offlineStatus: OfflineStatus = .none
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.domainLabel = domainLabel
        self.author = author
        self.points = points
        self.commentCount = commentCount
        self.createdAt = createdAt
        self.storyTextHTML = storyTextHTML
        self.kind = kind
        self.isSaved = isSaved
        self.offlineStatus = offlineStatus
    }

    var canonicalDiscussionURL: URL {
        URL(string: "https://news.ycombinator.com/item?id=\(id)")!
    }

    var shareURL: URL {
        url ?? canonicalDiscussionURL
    }
}

// MARK: - Hacker News Algolia Search DTOs

nonisolated struct HNSearchResponse: Decodable, Sendable {
    let hits: [HNHit]
    let nbHits: Int
    let page: Int
    let nbPages: Int
    let hitsPerPage: Int
}

nonisolated struct HNHit: Decodable, Sendable {
    let objectID: String
    let title: String?
    let storyTitle: String?
    let url: String?
    let storyURLString: String?
    let author: String?
    let points: Int?
    let numComments: Int?
    let createdAtI: Int?
    let storyText: String?
    let tags: [String]?

    enum CodingKeys: String, CodingKey {
        case objectID
        case title
        case storyTitle = "story_title"
        case url
        case storyURLString = "story_url"
        case author
        case points
        case numComments = "num_comments"
        case createdAtI = "created_at_i"
        case storyText = "story_text"
        case tags = "_tags"
    }
}

// MARK: - Hacker News Item & Comment Tree DTOs

nonisolated struct HNItem: Decodable, Sendable {
    let id: Int
    let createdAtI: Int?
    let type: String?
    let author: String?
    let title: String?
    let url: String?
    let text: String?
    let points: Int?
    let parentId: Int?
    let storyId: Int?
    let children: [HNItem]?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAtI = "created_at_i"
        case type
        case author
        case title
        case url
        case text
        case points
        case parentId = "parent_id"
        case storyId = "story_id"
        case children
    }
}

nonisolated struct ArticleComment: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: Int
    let author: String
    let plainText: String
    let createdAt: Date
    let depth: Int
    let isDeleted: Bool
    let childCount: Int
}
