//
//  ContentView.swift
//  Brief
//
//  Root view wrapping MainTabView for app launch and Xcode Canvas previews.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        MainTabView()
    }
}

#Preview {
    ContentView()
        .environment(AppEnvironment(networkMonitor: NetworkMonitor(startMonitoring: false)))
}
