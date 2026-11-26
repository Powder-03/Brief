//
//  PaginationFooterView.swift
//  Brief
//
//  Inline pagination footer showing loading spinner, retry action, or end-of-feed state.
//

import SwiftUI

struct PaginationFooterView: View {
    let state: FeedTabViewModel.PaginationState
    let hasArticles: Bool
    let onRetry: () -> Void

    var body: some View {
        switch state {
        case .loadingNextPage:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading more stories...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)

        case .failedPage(let message):
            ErrorBanner(
                message: message,
                retryTitle: "Retry",
                retryAction: onRetry
            )
            .padding(.vertical, 8)

        case .exhausted where hasArticles:
            Text("You're caught up")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)

        default:
            EmptyView()
        }
    }
}
