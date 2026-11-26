//
//  BriefApp.swift
//  Brief
//
//  Created by Satendra Patel on 26/11/26.
//

import SwiftUI

@main
struct BriefApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(environment)
        }
    }
}
