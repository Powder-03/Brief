//
//  MainTabView.swift
//  Brief
//
//  Root two-tab navigation shell with connectivity banner inset.
//

import SwiftUI

enum AppTab: Hashable {
    case discover
    case saved
}

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab: AppTab = .discover

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                EmptyStateView(
                    systemImage: "newspaper",
                    title: "Discover Tech News",
                    subtitle: "Live Hacker News stories and infinite-scroll discovery will appear here."
                )
                .navigationTitle("Brief")
            }
            .tabItem {
                Label("Discover", systemImage: "newspaper")
            }
            .tag(AppTab.discover)

            NavigationStack {
                EmptyStateView(
                    systemImage: "bookmark.fill",
                    title: "Saved for Offline",
                    subtitle: "Bookmarked stories and full offline reading packages will appear here."
                )
                .navigationTitle("Saved")
            }
            .tabItem {
                Label("Saved", systemImage: "bookmark.fill")
            }
            .tag(AppTab.saved)
        }
        .tint(AppTheme.brand)
        .safeAreaInset(edge: .top, spacing: 0) {
            OfflineBannerView(status: environment.networkMonitor.currentStatus)
        }
        .animation(AppMotion.snappy, value: environment.networkMonitor.currentStatus)
    }
}

#Preview {
    MainTabView()
        .environment(AppEnvironment(networkMonitor: NetworkMonitor(startMonitoring: false)))
}
