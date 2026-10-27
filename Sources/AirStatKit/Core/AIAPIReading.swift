import Foundation

public enum AIAPIStatus: String, Sendable, Equatable, Hashable {
    case disabled, pending, online, unavailable, stale

    public var message: String {
        switch self {
        case .disabled: return "API disabled"
        case .pending: return "Connecting to API"
        case .online: return "API connected"
        case .unavailable: return "API unavailable"
        case .stale: return "API data expired"
        }
    }
}

/// An inventory response, captured once per HTTP poll. Loaded does not mean generating.
public struct AIAPIReading: Sendable, Equatable {
    public var models: [AIModelInfo]
    /// Names explicitly associated by the server, keyed by the displayed model name.
    public var aliases: [String: Set<String>]
    public var memoryBytes: UInt64?
    public var fetchedAt: Date

    public init(models: [AIModelInfo] = [], aliases: [String: Set<String>] = [:],
                memoryBytes: UInt64? = nil, fetchedAt: Date = Date()) {
        self.models = models
        self.aliases = aliases
        self.memoryBytes = memoryBytes
        self.fetchedAt = fetchedAt
    }
}

public enum AIAPIError: Error, Sendable, Equatable {
    case invalidURL, httpStatus(Int), malformedResponse, responseTooLarge, transport, cancelled
}
