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

    init(
        networkMonitor: NetworkMonitor = NetworkMonitor(),
        apiClient: APIClient = APIClient(),
        hnService: HNService? = nil
    ) {
        self.networkMonitor = networkMonitor
        self.apiClient = apiClient
        self.hnService = hnService ?? HNService(apiClient: apiClient)
    }
}
