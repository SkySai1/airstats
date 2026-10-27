import Foundation
import Testing
@testable import AirStatKit

private final class TestAPIRequest: AIAPICancellable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class ControlledAIAPI: AIAPIFetching {
    private struct Pending {
        let queue: DispatchQueue
        let completion: (Result<AIAPIReading, AIAPIError>) -> Void
        let token: TestAPIRequest
    }
    private let lock = NSLock()
    private var pending: [Pending] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    func fetch(endpoint: AIEndpoint, completionQueue: DispatchQueue,
               completion: @escaping (Result<AIAPIReading, AIAPIError>) -> Void) -> AIAPICancellable {
        let token = TestAPIRequest()
        lock.lock()
        pending.append(Pending(queue: completionQueue, completion: completion, token: token))
        lock.unlock()
        return token
    }

    func wasCancelled(_ index: Int) -> Bool {
        lock.lock(); let token = pending[index].token; lock.unlock()
        return token.isCancelled
    }

    func complete(_ index: Int, with result: Result<AIAPIReading, AIAPIError>) async {
        lock.lock(); let request = pending[index]; lock.unlock()
        await withCheckedContinuation { continuation in
            request.queue.async {
                request.completion(result)
                continuation.resume()
            }
        }
    }
}

@Suite("Combined AI API collection")
struct AIAPICollectionTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("sampling returns while HTTP is pending and keeps one request in flight")
    func nonblockingCollection() async {
        let client = ControlledAIAPI()
        let cache = AIAPICache(client: client)
        defer { cache.stop() }
        let endpoint = AIEndpoint()
        cache.configure([endpoint])
        #expect(cache.reading(for: endpoint, now: date, maximumAge: 15).1 == .pending)
        #expect(cache.reading(for: endpoint, now: date.addingTimeInterval(10), maximumAge: 15).1 == .pending)
        #expect(client.count == 1)
        await client.complete(0, with: .success(AIAPIReading(fetchedAt: date)))
        #expect(cache.reading(for: endpoint, now: date.addingTimeInterval(11), maximumAge: 15).1 == .online)
    }

    @Test("one endpoint failing does not affect another and retries have a delay")
    func independentFailures() async {
        let client = ControlledAIAPI()
        let cache = AIAPICache(client: client)
        defer { cache.stop() }
        let a = AIEndpoint(name: "A")
        let b = AIEndpoint(name: "B")
        cache.configure([a, b])
        _ = cache.reading(for: a, now: date, maximumAge: 15)
        _ = cache.reading(for: b, now: date, maximumAge: 15)
        await client.complete(0, with: .failure(.transport))
        await client.complete(1, with: .success(AIAPIReading(fetchedAt: date)))
        #expect(cache.reading(for: a, now: date.addingTimeInterval(6), maximumAge: 15).1 == .unavailable)
        #expect(cache.reading(for: b, now: date.addingTimeInterval(1), maximumAge: 15).1 == .online)
        #expect(client.count == 2)
        _ = cache.reading(for: a, now: date.addingTimeInterval(11), maximumAge: 15)
        #expect(client.count == 3)
    }

    @Test("expired responses remain stale while a refresh is pending")
    func expiredResponses() async {
        let client = ControlledAIAPI()
        let cache = AIAPICache(client: client)
        defer { cache.stop() }
        let endpoint = AIEndpoint()
        cache.configure([endpoint])
        _ = cache.reading(for: endpoint, now: date, maximumAge: 15)
        await client.complete(0, with: .success(AIAPIReading(fetchedAt: date)))
        #expect(cache.reading(for: endpoint, now: date.addingTimeInterval(20), maximumAge: 15).1 == .stale)
        #expect(client.count == 2)
    }

    @Test("changing server URL cancels old work and ignores its late response")
    func reconfiguredEndpoint() async {
        let client = ControlledAIAPI()
        let cache = AIAPICache(client: client)
        defer { cache.stop() }
        var endpoint = AIEndpoint()
        cache.configure([endpoint])
        _ = cache.reading(for: endpoint, now: date, maximumAge: 15)
        endpoint.url = "http://localhost:11435"
        cache.configure([endpoint])
        #expect(client.wasCancelled(0))
        _ = cache.reading(for: endpoint, now: date, maximumAge: 15)
        await client.complete(0, with: .success(AIAPIReading(fetchedAt: date)))
        #expect(cache.reading(for: endpoint, now: date, maximumAge: 15).1 == .pending)
        #expect(client.count == 2)
        await client.complete(1, with: .success(AIAPIReading(fetchedAt: date)))
        #expect(cache.reading(for: endpoint, now: date, maximumAge: 15).1 == .online)
    }

    @Test("logs-only mode does not make any API request")
    func logsOnly() {
        let client = ControlledAIAPI()
        let cache = AIAPICache(client: client)
        defer { cache.stop() }
        let endpoint = AIEndpoint(usesAPI: false)
        cache.configure([endpoint])
        #expect(cache.reading(for: endpoint, now: date, maximumAge: 15).1 == .disabled)
        #expect(client.count == 0)
    }

    @Test("collector prefers matching log generation timings over API rates and deduplicates history")
    func combinedCollector() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = ISO8601DateFormatter().string(from: date)
        let contents = "time=\(timestamp) print_info: general.name = Qwen\ntime=\(timestamp) slot print_timing: eval time = 4000 ms / 200 tokens (20 ms per token, 50 tokens per second)\n"
        let file = directory.appendingPathComponent("server.log")
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let endpoint = AIEndpoint(logDirectory: directory.path)
        let client = ControlledAIAPI()
        let inspector = FakeAIProcessInspector(nodes: [
            AIProcessNode(pid: 10, parentPID: 1, startedAt: 1, isRuntime: true, listeningPorts: [11434]),
            AIProcessNode(pid: 11, parentPID: 10, startedAt: 2, isRuntime: true, isWorker: true, modelIdentifiers: ["Qwen"]),
        ], readings: [11: AIProcessMemory(pid: 11, residentBytes: 8192)])
        let collector = AICollector(apiClient: client, processInspector: inspector, now: { date })
        defer { collector.stop() }
        collector.setEndpoints([endpoint])
        let context = SampleContext(elapsed: 5, isFirstSample: false, activity: .panel)
        let first = try #require(collector.collect(context: context).value)
        #expect(first.instances.first?.apiStatus == .pending)
        let live = AIModelInfo(endpointID: endpoint.id, name: "served-model", memoryBytes: 4096,
                               tokensPerSecond: 80, isLoaded: true)
        await client.complete(0, with: .success(AIAPIReading(models: [live], aliases: [live.name: ["Qwen"]],
                                                          memoryBytes: 4096, fetchedAt: date)))
        let second = try #require(collector.collect(context: context).value)
        #expect(second.instances.first?.apiStatus == .online)
        #expect(second.models.first?.isLoaded == true)
        #expect(second.models.first?.tokensPerSecond == 50)
        #expect(second.instances.first?.memoryBytes == 8192)
        var history = AIHistory()
        history.append(first)
        history.append(second)
        history.append(try #require(collector.collect(context: context).value))
        #expect(history.count == 2)
        for interval in AIHistoryInterval.allCases {
            let generation = history.generationSeries(instanceID: endpoint.id, interval: interval)
            #expect(generation.count == 1)
            #expect(generation.first?.value == 50)
        }
    }

    @Test("legacy settings enable API while explicit logs-only choices survive decoding")
    func settingsMigration() throws {
        let legacy = try JSONDecoder().decode(AIEndpoint.self, from: Data("{}".utf8))
        let local = try JSONDecoder().decode(AIEndpoint.self, from: Data("{\"usesAPI\":false}".utf8))
        #expect(legacy.usesAPI)
        #expect(!local.usesAPI)
        var endpoint = AIEndpoint()
        #expect(endpoint.apiBaseURL != nil)
        endpoint.url = "file:///tmp/log"
        #expect(endpoint.apiBaseURL == nil)
        endpoint.url = "http://user:password@localhost:11434"
        #expect(endpoint.apiBaseURL == nil)
    }
}
