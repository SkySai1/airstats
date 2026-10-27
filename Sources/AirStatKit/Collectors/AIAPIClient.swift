import Foundation
import CoreFoundation

public protocol AIAPICancellable: AnyObject { func cancel() }

public protocol AIAPIFetching: AnyObject {
    @discardableResult
    func fetch(endpoint: AIEndpoint, completionQueue: DispatchQueue,
               completion: @escaping (Result<AIAPIReading, AIAPIError>) -> Void) -> AIAPICancellable
}

/// Every request is GET-only, has a deadline, and stops reading once the body exceeds
/// its budget. Router inventories are filtered to models explicitly marked loaded.
public final class AIAPIClient: AIAPIFetching {
    private let configuration: URLSessionConfiguration
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let now: () -> Date

    public init(configuration: URLSessionConfiguration = .ephemeral, timeout: TimeInterval = 3,
                maximumResponseBytes: Int = 1_048_576, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.timeout = timeout.isFinite ? min(max(timeout, 0.1), 30) : 3
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.now = now
    }

    @discardableResult
    public func fetch(endpoint: AIEndpoint, completionQueue: DispatchQueue,
                      completion: @escaping (Result<AIAPIReading, AIAPIError>) -> Void) -> AIAPICancellable {
        let task = Task {
            let result: Result<AIAPIReading, AIAPIError>
            do {
                guard let base = Self.validatedBaseURL(endpoint.url) else { throw AIAPIError.invalidURL }
                let reading = try await self.readWithDeadline(endpoint: endpoint, base: base)
                try Task.checkCancellation()
                result = .success(reading)
            } catch {
                let failure: AIAPIError
                if Task.isCancelled || error is CancellationError { failure = .cancelled }
                else { failure = error as? AIAPIError ?? .transport }
                result = .failure(failure)
            }
            completionQueue.async { completion(result) }
        }
        return AIAPITask(task)
    }

