//
//  APIClient.swift
//  Brief
//
//  Async/await HTTP client with injectable URLSessionProtocol, ATS HTTPS upgrades,
//  rate-limit parsing, byte-limit protection, and off-main-actor JSON decoding.
//

import Foundation

nonisolated protocol URLSessionProtocol: Sendable {
    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

nonisolated extension URLSession: URLSessionProtocol {
    nonisolated func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

protocol APIClientProtocol {
    func request<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T
    func fetchData(from url: URL, maxBytes: Int?) async throws -> (Data, HTTPURLResponse)
}

final class APIClient: APIClientProtocol {
    private let baseURL: URL
    private let session: URLSessionProtocol

    init(
        baseURL: URL = AppConfig.baseURL,
        session: URLSessionProtocol = URLSession.shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    func request<T: Decodable & Sendable>(_ endpoint: Endpoint) async throws -> T {
        let urlRequest = try endpoint.makeURLRequest(baseURL: baseURL)
        let (data, _) = try await Self.executeRequest(urlRequest, session: session, maxBytes: nil)
        do {
            return try await JSONCoders.decode(T.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.decodingError(error.localizedDescription)
        }
    }

    func fetchData(from url: URL, maxBytes: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        let secureURL = Self.upgradingHTTPToHTTPSIfNeeded(url)
        var request = URLRequest(url: secureURL)
        request.httpMethod = "GET"
        request.timeoutInterval = AppConfig.requestTimeout
        request.setValue(AppConfig.userAgent, forHTTPHeaderField: "User-Agent")

        return try await Self.executeRequest(request, session: session, maxBytes: maxBytes)
    }

    // MARK: - Helpers

    @concurrent
    private nonisolated static func executeRequest(
        _ request: URLRequest,
        session: URLSessionProtocol,
        maxBytes: Int?
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw APIError.mapURLError(urlError)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.networkError(error.localizedDescription)
        }

        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError("Invalid server response.")
        }

        if let maxBytes,
           httpResponse.expectedContentLength > 0,
           httpResponse.expectedContentLength > Int64(maxBytes) {
            throw APIError.extractionError("Content exceeds maximum allowed size (\(maxBytes) bytes).")
        }

        switch httpResponse.statusCode {
        case 200...299:
            if let maxBytes, data.count > maxBytes {
                throw APIError.extractionError("Content exceeds maximum allowed size (\(maxBytes) bytes).")
            }
            return (data, httpResponse)

        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw APIError.rateLimited(retryAfterSeconds: retryAfter)

        default:
            let message = String(data: data.prefix(512), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private nonisolated static func upgradingHTTPToHTTPSIfNeeded(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }
}
