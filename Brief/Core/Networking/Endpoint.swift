//
//  Endpoint.swift
//  Brief
//
//  Type-safe Hacker News Algolia REST endpoint definitions.
//

import Foundation

nonisolated struct Endpoint: Sendable {
    let path: String
    var queryItems: [URLQueryItem] = []

    static func feed(query: FeedQuery, cursor: FeedCursor, now: Date = .now) -> Endpoint {
        let searchText = query.trimmedSearchText
        if !searchText.isEmpty {
            let page: Int
            if case .searchPage(let targetPage) = cursor {
                page = targetPage
            } else {
                page = 0
            }

            let endpointPath = query.sortMode == .latest ? "/search_by_date" : "/search"
            return Endpoint(
                path: endpointPath,
                queryItems: [
                    URLQueryItem(name: "query", value: searchText),
                    URLQueryItem(name: "tags", value: query.tab.algoliaTag),
                    URLQueryItem(name: "hitsPerPage", value: String(AppConfig.hitsPerPage)),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
        }

        switch query.tab {
        case .top:
            switch cursor {
            case .popularArchive(let page, let minTimestamp):
                return Endpoint(
                    path: "/search",
                    queryItems: [
                        URLQueryItem(name: "tags", value: "story"),
                        URLQueryItem(
                            name: "numericFilters",
                            value: "points>=\(AppConfig.topPopularMinPoints),created_at_i>\(minTimestamp)"
                        ),
                        URLQueryItem(name: "hitsPerPage", value: String(AppConfig.hitsPerPage)),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                )
            case .frontPage(let page):
                return Endpoint(
                    path: "/search",
                    queryItems: [
                        URLQueryItem(name: "tags", value: "front_page"),
                        URLQueryItem(name: "hitsPerPage", value: String(AppConfig.hitsPerPage)),
                        URLQueryItem(name: "page", value: String(page))
                    ]
                )
            case .initial, .beforeTimestamp, .searchPage:
                return Endpoint(
                    path: "/search",
                    queryItems: [
                        URLQueryItem(name: "tags", value: "front_page"),
                        URLQueryItem(name: "hitsPerPage", value: String(AppConfig.hitsPerPage)),
                        URLQueryItem(name: "page", value: "0")
                    ]
                )
            }

        case .latest, .askHN, .showHN:
            var items = [
                URLQueryItem(name: "tags", value: query.tab.algoliaTag),
                URLQueryItem(name: "hitsPerPage", value: String(AppConfig.hitsPerPage))
            ]
            if case .beforeTimestamp(let timestamp) = cursor {
                items.append(URLQueryItem(name: "numericFilters", value: "created_at_i<=\(timestamp)"))
            }
            return Endpoint(path: "/search_by_date", queryItems: items)
        }
    }

    static func item(id: Int) -> Endpoint {
        Endpoint(path: "/items/\(id)")
    }

    static func popularArchiveStartTimestamp(relativeTo date: Date = .now) -> Int {
        Int(date.timeIntervalSince1970) - (AppConfig.topPopularWindowDays * 86_400)
    }

    func makeURLRequest(baseURL: URL = AppConfig.baseURL) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = (components.path == "/" ? "" : components.path) + normalizedPath
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = AppConfig.requestTimeout
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
