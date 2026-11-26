//
//  APIError.swift
//  Brief
//
//  Typed networking, rate-limit, decoding, and content extraction errors.
//

import Foundation

nonisolated enum APIError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case rateLimited(retryAfterSeconds: Int?)
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case extractionError(String)
    case networkError(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "Rate limit reached. Please try again in \(retryAfterSeconds)s."
            }
            return "Rate limit reached. Please try again shortly."
        case .httpError(let statusCode, let message):
            return message.isEmpty ? "Server error (HTTP \(statusCode))." : message
        case .decodingError(let details):
            return "Failed to parse server response: \(details)"
        case .extractionError(let details):
            return details.isEmpty ? "Could not extract article content." : details
        case .networkError(let details):
            return details.isEmpty ? "Network connection unavailable." : details
        case .timeout:
            return "Request timed out. Please try again."
        case .cancelled:
            return "Request was cancelled."
        }
    }

    var isLikelyOfflineError: Bool {
        switch self {
        case .networkError, .timeout:
            return true
        case .invalidURL, .rateLimited, .httpError, .decodingError, .extractionError, .cancelled:
            return false
        }
    }

    static func mapURLError(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return APIError.timeout
        case .appTransportSecurityRequiresSecureConnection,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return APIError.extractionError("Secure HTTPS connection failed.")
        default:
            return APIError.networkError(error.localizedDescription)
        }
    }
}
