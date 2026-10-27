import Foundation

/// Bounded logs, cached nonblocking API requests, and measured local process memory.
public final class AICollector: MetricSource {
    public typealias Output = AISnapshot
    public let identifier: CollectorID = .ai
    public var preferredInterval: TimeInterval { isReadingContext ? 1 : 5 }
    private var isReadingContext = false
    private var endpoints: [AIEndpoint] = []
    private var tailers: [UUID: AILogTailer] = [:]
    private var parsers: [UUID: AILogParser] = [:]
    private let now: () -> Date
    private let api: AIAPICache
    private let processMemory: AIProcessMemoryCollector

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
        self.api = AIAPICache(client: AIAPIClient())
        self.processMemory = AIProcessMemoryCollector()
    }

    init(apiClient: AIAPIFetching, processInspector: AIProcessInspecting = NativeAIProcessInspector(),
         now: @escaping () -> Date = Date.init) {
        self.now = now
        self.api = AIAPICache(client: apiClient)
        self.processMemory = AIProcessMemoryCollector(inspector: processInspector)
    }

    public func start() { api.configure(endpoints) }
    public func stop() {
        isReadingContext = false
        api.stop()
        tailers.removeAll()
        parsers.removeAll()
        processMemory.invalidate()
    }

    /// SamplingCore applies settings on the same serial queue as collect.
    public func setEndpoints(_ endpoints: [AIEndpoint]) {
        let previous = Dictionary(self.endpoints.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let retained = Set(endpoints.map(\.id))
        tailers = tailers.filter { retained.contains($0.key) }
        parsers = parsers.filter { retained.contains($0.key) }
        for endpoint in endpoints {
            if let old = previous[endpoint.id], old.runtime != endpoint.runtime
                || old.logDirectory != endpoint.logDirectory || old.logFilePattern != endpoint.logFilePattern
                || old.isEnabled != endpoint.isEnabled {
                tailers.removeValue(forKey: endpoint.id)
                parsers.removeValue(forKey: endpoint.id)
            }
        }
        if self.endpoints != endpoints { processMemory.invalidate() }
        self.endpoints = endpoints
        api.configure(endpoints)
    }

    public func collect(context: SampleContext) -> MetricState<AISnapshot> {
        guard !endpoints.isEmpty else {
            isReadingContext = false
            return .pending
        }
        let date = now()
        var instances: [AIInstanceSnapshot] = []
        var visited = Set<UUID>()
        for endpoint in endpoints where visited.insert(endpoint.id).inserted {
            guard endpoint.isEnabled else {
                instances.append(AIInstanceSnapshot(id: endpoint.id, name: endpoint.name,
                    runtime: endpoint.runtime, status: .disabled))
                continue
            }
            let tailer = tailers[endpoint.id] ?? AILogTailer()
            tailers[endpoint.id] = tailer
            let read = tailer.read(directory: endpoint.logDirectory, pattern: endpoint.logFilePattern, now: date)
            var parser = parsers[endpoint.id] ?? AILogParser(instanceID: endpoint.id)
            parser.beginPoll()
            for record in read.records { parser.consume(record) }
            let logs = parser.snapshot(endpoint: endpoint, read: read, now: date)
            let maximumAge = max(15, min(300, context.elapsed * 2))
            let (reading, status) = api.reading(for: endpoint, now: date, maximumAge: maximumAge)
            let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: status,
                                           now: date, maximumAge: maximumAge)
            instances.append(processMemory.apply(to: merged, endpoint: endpoint, now: date))
            parsers[endpoint.id] = parser
        }
        isReadingContext = instances.contains { instance in
            instance.models.contains { !$0.prefillProgress.isEmpty }
        }
        return .value(AISnapshot(instances: instances, capturedAt: date))
    }
}