    private func readWithDeadline(endpoint: AIEndpoint, base: URL) async throws -> AIAPIReading {
        try await withThrowingTaskGroup(of: AIAPIReading.self) { group in
            group.addTask { try await self.read(endpoint: endpoint, base: base) }
            group.addTask {
                try await Task.sleep(nanoseconds: 8_000_000_000)
                throw AIAPIError.transport
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func read(endpoint: AIEndpoint, base: URL) async throws -> AIAPIReading {
        switch endpoint.runtime {
        case .ollama:
            let data = try await request(base: base, path: "api/ps", endpoint: endpoint)
            return try Self.ollama(data, endpoint: endpoint, fetchedAt: now())
        case .llamaCpp:
            async let propsResult = optionalRequest(base: base, path: "props", endpoint: endpoint)
            async let healthResult = optionalRequest(base: base, path: "health", endpoint: endpoint)
            async let modelsResult = optionalRequest(base: base, path: "models", endpoint: endpoint)
            let (propsResponse, healthResponse, modelsResponse) = await (propsResult, healthResult, modelsResult)
            try Task.checkCancellation()
            // Router inventories also contain cached and sleeping models. Only the
            // explicit loaded status can make an entry part of the live inventory.
            if case .success(let data) = modelsResponse,
               let inventory = try? Self.object(data), let entries = inventory["data"] as? [[String: Any]],
               entries.isEmpty || entries.contains(where: { $0["status"] is [String: Any] }) {
                var models: [AIModelInfo] = []
                var aliases: [String: Set<String>] = [:]
                var seen = Set<String>()
                for entry in entries {
                    guard let status = entry["status"] as? [String: Any], status["value"] as? String == "loaded" else { continue }
                    guard let name = Self.name(entry["id"]) else { throw AIAPIError.malformedResponse }
                    guard seen.insert(name).inserted else { continue }
                    let metadata = entry["meta"] as? [String: Any]
                    let context = Self.integer(metadata?["n_ctx"]).flatMap { $0 > 0 ? $0 : nil }
                        ?? Self.integer(entry["context_length"]).flatMap { $0 > 0 ? $0 : nil }
                    let model = AIModelInfo(endpointID: endpoint.id, name: name, contextWindowTotal: context,
                                            lastObservedAt: now(), isLoaded: true)
                    var names: Set<String> = [name]
                    if let aliases = entry["aliases"] as? [String] {
                        names.formUnion(aliases.compactMap { Self.name($0) })
                    }
                    if let path = Self.name(entry["path"]) { names.formUnion(Self.pathAliases(path)) }
                    if let arguments = status["args"] as? [String], let path = Self.modelPath(in: arguments) {
                        names.formUnion(Self.pathAliases(path))
                    }
                    models.append(model)
                    aliases[name] = names
                }
                return AIAPIReading(models: models, aliases: aliases,
                                    memoryBytes: AIMerge.completeMemoryTotal(models), fetchedAt: now())
            }
            let props = try Self.object(propsResponse.get())
            let health = try Self.object(healthResponse.get())
            guard health["status"] as? String == "ok",
                  props["model_path"] is String || props["model_alias"] is String
                    || props["default_generation_settings"] is [String: Any] else { throw AIAPIError.malformedResponse }
            if props["is_sleeping"] as? Bool == true {
                return AIAPIReading(models: [], fetchedAt: now())
            }
            let modelName = Self.name(props["model_alias"])
                ?? Self.name(props["model_path"]).map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Model name unavailable"
            var model = AIModelInfo(endpointID: endpoint.id, name: modelName,
                                    lastObservedAt: now(), isLoaded: true)
            var aliases: Set<String> = [modelName]
            Self.applyProps(props, to: &model, aliases: &aliases)
            await supplement(&model, base: base, query: [], endpoint: endpoint)
            try Task.checkCancellation()
            return AIAPIReading(models: [model], aliases: [modelName: aliases],
                                memoryBytes: model.memoryBytes, fetchedAt: now())
        }
    }

    private func supplement(_ model: inout AIModelInfo, base: URL, query: [URLQueryItem], endpoint: AIEndpoint) async {
        let metrics = await optionalRequest(base: base, path: "metrics", query: query, endpoint: endpoint)
        if case .success(let data) = metrics, let text = String(data: data, encoding: .utf8) {
            let values = Self.prometheus(text)
            if let processing = values["llamacpp:requests_processing"] { model.isActive = processing > 0 }
        }
        // Unlike /metrics, /slots is not exempt from llama.cpp's idle timer. Only
        // inspect slots during an explicitly reported request; idle monitoring must
        // not keep a model loaded or wake a sleeping server.
        guard model.isActive == true else { return }
        let response = await optionalRequest(base: base, path: "slots", query: query, endpoint: endpoint)
        if case .success(let data) = response,
           let slots = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !slots.isEmpty {
            let fetchedAt = now()
            var seen = Set<Int>()
            model.slots = slots.compactMap { value in
                guard let id = Self.integer(value["id"]), seen.insert(id).inserted else { return nil }
                let active = Self.boolean(value["is_processing"])
                return AISlotInfo(id: id, taskID: Self.integer(value["id_task"]),
                    phase: active.map { $0 ? .processing : .idle } ?? .unknown,
                    contextWindowTotal: Self.integer(value["n_ctx"]).flatMap { $0 > 0 ? $0 : nil },
                    contextWindowUsed: Self.integer(value["n_past"]), updatedAt: fetchedAt)
            }.sorted { $0.id < $1.id }
            let activities = slots.compactMap { Self.boolean($0["is_processing"]) }
            if activities.contains(true) { model.isActive = true }
            else if activities.count == slots.count { model.isActive = false }
            // n_ctx is a per-slot ceiling. Expose the occupied slot with the most
            // context only when the server includes its actual n_past measurement.
            let used = slots.compactMap { slot -> (Int, Int)? in
                guard let count = Self.integer(slot["n_past"]), let total = Self.integer(slot["n_ctx"]),
                      total > 0, count <= total else { return nil }
                return (count, total)
            }.max { $0.0 < $1.0 }
            if let used { model.contextWindowUsed = used.0; model.contextWindowTotal = used.1 }
            else if let total = slots.compactMap({ Self.integer($0["n_ctx"]) }).filter({ $0 > 0 }).min() {
                model.contextWindowTotal = total
            }
        }
        // Standard llama.cpp metrics do not expose resident/model memory. Never
        // reinterpret context high-watermarks or model file sizes as memory.
    }

    private static func applyProps(_ props: [String: Any], to model: inout AIModelInfo, aliases: inout Set<String>) {
        if let name = name(props["model_alias"]) { aliases.insert(name) }
        if let path = name(props["model_path"]) { aliases.formUnion(pathAliases(path)) }
        if let defaults = props["default_generation_settings"] as? [String: Any],
           let total = integer(defaults["n_ctx"]), total > 0 { model.contextWindowTotal = total }
    }

    static func ollama(_ data: Data, endpoint: AIEndpoint, fetchedAt: Date) throws -> AIAPIReading {
        let object = try object(data)
        guard let entries = object["models"] as? [[String: Any]] else { throw AIAPIError.malformedResponse }
        var models: [AIModelInfo] = []
        var aliases: [String: Set<String>] = [:]
        var seen = Set<String>()
        for entry in entries {
            guard let modelName = name(entry["name"]) ?? name(entry["model"]) else { throw AIAPIError.malformedResponse }
            guard seen.insert(modelName).inserted else { continue }
            let model = AIModelInfo(endpointID: endpoint.id, name: modelName,
                                    memoryBytes: unsigned(entry["size"]),
                                    contextWindowTotal: integer(entry["context_length"]).flatMap { $0 > 0 ? $0 : nil },
                                    lastObservedAt: fetchedAt, isLoaded: true, gpuMemoryBytes: unsigned(entry["size_vram"]))
            models.append(model)
            aliases[modelName] = Set([modelName, name(entry["model"]), name(entry["digest"])].compactMap { $0 })
        }
        return AIAPIReading(models: models, aliases: aliases,
                            memoryBytes: AIMerge.completeMemoryTotal(models), fetchedAt: fetchedAt)
    }

    private func optionalRequest(base: URL, path: String, query: [URLQueryItem] = [], endpoint: AIEndpoint) async -> Result<Data, AIAPIError> {
        do { return .success(try await request(base: base, path: path, query: query, endpoint: endpoint)) }
        catch { return .failure(error as? AIAPIError ?? .transport) }
    }

    private func request(base: URL, path: String, query: [URLQueryItem] = [], endpoint: AIEndpoint) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AIAPIError.invalidURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(path == "metrics" ? "text/plain" : "application/json", forHTTPHeaderField: "Accept")
        if let key = endpoint.apiKey, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let operation = AIBoundedHTTP(maximumBytes: maximumResponseBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, configuration: configuration) { continuation.resume(with: $0) }
            }
        } onCancel: { operation.cancel() }
    }

