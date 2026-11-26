//
//  ArticleRowView.swift
//  Brief
//
//  Scannable feed row presenting story headline, source badge, engagement metrics, and offline status.
//

import SwiftUI

struct ArticleRowView: View {
    let article: Article

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(article.domainLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(article.kind == .selfPost ? AppTheme.brand : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (article.kind == .selfPost ? AppTheme.brand.opacity(0.12) : Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )

                Text(relativeTimeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                if article.isSaved {
                    OfflineStatusBadge(status: article.offlineStatus)
                }
            }

            Text(article.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                Label("\(article.points)", systemImage: "arrow.up")
                Label("\(article.commentCount)", systemImage: "bubble.right")
                Text(article.author)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(CompactMetricLabelStyle())
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var relativeTimeString: String {
        Self.relativeFormatter.localizedString(for: article.createdAt, relativeTo: .now)
    }

    private var accessibilitySummary: String {
        var summary = "\(article.title), \(article.domainLabel), \(article.points) points, \(article.commentCount) comments, by \(article.author), \(relativeTimeString)"
        if article.isSaved {
            summary += ", \(article.offlineStatus.accessibilityDescription)"
        }
        return summary
    }
}

private struct CompactMetricLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
