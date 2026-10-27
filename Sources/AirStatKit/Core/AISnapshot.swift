import Foundation

/// Progress through one prompt, distinct from the model's context-window occupancy.
public struct AIPrefillProgress: Sendable, Equatable, Hashable, Identifiable {
    public var slotID: Int?
    public var taskID: Int?
    public var fraction: Double
    public var processedTokens: Int
    public var elapsed: TimeInterval?
    public var tokensPerSecond: Double?
    public var updatedAt: Date

    public var id: String { "slot:\(slotID ?? -1):task:\(taskID ?? -1)" }

    public init(slotID: Int? = nil, taskID: Int? = nil, fraction: Double,
                processedTokens: Int, elapsed: TimeInterval? = nil,
                tokensPerSecond: Double? = nil, updatedAt: Date) {
        self.slotID = slotID
        self.taskID = taskID
        self.fraction = fraction
        self.processedTokens = processedTokens
        self.elapsed = elapsed
        self.tokensPerSecond = tokensPerSecond
        self.updatedAt = updatedAt
    }
}

/// Measurements come from runtime APIs, logs, and identified local model processes.
public struct AIModelInfo: Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var endpointID: UUID
    public var name: String
    /// Log stream identity survives metadata names and API aliases changing.
    public var historyID: UUID
    public var slots: [AISlotInfo]
    /// Names, paths and digests actually reported for this model by its source.
    public var aliases: Set<String>
    /// Measured process RSS in collected snapshots; raw API/log readings are replaced before publication.
    public var memoryBytes: UInt64?
    public var processes: [AIProcessMemory]
    public var contextWindowTotal: Int?
    public var contextWindowUsed: Int?
    public var tokensPerSecond: Double?
    public var contextTokensPerSecond: Double?
    public var prefillProgress: [AIPrefillProgress]
    public var isActive: Bool?
    /// Loaded inventory and request activity are separate measurements.
    public var isLoaded: Bool?
    public var gpuMemoryBytes: UInt64?
    public var lastObservedAt: Date?

    public init(id: UUID? = nil, endpointID: UUID = AIModelInfo.unassignedEndpointID,
                name: String = "", memoryBytes: UInt64? = nil,
                contextWindowTotal: Int? = nil, contextWindowUsed: Int? = nil,
                tokensPerSecond: Double? = nil, contextTokensPerSecond: Double? = nil,
                isActive: Bool? = nil, lastObservedAt: Date? = nil,
                isLoaded: Bool? = nil, gpuMemoryBytes: UInt64? = nil,
                aliases: Set<String> = [], prefillProgress: [AIPrefillProgress] = [],
                processes: [AIProcessMemory] = [], historyID: UUID? = nil,
                slots: [AISlotInfo] = []) {
        self.id = id ?? Self.stableID(endpointID: endpointID, name: name)
        self.historyID = historyID ?? self.id
        self.slots = slots
        self.endpointID = endpointID
        self.name = name
        self.aliases = aliases
        self.memoryBytes = memoryBytes
        self.contextWindowTotal = contextWindowTotal
        self.contextWindowUsed = contextWindowUsed
        self.tokensPerSecond = tokensPerSecond
        self.contextTokensPerSecond = contextTokensPerSecond
        self.isActive = isActive
        self.lastObservedAt = lastObservedAt
        self.isLoaded = isLoaded
        self.gpuMemoryBytes = gpuMemoryBytes
        self.prefillProgress = prefillProgress
        self.processes = processes
    }

    public static let unassignedEndpointID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public static func stableID(endpointID: UUID, name: String) -> UUID {
        let bytes = Array((endpointID.uuidString + ":" + name).utf8)
        func hash(_ seed: UInt64) -> UInt64 {
            bytes.reduce(seed) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }
        let a = hash(14_695_981_039_346_656_037)
        let b = hash(7_809_847_782_465_536_322)
        let data = (0..<8).map { UInt8(truncatingIfNeeded: a >> ($0 * 8)) }
            + (0..<8).map { UInt8(truncatingIfNeeded: b >> ($0 * 8)) }
        return UUID(uuid: (data[0], data[1], data[2], data[3], data[4], data[5], data[6], data[7],
                           data[8], data[9], data[10], data[11], data[12], data[13], data[14], data[15]))
    }
}

