import Foundation

public enum AISlotPhase: String, Sendable, Equatable, Hashable {
    case unknown, idle, processing, prefill, answer

    public var label: String {
        switch self {
        case .unknown: return "Activity unknown"
        case .idle: return "Idle"
        case .processing: return "Processing"
        case .prefill: return "Prefill"
        case .answer: return "Answer"
        }
    }

    public var isActive: Bool? {
        switch self {
        case .unknown: return nil
        case .idle: return false
        case .processing, .prefill, .answer: return true
        }
    }
}

/// Slot numbers are scoped to a model worker, never to the whole server.
public struct AISlotInfo: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int
    public var taskID: Int?
    public var phase: AISlotPhase
    public var contextWindowTotal: Int?
    public var contextWindowUsed: Int?
    public var generatedTokens: Int?
    public var tokensPerSecond: Double?
    public var contextTokensPerSecond: Double?
    public var prefillProgress: AIPrefillProgress?
    public var updatedAt: Date
    public var generationMeasuredAt: Date?
    public var prefillMeasuredAt: Date?

    public init(id: Int, taskID: Int? = nil, phase: AISlotPhase = .unknown,
                contextWindowTotal: Int? = nil, contextWindowUsed: Int? = nil,
                generatedTokens: Int? = nil, tokensPerSecond: Double? = nil,
                contextTokensPerSecond: Double? = nil, prefillProgress: AIPrefillProgress? = nil,
                updatedAt: Date = Date(), generationMeasuredAt: Date? = nil,
                prefillMeasuredAt: Date? = nil) {
        self.id = id
        self.taskID = taskID
        self.phase = phase
        self.contextWindowTotal = contextWindowTotal
        self.contextWindowUsed = contextWindowUsed
        self.generatedTokens = generatedTokens
        self.tokensPerSecond = tokensPerSecond
        self.contextTokensPerSecond = contextTokensPerSecond
        self.prefillProgress = prefillProgress
        self.updatedAt = updatedAt
        self.generationMeasuredAt = generationMeasuredAt
        self.prefillMeasuredAt = prefillMeasuredAt
    }

    func current(at now: Date, available: Bool) -> Self {
        var result = self
        func fresh(_ date: Date?, for limit: TimeInterval) -> Bool {
            guard let date else { return false }
            return (-1...limit).contains(now.timeIntervalSince(date))
        }
        guard available, fresh(updatedAt, for: 300) else {
            result.phase = .unknown
            result.contextWindowUsed = nil
            result.generatedTokens = nil
            result.tokensPerSecond = nil
            result.contextTokensPerSecond = nil
            result.prefillProgress = nil
            return result
        }
        if !fresh(generationMeasuredAt, for: 60) { result.tokensPerSecond = nil }
        if !fresh(prefillMeasuredAt, for: 60) { result.contextTokensPerSecond = nil }
        if !fresh(prefillProgress?.updatedAt, for: 60) { result.prefillProgress = nil }
        if phase.isActive == true, !fresh(updatedAt, for: 60) { result.phase = .unknown }
        return result
    }
}
