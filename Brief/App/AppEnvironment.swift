//
//  AppEnvironment.swift
//  Brief
//
//  Central dependency container wiring core services and root view models.
//

import Foundation
import Observation

@Observable
final class AppEnvironment {
    let networkMonitor: NetworkMonitor
    let apiClient: APIClient
    let hnService: HNService

    let feedViewModel: FeedTabViewModel

    init(
        networkMonitor: NetworkMonitor = NetworkMonitor(),
        apiClient: APIClient = APIClient(),
        hnService: HNService? = nil
    ) {
        let resolvedHNService = hnService ?? HNService(apiClient: apiClient)
        self.networkMonitor = networkMonitor
        self.apiClient = apiClient
        self.hnService = resolvedHNService
        self.feedViewModel = FeedTabViewModel(hnService: resolvedHNService)
    }
}