public enum AIInstanceStatus: String, Sendable, Equatable, Hashable {
    case monitoring, idle, stale, missingLogs, unreadable, disabled

    public var message: String {
        switch self {
        case .monitoring: return "Reading logs"
        case .idle: return "No active requests reported"
        case .stale: return "Historical log; current activity unknown"
        case .missingLogs: return "No matching log files"
        case .unreadable: return "Cannot read log directory or files"
        case .disabled: return "Disabled"
        }
    }
}

public struct AIInstanceSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var runtime: AIRuntime
    public var status: AIInstanceStatus
    public var models: [AIModelInfo]
    public var memoryBytes: UInt64?
    public var lastEventAt: Date?
    /// Empty on a poll with no new measurements; a cached rate is never a new sample.
    public var observations: [AIObservation]
    public var apiStatus: AIAPIStatus
    public var apiFetchedAt: Date?
    public var processes: [AIProcessMemory]
    public var processMemoryStatus: AIProcessMemoryStatus

    public init(id: UUID, name: String, runtime: AIRuntime = .ollama,
                status: AIInstanceStatus = .monitoring, models: [AIModelInfo] = [],
                memoryBytes: UInt64? = nil, lastEventAt: Date? = nil,
                observations: [AIObservation] = [],
                apiStatus: AIAPIStatus = .disabled, apiFetchedAt: Date? = nil,
                processes: [AIProcessMemory] = [], processMemoryStatus: AIProcessMemoryStatus = .pending) {
        self.id = id
        self.name = name
        self.runtime = runtime
        self.status = status
        self.models = models
        self.memoryBytes = memoryBytes
        self.lastEventAt = lastEventAt
        self.observations = observations
        self.apiStatus = apiStatus
        self.apiFetchedAt = apiFetchedAt
        self.processes = processes
        self.processMemoryStatus = processMemoryStatus
    }
}

public struct AIObservation: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Hashable { case generation, prefill, memory }
    public var id: String
    public var instanceID: UUID
    public var kind: Kind
    public var date: Date
    public var value: Double
    public var tokenCount: Int?
    public var duration: TimeInterval?
    public var modelID: UUID?
    public var slotID: Int?
    public var taskID: Int?

    public init(id: String, instanceID: UUID, kind: Kind, date: Date, value: Double,
                tokenCount: Int? = nil, duration: TimeInterval? = nil,
                modelID: UUID? = nil, slotID: Int? = nil, taskID: Int? = nil) {
        self.id = id
        self.instanceID = instanceID
        self.kind = kind
        self.date = date
        self.value = value
        self.tokenCount = tokenCount
        self.duration = duration
        self.modelID = modelID
        self.slotID = slotID
        self.taskID = taskID
    }
}

public struct AISnapshot: Sendable, Equatable {
    public var overallRAMUsage: Double?
    public var models: [AIModelInfo]
    public var instances: [AIInstanceSnapshot]
    public var capturedAt: Date

    public init(overallRAMUsage: Double? = nil, models: [AIModelInfo] = [],
                instances: [AIInstanceSnapshot] = [], capturedAt: Date = Date()) {
        self.overallRAMUsage = overallRAMUsage
        self.models = instances.isEmpty ? models : instances.flatMap(\.models)
        self.instances = instances
        self.capturedAt = capturedAt
    }
}

public enum AIFailure: Sendable, Equatable, Hashable {
    case unsupported(String), failed(String), pending
    public var message: String {
        switch self {
        case .unsupported(let text), .failed(let text): return text
        case .pending: return "Collecting…"
        }
    }
    public var isPermanent: Bool {
        if case .unsupported = self { return true }
        return false
    }
}
