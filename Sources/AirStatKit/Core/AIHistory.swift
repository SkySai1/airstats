import Foundation

public enum AIHistoryInterval: Int, CaseIterable, Sendable, Equatable, Hashable {
    case oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900
    public var duration: TimeInterval { TimeInterval(rawValue) }
    public var label: String { "\(rawValue / 60)m" }
}

public struct AIHistoryPoint: Sendable, Equatable, Identifiable {
    public var date: Date
    public var value: Double
    public var id: Date { date }
    public init(date: Date, value: Double) { self.date = date; self.value = value }
}

/// Keeps measurements, not repeated screen refreshes. Missing intervals remain gaps.
public struct AIHistory: Sendable, Equatable {
    public let retention: TimeInterval
    public let capacity: Int
    private var observations: [AIObservation] = []
    private var seen = Set<String>()
    private var observationInstanceIDs = Set<UUID>()
    private var latestDate: Date?
    private var lastSnapshot: AISnapshot?

    public init(retention: TimeInterval = 86_400, capacity: Int = 16_384) {
        self.retention = max(900, retention)
        self.capacity = max(1, capacity)
    }

    public var count: Int { observations.count }
    public var isEmpty: Bool { observations.isEmpty }

    public mutating func append(_ snapshot: AISnapshot) {
        guard snapshot.capturedAt.timeIntervalSince1970.isFinite else { return }
        if lastSnapshot?.capturedAt == snapshot.capturedAt, lastSnapshot == snapshot { return }
        lastSnapshot = snapshot
        latestDate = max(latestDate ?? snapshot.capturedAt, snapshot.capturedAt)
        let cutoff = latestDate!.addingTimeInterval(-retention)
        var added = false
        for instance in snapshot.instances {
            for observation in instance.observations where observation.instanceID == instance.id {
                let key = instance.id.uuidString + ":" + observation.id
                guard observation.date >= cutoff, observation.date <= snapshot.capturedAt.addingTimeInterval(1),
                      observation.value.isFinite, observation.value >= 0,
                      seen.insert(key).inserted else { continue }
                observations.append(observation)
                observationInstanceIDs.insert(observation.instanceID)
                added = true
            }
        }
        if added { observations.sort { $0.date < $1.date } }
        var removed = false
        if let first = observations.first, first.date < cutoff {
            observations.removeAll { $0.date < cutoff }
            removed = true
        }
        if observations.count > capacity {
            observations.removeFirst(observations.count - capacity)
            removed = true
        }
        if removed { rebuildSeen() }
    }

    public mutating func retainInstances(_ ids: Set<UUID>) {
        guard !observationInstanceIDs.isSubset(of: ids) else { return }
        observations.removeAll { !ids.contains($0.instanceID) }
        lastSnapshot = nil
        rebuildSeen()
    }

    private mutating func rebuildSeen() {
        seen = Set(observations.map { $0.instanceID.uuidString + ":" + $0.id })
        observationInstanceIDs = Set(observations.map(\.instanceID))
    }

    public func generationSeries(instanceID: UUID, modelID: UUID? = nil, slotID: Int? = nil,
                                 interval: AIHistoryInterval = .oneMinute,
                                 now: Date? = nil) -> [AIHistoryPoint] {
        series(instanceID: instanceID, kind: .generation, modelID: modelID, slotID: slotID,
               interval: interval, now: now)
    }

    public func prefillSeries(instanceID: UUID, modelID: UUID? = nil, slotID: Int? = nil,
                              interval: AIHistoryInterval = .oneMinute,
                              now: Date? = nil) -> [AIHistoryPoint] {
        series(instanceID: instanceID, kind: .prefill, modelID: modelID, slotID: slotID,
               interval: interval, now: now)
    }

    public func memorySeries(instanceID: UUID, interval: AIHistoryInterval = .oneMinute,
                             now: Date? = nil) -> [AIHistoryPoint] {
        series(instanceID: instanceID, kind: .memory, interval: interval, now: now)
    }

    private func series(instanceID: UUID, kind: AIObservation.Kind,
                        modelID: UUID? = nil, slotID: Int? = nil, interval: AIHistoryInterval,
                        now: Date?) -> [AIHistoryPoint] {
        let end = now ?? latestDate ?? Date()
        let start = end.addingTimeInterval(-retention)
        var buckets: [Int: [AIObservation]] = [:]
        for item in observations where item.instanceID == instanceID && item.kind == kind
            && (modelID == nil || item.modelID == modelID) && (slotID == nil || item.slotID == slotID)
            && item.date >= start && item.date <= end {
            let bucket = Int(floor(item.date.timeIntervalSince1970 / interval.duration))
            buckets[bucket, default: []].append(item)
        }
        return buckets.keys.sorted().compactMap { bucket in
            let items = buckets[bucket]!
            // Token/duration pairs must all exist before weighting: mixing units would
            // silently give short requests the same influence as long generations.
            let weighted = kind != .memory && items.allSatisfy {
                ($0.tokenCount ?? -1) >= 0 && ($0.duration ?? 0) > 0 && ($0.duration?.isFinite ?? false)
            }
            let value: Double
            if weighted {
                let tokens = items.reduce(0.0) { $0 + Double($1.tokenCount!) }
                let duration = items.reduce(0.0) { $0 + $1.duration! }
                guard tokens.isFinite, duration.isFinite, duration > 0 else { return nil }
                value = tokens / duration
            } else {
                value = items.reduce(0) { $0 + $1.value } / Double(items.count)
            }
            guard value.isFinite else { return nil }
            return AIHistoryPoint(date: Date(timeIntervalSince1970: Double(bucket) * interval.duration), value: value)
        }
    }
}