    private static func validatedBaseURL(_ value: String) -> URL? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = components.scheme?.lowercased()
        return components.url
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIAPIError.malformedResponse }
        return object
    }
    private static func name(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return UInt64(number.stringValue)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(number.stringValue), value >= 0 else { return nil }
        return value
    }
    private static func modelPath(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if ["--model", "-m"].contains(argument), arguments.indices.contains(index + 1) {
                return name(arguments[index + 1])
            }
            if argument.hasPrefix("--model=") { return name(String(argument.dropFirst("--model=".count))) }
        }
        return nil
    }
    private static func pathAliases(_ path: String) -> Set<String> {
        let url = URL(fileURLWithPath: path)
        return [path, url.lastPathComponent, url.deletingPathExtension().lastPathComponent]
    }
    private static func prometheus(_ text: String) -> [String: Double] {
        var result: [String: Double] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, !fields[0].contains("{"),
                  let value = Double(fields[1]), value.isFinite, value >= 0 else { continue }
            result[String(fields[0])] = value
        }
        return result
    }
}

private final class AIAPITask: AIAPICancellable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task.cancel() }
}

private final class AIBoundedHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var body = Data()
    private var completion: ((Result<Data, AIAPIError>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var cancelled = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               completion: @escaping (Result<Data, AIAPIError>) -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); completion(.failure(.cancelled)); return }
        self.completion = completion
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<Data, AIAPIError>) {
        lock.lock()
        guard !finished, let completion else { lock.unlock(); return }
        finished = true
        self.completion = nil
        let session = self.session
        self.session = nil
        task = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        completion(result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(.malformedResponse)); return
        }
        guard http.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(.httpStatus(http.statusCode))); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(.responseTooLarge)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock(); finish(.failure(.responseTooLarge)); return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil {
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            finish(.failure(wasCancelled ? .cancelled : .transport))
        }
        else {
            lock.lock(); let data = body; lock.unlock()
            finish(.success(data))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(.httpStatus(response.statusCode)))
    }
}
