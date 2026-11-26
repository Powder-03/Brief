//
//  AppTheme.swift
//  Brief
//
//  Editorial palette, typography helpers, motion presets, and status styling.
//

import SwiftUI

enum AppTheme {
    static let brand = Color(red: 0.91, green: 0.36, blue: 0.14)
    static let brandAccent = Color(red: 0.96, green: 0.54, blue: 0.18)

    static let readyOffline = Color(red: 0.11, green: 0.62, blue: 0.42)
    static let queuedOffline = Color.orange
    static let downloadingOffline = Color.blue
    static let partialOffline = Color.yellow
    static let failedOffline = Color(red: 0.86, green: 0.28, blue: 0.24)

    static let cardCornerRadius: CGFloat = 14
    static let badgeCornerRadius: CGFloat = 8
    static let readerMaxWidth: CGFloat = 720

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brand, brandAccent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func statusColor(for status: OfflineStatus) -> Color {
        switch status {
        case .none:
            return .secondary
        case .queued:
            return queuedOffline
        case .downloading:
            return downloadingOffline
        case .ready:
            return readyOffline
        case .partial:
            return partialOffline
        case .failed:
            return failedOffline
        }
    }

    static func statusIcon(for status: OfflineStatus) -> String {
        switch status {
        case .none:
            return "bookmark"
        case .queued:
            return "clock.arrow.circlepath"
        case .downloading:
            return "arrow.down.circle"
        case .ready:
            return "checkmark.circle.fill"
        case .partial:
            return "exclamationmark.circle"
        case .failed:
            return "xmark.octagon"
        }
    }
}

enum AppMotion {
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.78)
    static let gentle = Animation.spring(response: 0.46, dampingFraction: 0.86)
    static let quick = Animation.easeOut(duration: 0.2)
}
