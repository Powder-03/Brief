//
//  OfflineBannerView.swift
//  Brief
//
//  Subtle connectivity banner pinned above tab content during offline or constrained states.
//

import SwiftUI

struct OfflineBannerView: View {
    let status: NetworkStatus

    var body: some View {
        switch status {
        case .online:
            EmptyView()
        case .offline:
            bannerContent(
                icon: "wifi.slash",
                text: "Offline Mode — Browsing cached and saved articles",
                tint: AppTheme.queuedOffline
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        case .constrained:
            bannerContent(
                icon: "gauge.with.dots.needle.33percent",
                text: "Low Data Mode — Automatic downloads may pause",
                tint: .secondary
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func bannerContent(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
