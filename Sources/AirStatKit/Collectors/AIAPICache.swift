import Foundation

/// Network completion has its own queue; file cursors remain on SamplingCore's queue.
/// A failed or slow endpoint therefore never delays system metric collection.
final class AIAPICache {
    private struct Entry {
        var endpoint: AIEndpoint
        var reading: AIAPIReading?
        var requestID: UUID?
        var request: AIAPICancellable?
        var lastAttempt: Date?
        var failed = false
        var failures = 0
    }

    private let queue = DispatchQueue(label: "com.airstat.ai-api-cache", qos: .utility)
    private let client: AIAPIFetching
    private var entries: [UUID: Entry] = [:]

    init(client: AIAPIFetching) { self.client = client }

    func configure(_ endpoints: [AIEndpoint]) {
        let requests: [AIAPICancellable] = queue.sync {
            let configured = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            var requests: [AIAPICancellable] = []
            for (id, entry) in entries {
                guard let endpoint = configured[id], Self.sameSource(entry.endpoint, endpoint) else {
                    if let request = entry.request { requests.append(request) }
                    entries.removeValue(forKey: id)
                    continue
                }
            }
            for endpoint in configured.values where endpoint.isEnabled && endpoint.usesAPI {
                if entries[endpoint.id] == nil { entries[endpoint.id] = Entry(endpoint: endpoint) }
            }
            return requests
        }
        requests.forEach { $0.cancel() }
    }

    func stop() {
        let requests = queue.sync {
            let requests = entries.values.compactMap(\.request)
            entries.removeAll()
            return requests
        }
        requests.forEach { $0.cancel() }
    }

    func reading(for endpoint: AIEndpoint, now: Date,
                 maximumAge: TimeInterval) -> (AIAPIReading?, AIAPIStatus) {
        guard endpoint.isEnabled, endpoint.usesAPI else { return (nil, .disabled) }
        guard endpoint.apiBaseURL != nil else { return (nil, .unavailable) }

        let result: (AIAPIReading?, AIAPIStatus, UUID?) = queue.sync {
            var entry = entries[endpoint.id] ?? Entry(endpoint: endpoint)
            var requestID: UUID?
            let retryInterval = min(60, 5 * pow(2, Double(min(entry.failures, 4))))
            if entry.requestID == nil,
               entry.lastAttempt.map({ now.timeIntervalSince($0) >= retryInterval }) ?? true {
                let id = UUID()
                entry.requestID = id
                entry.lastAttempt = now
                requestID = id
            }
            let status: AIAPIStatus
            if entry.failed { status = .unavailable }
            else if let reading = entry.reading {
                status = now.timeIntervalSince(reading.fetchedAt) <= maximumAge ? .online : .stale
            } else { status = .pending }
            entries[endpoint.id] = entry
            return (entry.reading, status, requestID)
        }

        if let requestID = result.2 {
            let request = client.fetch(endpoint: endpoint, completionQueue: queue) { [weak self] result in
                guard let self, var entry = self.entries[endpoint.id],
                      entry.requestID == requestID else { return }
                entry.requestID = nil
                entry.request = nil
                switch result {
                case .success(let reading):
                    entry.reading = reading
                    entry.failed = false
                    entry.failures = 0
                case .failure:
                    entry.failed = true
                    entry.failures = min(entry.failures + 1, 4)
                }
                self.entries[endpoint.id] = entry
            }
            let retained: Bool = queue.sync {
                guard entries[endpoint.id]?.requestID == requestID else { return false }
                entries[endpoint.id]?.request = request
                return true
            }
            if !retained { request.cancel() }
        }
        return (result.0, result.1)
    }

    private static func sameSource(_ a: AIEndpoint, _ b: AIEndpoint) -> Bool {
        a.runtime == b.runtime && a.url == b.url && a.apiKey == b.apiKey
            && a.usesAPI == b.usesAPI && a.isEnabled == b.isEnabled
    }
}
