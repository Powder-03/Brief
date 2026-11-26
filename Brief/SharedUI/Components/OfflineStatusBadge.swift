//
//  OfflineStatusBadge.swift
//  Brief
//
//  Compact badge displaying offline article persistence and download state.
//

import SwiftUI

struct OfflineStatusBadge: View {
    let status: OfflineStatus

    var body: some View {
        if status == .none {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                Image(systemName: AppTheme.statusIcon(for: status))
                    .font(.caption2.weight(.semibold))

                Text(status.displayTitle)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(AppTheme.statusColor(for: status))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                AppTheme.statusColor(for: status).opacity(0.14),
                in: RoundedRectangle(cornerRadius: AppTheme.badgeCornerRadius)
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.accessibilityDescription)
        }
    }
}
