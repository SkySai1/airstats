import Foundation
import Testing
@testable import AirStatKit

private final class AIHTTPRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class AIMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case response(Int, String, [String: String] = [:])
        case stall
    }
    typealias Handler = (URLRequest) -> Reply
    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]
    static func register(host: String, handler: @escaping Handler) {
        lock.lock(); handlers[host] = handler; lock.unlock()
    }
    static func remove(host: String) { lock.lock(); handlers.removeValue(forKey: host); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handlers[request.url?.host ?? ""]; Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        switch handler(request) {
        case .response(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .stall: break
        }
    }
    override func stopLoading() {}
}

@Suite("Read-only inference APIs")
struct AIAPITests {
    private func setup(runtime: AIRuntime = .ollama, handler: @escaping AIMockURLProtocol.Handler)
        -> (AIEndpoint, URLSessionConfiguration, AIHTTPRecorder) {
        let host = "inference-\(UUID().uuidString.lowercased()).test"
        let recorder = AIHTTPRecorder()
        AIMockURLProtocol.register(host: host) { request in recorder.append(request); return handler(request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIMockURLProtocol.self]
        return (AIEndpoint(name: runtime.label, url: "http://\(host)", apiKey: "test-key", runtime: runtime), configuration, recorder)
    }

    private func fetch(_ endpoint: AIEndpoint, configuration: URLSessionConfiguration,
                       maximumBytes: Int = 1_048_576) async -> Result<AIAPIReading, AIAPIError> {
        let client = AIAPIClient(configuration: configuration, timeout: 0.2, maximumResponseBytes: maximumBytes)
        return await withCheckedContinuation { continuation in
            _ = client.fetch(endpoint: endpoint, completionQueue: DispatchQueue(label: "AIAPITests.callback")) {
                continuation.resume(returning: $0)
            }
        }
    }

    @Test("Ollama ps reports loaded inventory without treating expiration as generation")
    func ollamaInventory() async throws {
        let (endpoint, configuration, recorder) = setup { _ in .response(200, #"""
        {"models":[
          {"name":"custom:latest","model":"base:8b","digest":"sha256:digest","size":5000,"size_vram":3000,"context_length":8192,"expires_at":"2099-01-01T00:00:00Z"},
          {"model":"second:latest","size":2000,"size_vram":0,"context_length":2048}
        ]}
        """#) }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models.count == 2)
        #expect(reading.models[0].isLoaded == true)
        #expect(reading.models[0].isActive == nil)
        #expect(reading.models[0].memoryBytes == 5000)
        #expect(reading.models[0].gpuMemoryBytes == 3000)
        #expect(reading.models[0].contextWindowTotal == 8192)
        #expect(reading.models[0].contextWindowUsed == nil)
        #expect(reading.memoryBytes == 7000)
        #expect(reading.aliases["custom:latest"]?.contains("base:8b") == true)
        #expect(reading.aliases["custom:latest"]?.contains("sha256:digest") == true)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].url?.path == "/api/ps")
        #expect(recorder.requests[0].httpMethod == "GET")
        #expect(recorder.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
    }

    @Test("missing, negative and malformed numbers stay unavailable")
    func noInventedMetrics() async throws {
        let (endpoint, configuration, _) = setup { _ in
            .response(200, #"{"models":[{"name":"one","size":-1,"size_vram":true,"context_length":-1},{"name":"two","size":"1000"}]}"#)
        }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models.allSatisfy { $0.memoryBytes == nil && $0.gpuMemoryBytes == nil })
        #expect(reading.models[0].contextWindowTotal == nil)
        #expect(reading.memoryBytes == nil)
    }

    @Test("ps authentication failure never falls back to downloaded model lists")
    func noTagsFallback() async {
        let (endpoint, configuration, recorder) = setup { _ in .response(401, #"{"error":"unauthorized"}"#) }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let result = await fetch(endpoint, configuration: configuration)
        #expect(result == .failure(.httpStatus(401)))
        #expect(recorder.requests.map { $0.url!.path } == ["/api/ps"])
    }

    @Test("unrecognized JSON is not an authoritative empty inventory")
    func malformedInventory() async {
        let (endpoint, configuration, _) = setup { _ in .response(200, #"{"tags":[]}"#) }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        #expect(await fetch(endpoint, configuration: configuration) == .failure(.malformedResponse))
    }

    @Test("response limits apply even without a Content-Length header")
    func boundedStreamingResponse() async {
        let (endpoint, configuration, _) = setup { _ in .response(200, String(repeating: "x", count: 512)) }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        #expect(await fetch(endpoint, configuration: configuration, maximumBytes: 128) == .failure(.responseTooLarge))
    }

    @Test("a declared oversized response is rejected before reading its body")
    func boundedDeclaredResponse() async {
        let (endpoint, configuration, _) = setup { _ in .response(200, "{}", ["Content-Length": "1000000"]) }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        #expect(await fetch(endpoint, configuration: configuration, maximumBytes: 128) == .failure(.responseTooLarge))
    }

    @Test("cancelled requests complete on the requested queue")
    func cancellationAndCallbackQueue() async {
        let (endpoint, configuration, _) = setup { _ in .stall }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let client = AIAPIClient(configuration: configuration)
        let queue = DispatchQueue(label: "AIAPITests.cancelCallback")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let result: (Result<AIAPIReading, AIAPIError>, Bool) = await withCheckedContinuation { continuation in
            let task = client.fetch(endpoint: endpoint, completionQueue: queue) {
                continuation.resume(returning: ($0, DispatchQueue.getSpecific(key: key) == true))
            }
            task.cancel()
        }
        #expect(result.0 == .failure(.cancelled))
        #expect(result.1)
    }

    @Test("non-HTTP URLs never launch requests")
    func invalidURL() async {
        let (configured, configuration, recorder) = setup { _ in .response(200, "{}") }
        defer { AIMockURLProtocol.remove(host: URL(string: configured.url)!.host!) }
        var endpoint = configured
        endpoint.url = "file:///tmp/server"
        #expect(await fetch(endpoint, configuration: configuration) == .failure(.invalidURL))
        #expect(recorder.requests.isEmpty)
    }

    @Test("llama health and props prove loaded state while slots report request activity")
    func llamaSlots() async throws {
        let (endpoint, configuration, _) = setup(runtime: .llamaCpp) { request in
            switch request.url!.path {
            case "/health": return .response(200, #"{"status":"ok"}"#)
            case "/props": return .response(200, #"{"model_alias":"local-qwen","model_path":"/models/qwen.gguf","default_generation_settings":{"n_ctx":8192},"is_sleeping":false}"#)
            case "/slots": return .response(200, #"[{"id":0,"id_task":-1,"is_processing":false,"n_ctx":8192,"n_past":100},{"id":1,"id_task":27,"is_processing":true,"n_ctx":8192,"n_past":2000}]"#)
            case "/metrics": return .response(200, "llamacpp:requests_processing 1\nllamacpp:n_tokens_max 7000\n")
            default: return .response(404, "{}")
            }
        }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models.count == 1)
        #expect(reading.models[0].isLoaded == true)
        #expect(reading.models[0].isActive == true)
        #expect(reading.models[0].contextWindowUsed == 2000)
        #expect(reading.models[0].contextWindowTotal == 8192)
        #expect(reading.models[0].slots.map(\.id) == [0, 1])
        #expect(reading.models[0].slots.map(\.phase) == [.idle, .processing])
        #expect(reading.models[0].slots[0].taskID == nil)
        #expect(reading.models[0].slots[1].taskID == 27)
        #expect(reading.models[0].slots[1].contextWindowUsed == 2000)
        #expect(reading.models[0].memoryBytes == nil)
        #expect(reading.aliases["local-qwen"]?.contains("qwen") == true)
    }

    @Test("idle llama metrics never poll slots or reset the idle timer")
    func idleLlamaDoesNotPollSlots() async throws {
        let (endpoint, configuration, recorder) = setup(runtime: .llamaCpp) { request in
            switch request.url!.path {
            case "/health": return .response(200, #"{"status":"ok"}"#)
            case "/props": return .response(200, #"{"model_path":"/models/qwen.gguf","is_sleeping":false}"#)
            case "/metrics": return .response(200, "llamacpp:requests_processing 0\n")
            default: return .response(404, "{}")
            }
        }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models[0].isLoaded == true)
        #expect(reading.models[0].isActive == false)
        #expect(!recorder.requests.contains { $0.url?.path == "/slots" })
    }

    @Test("sleeping llama inventory is empty and no slots request wakes it")
    func sleepingLlama() async throws {
        let (endpoint, configuration, recorder) = setup(runtime: .llamaCpp) { request in
            switch request.url!.path {
            case "/health": return .response(200, #"{"status":"ok"}"#)
            case "/props": return .response(200, #"{"model_path":"/models/qwen.gguf","is_sleeping":true}"#)
            default: return .response(404, "{}")
            }
        }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models.isEmpty)
        #expect(!recorder.requests.contains { $0.url?.path == "/slots" })
        #expect(!recorder.requests.contains { $0.url?.path == "/metrics" })
    }

    @Test("router lists only explicitly loaded models without querying or loading cached entries")
    func routerLoadedOnly() async throws {
        let (endpoint, configuration, recorder) = setup(runtime: .llamaCpp) { request in
            switch request.url!.path {
            case "/models": return .response(200, #"{"data":[{"id":"loaded","aliases":["public-alias"],"meta":{"n_ctx":262144,"size":999999},"context_length":131072,"status":{"value":"loaded","args":["llama-server","--model","/models/live.gguf"]}},{"id":"context-fallback","context_length":8192,"status":{"value":"loaded"}},{"id":"cached","status":{"value":"unloaded"}},{"id":"sleeping","status":{"value":"sleeping"}}]}"#)
            case "/health": return .response(200, #"{"status":"ok"}"#)
            default: return .response(400, "{}")
            }
        }
        defer { AIMockURLProtocol.remove(host: URL(string: endpoint.url)!.host!) }
        let reading = try await fetch(endpoint, configuration: configuration).get()
        #expect(reading.models.map(\.name) == ["loaded", "context-fallback"])
        #expect(reading.models[0].contextWindowTotal == 262144)
        #expect(reading.models[1].contextWindowTotal == 8192)
        #expect(reading.models[0].memoryBytes == nil)
        #expect(reading.aliases["loaded"]?.contains("public-alias") == true)
        #expect(reading.aliases["loaded"]?.contains("live") == true)
        #expect(recorder.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.query == nil })
        #expect(recorder.requests.count == 3)
    }
}

@Suite("API and log measurement merge")
struct AIMergeTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = UUID()

    @Test("fresh API inventory removes unloaded log models and merges only confident aliases")
    func authoritativeInventory() {
        let logged = AIModelInfo(endpointID: id, name: "loader-name", memoryBytes: 100,
                                 contextWindowTotal: 8192, contextWindowUsed: 200,
                                 tokensPerSecond: 50, contextTokensPerSecond: 100, isActive: true)
        let absent = AIModelInfo(endpointID: id, name: "unloaded", memoryBytes: 300)
        let logs = AIInstanceSnapshot(id: id, name: "test", models: [logged, absent])
        let live = AIModelInfo(endpointID: id, name: "custom-tag", memoryBytes: 150,
                               contextWindowTotal: 4096, isLoaded: true)
        let reading = AIAPIReading(models: [live], aliases: ["custom-tag": ["loader-name"]], memoryBytes: 150, fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
        #expect(merged.models.count == 1)
        #expect(merged.models[0].name == "custom-tag")
        #expect(merged.models[0].memoryBytes == 150)
        #expect(merged.models[0].contextWindowTotal == 4096)
        #expect(merged.models[0].contextWindowUsed == 200)
        #expect(merged.models[0].tokensPerSecond == 50)
        #expect(merged.models[0].isActive == true)
        #expect(merged.models[0].isLoaded == true)
    }

    @Test("current log generation rates take precedence over API rates, including measured zero")
    func logGenerationPriority() {
        let live = AIModelInfo(endpointID: id, name: "served", tokensPerSecond: 80, isLoaded: true)
        let reading = AIAPIReading(models: [live], aliases: [live.name: ["loader-name"]], fetchedAt: date)
        for status in [AIInstanceStatus.monitoring, .idle] {
            for rate in [0.0, 50] {
                let logged = AIModelInfo(endpointID: id, name: "loader-name", tokensPerSecond: rate)
                let logs = AIInstanceSnapshot(id: id, name: "test", status: status, models: [logged])
                let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
                #expect(merged.models.first?.tokensPerSecond == rate)
            }
        }
    }

    @Test("API generation rates fill missing log timings without reviving unavailable log readings")
    func generationFallback() {
        let live = AIModelInfo(endpointID: id, name: "live", tokensPerSecond: 80, isLoaded: true)
        let reading = AIAPIReading(models: [live], fetchedAt: date)
        let missingTiming = AIInstanceSnapshot(id: id, name: "test",
            models: [AIModelInfo(endpointID: id, name: "live")])
        #expect(AIMerge.snapshot(logs: missingTiming, api: reading, apiStatus: .online,
                                 now: date).models.first?.tokensPerSecond == 80)
        for status in [AIInstanceStatus.stale, .missingLogs, .unreadable] {
            let logs = AIInstanceSnapshot(id: id, name: "test", status: status,
                models: [AIModelInfo(endpointID: id, name: "live", tokensPerSecond: 50)])
            let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
            #expect(merged.models.first?.tokensPerSecond == 80)
        }
    }

    @Test("digest aliases match custom Ollama tags to loader paths")
    func digestMatch() {
        let digest = String(repeating: "a", count: 64)
        let logged = AIModelInfo(endpointID: id, name: "Human Model Name", tokensPerSecond: 42,
                                 aliases: ["/models/blobs/sha256-" + digest])
        let logs = AIInstanceSnapshot(id: id, name: "test", models: [logged])
        let live = AIModelInfo(endpointID: id, name: "custom:8b", isLoaded: true)
        let reading = AIAPIReading(models: [live], aliases: [live.name: [digest]], fetchedAt: date)
        #expect(AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date).models[0].tokensPerSecond == 42)
    }

    @Test("similar model families and ambiguous aliases never acquire unrelated log measurements")
    func ambiguousNames() {
        let logged = AIModelInfo(endpointID: id, name: "Qwen", tokensPerSecond: 42)
        let logs = AIInstanceSnapshot(id: id, name: "test", models: [logged])
        let a = AIModelInfo(endpointID: id, name: "qwen:8b", isLoaded: true)
        let b = AIModelInfo(endpointID: id, name: "qwen:4b", isLoaded: true)
        let reading = AIAPIReading(models: [a, b], aliases: [a.name: ["Qwen"], b.name: ["Qwen"]], fetchedAt: date)
        #expect(AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date).models.allSatisfy { $0.tokensPerSecond == nil })
        let unmatched = AIAPIReading(models: [a], fetchedAt: date)
        #expect(AIMerge.snapshot(logs: logs, api: unmatched, apiStatus: .online, now: date).models[0].tokensPerSecond == nil)
    }

    @Test("cached API data expires and cannot advertise loaded or generating models")
    func staleReading() {
        let logs = AIInstanceSnapshot(id: id, name: "test", status: .stale)
        let reading = AIAPIReading(models: [AIModelInfo(endpointID: id, name: "old", isActive: true, isLoaded: true)], fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date.addingTimeInterval(60))
        #expect(merged.apiStatus == .stale)
        #expect(merged.models.isEmpty)
        #expect(merged.memoryBytes == nil)
    }

    @Test("live API slots activity is usable when logs are missing")
    func apiActivityWithoutLogs() {
        let logs = AIInstanceSnapshot(id: id, name: "test", status: .missingLogs)
        let reading = AIAPIReading(models: [AIModelInfo(endpointID: id, name: "live", isActive: true, isLoaded: true)], fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
        #expect(merged.models[0].isActive == true)
        #expect(merged.apiStatus == .online)
        #expect(merged.status == .missingLogs)
    }

    @Test("ps loaded inventory cannot promote historical log activity or context")
    func noHistoricalPromotion() {
        let logs = AIInstanceSnapshot(id: id, name: "test", status: .stale,
            models: [AIModelInfo(endpointID: id, name: "live", contextWindowUsed: 200, isActive: true)])
        let reading = AIAPIReading(models: [AIModelInfo(endpointID: id, name: "live", isLoaded: true)], fetchedAt: date)
        let model = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date).models[0]
        #expect(model.isLoaded == true)
        #expect(model.isActive == nil)
        #expect(model.contextWindowUsed == nil)
    }

    @Test("API memory replaces log allocation samples while preserving token history")
    func memoryRepresentationIsNotMixed() {
        let observations = [
            AIObservation(id: "log-memory", instanceID: id, kind: .memory, date: date, value: 50),
            AIObservation(id: "log-generation", instanceID: id, kind: .generation, date: date, value: 20),
        ]
        let logs = AIInstanceSnapshot(id: id, name: "test", observations: observations)
        let reading = AIAPIReading(models: [], memoryBytes: 100, fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
        #expect(merged.observations.filter { $0.kind == .memory }.map(\.value) == [100])
        #expect(merged.observations.contains { $0.id == "log-generation" })
    }

    @Test("cached memory readings enter history only once and never overflow the total")
    func memoryDedupAndOverflow() {
        let logs = AIInstanceSnapshot(id: id, name: "test")
        let model = AIModelInfo(endpointID: id, name: "live", memoryBytes: 100, isLoaded: true)
        let reading = AIAPIReading(models: [model], memoryBytes: 100, fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
        var history = AIHistory()
        history.append(AISnapshot(instances: [merged], capturedAt: date))
        history.append(AISnapshot(instances: [merged], capturedAt: date.addingTimeInterval(5)))
        #expect(history.count == 1)
        let big = AIModelInfo(name: "big", memoryBytes: UInt64.max)
        #expect(AIMerge.completeMemoryTotal([big, model]) == nil)
        #expect(AIMerge.completeMemoryTotal([]) == nil)
    }
}
