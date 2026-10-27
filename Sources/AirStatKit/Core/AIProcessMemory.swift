import Foundation

public struct AIProcessMemory: Sendable, Equatable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var residentBytes: UInt64
    public var physicalFootprintBytes: UInt64?

    public init(pid: Int32, residentBytes: UInt64, physicalFootprintBytes: UInt64? = nil) {
        self.pid = pid
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public enum AIProcessMemoryStatus: String, Sendable, Equatable, Hashable {
    case pending, measured, remote, noListener, ambiguous, noWorker, partial, unavailable

    public var message: String {
        switch self {
        case .pending: return "Waiting for process memory measurements."
        case .measured: return "Memory is measured from local model processes."
        case .remote: return "Process memory is available only for a local API address."
        case .noListener: return "No local inference server was found listening on the configured API port."
        case .ambiguous: return "The server or model processes could not be identified unambiguously."
        case .noWorker: return "No model worker process could be matched to this instance."
        case .partial: return "Some model processes could not be inspected; the total memory is unavailable."
        case .unavailable: return "macOS did not allow reading the model process memory, or the process exited."
        }
    }
}
