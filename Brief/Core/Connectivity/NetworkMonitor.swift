//
//  NetworkMonitor.swift
//  Brief
//
//  Live NWPathMonitor connectivity observer exposing current status and AsyncStream updates.
//

import Foundation
import Network
import Observation

protocol NetworkMonitorProtocol {
    var currentStatus: NetworkStatus { get }
    func statusUpdates() -> AsyncStream<NetworkStatus>
}

@Observable
final class NetworkMonitor: NetworkMonitorProtocol {
    private(set) var currentStatus: NetworkStatus = .online

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.brief.network.monitor", qos: .utility)
    private var continuations: [UUID: AsyncStream<NetworkStatus>.Continuation] = [:]

    init(startMonitoring: Bool = true) {
        self.monitor = NWPathMonitor()
        if startMonitoring {
            start()
        }
    }

    isolated deinit {
        monitor.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func statusUpdates() -> AsyncStream<NetworkStatus> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(currentStatus)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let mapped = Self.mapPath(path)
            Task { @MainActor [weak self] in
                self?.applyStatus(mapped)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    private func applyStatus(_ status: NetworkStatus) {
        guard currentStatus != status else { return }
        currentStatus = status
        for continuation in continuations.values {
            continuation.yield(status)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private nonisolated static func mapPath(_ path: NWPath) -> NetworkStatus {
        guard path.status == .satisfied else {
            return .offline
        }
        if path.isConstrained {
            return .constrained
        }
        return .online
    }
}
