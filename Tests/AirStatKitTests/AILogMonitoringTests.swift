import Foundation
import Testing
@testable import AirStatKit

@Suite("AI log monitoring")
struct AILogMonitoringTests {
    private let context = SampleContext(elapsed: 5, isFirstSample: false, activity: .panel)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airstats-ai-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func endpoint(_ directory: URL, id: UUID = UUID(), runtime: AIRuntime = .ollama,
                          pattern: String = "server*.log", enabled: Bool = true) -> AIEndpoint {
        AIEndpoint(id: id, name: "Local", isEnabled: enabled, runtime: runtime,
                   logDirectory: directory.path, logFilePattern: pattern, usesAPI: false)
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func record(_ text: String, id: String = UUID().uuidString,
                        at date: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> AILogRecord {
        AILogRecord(id: id, text: text, date: date, canChart: true)
    }

    @Test("llama timing, context and allocations are measured and retain instance identity")
    func llamaMeasurements() throws {
        let id = UUID()
        var parser = AILogParser(instanceID: id)
        parser.consume(record("srv    load_model: loading model '/models/Qwen.gguf'"))
        parser.consume(record("llama_context: n_ctx = 32768"))
        parser.consume(record("load_tensors: MTL0 model buffer size = 1024.00 MiB"))
        parser.consume(record("llama_kv_cache: MTL0 KV buffer size = 512.00 MiB"))
        parser.consume(record("sched_reserve: MTL0 compute buffer size = 128.00 MiB"))
        parser.consume(record("sched_reserve: MTL0 compute buffer size = 64.00 MiB"))
        parser.consume(record("slot operator(): id 0 | task 1 | new prompt, n_ctx_slot = 32768, task.n_tokens = 4096"))
        parser.consume(record("slot print_timing: prompt eval time = 2000.00 ms / 4000 tokens (0.50 ms per token, 2000.00 tokens per second)"))
        parser.consume(record("slot print_timing: eval time = 4000.00 ms / 200 tokens (20.00 ms per token, 50.00 tokens per second)"))
        let model = try #require(parser.model)
        #expect(model.name == "Qwen")
        #expect(model.endpointID == id)
        #expect(model.contextWindowTotal == 32768)
        #expect(model.contextWindowUsed == 4096)
        #expect(model.memoryBytes == 1600 * 1024 * 1024)
        #expect(model.tokensPerSecond == 50)
        #expect(model.contextTokensPerSecond == 2000)
        #expect(model.isActive == true)
        let generation = try #require(parser.observations.first { $0.kind == .generation })
        #expect(generation.tokenCount == 200)
        #expect(generation.duration == 4)
    }

    @Test("live llama generation rates reach history before the final eval timing")
    func liveGenerationHistory() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stdout.log")
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let instance = endpoint(dir, runtime: .llamaCpp, pattern: "std*.log")
        try Data("[60662] 0.00.100.000 I srv load_model: loading model '/models/Test.gguf'\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let collector = AICollector(now: { now })
        defer { collector.stop() }
        collector.setEndpoints([instance])
        var history = AIHistory()
        history.append(try #require(collector.collect(context: context).value))
        #expect(history.generationSeries(instanceID: instance.id).isEmpty)

        now.addTimeInterval(5)
        try append("[60662] 0.05.100.000 I slot print_timing: id  0 | task 127 | n_gen = 100, tg = 25.00 t/s, tg_3s = 20.00 t/s\n", to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let first = try #require(collector.collect(context: context).value)
        #expect(first.models.first?.tokensPerSecond == 20)
        #expect(first.models.first?.isActive == true)
        history.append(first)
        history.append(try #require(collector.collect(context: context).value))
        #expect(history.generationSeries(instanceID: instance.id).first?.value == 20)

        now.addTimeInterval(5)
        try append("[60662] 0.10.100.000 I slot print_timing: id  0 | task 127 | n_gen = 200, tg = 30.00 t/s, tg_3s = 50.00 t/s\n", to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        history.append(try #require(collector.collect(context: context).value))
        #expect(history.generationSeries(instanceID: instance.id, interval: .oneMinute).map(\.value) == [35])

        now.addTimeInterval(1)
        try append("[60662] 0.11.100.000 I slot release: id  0 | task 127 | stop processing\n[60662] 0.11.100.001 I slot print_timing: id  0 | task 127 | eval time = 10000 ms / 200 tokens (50 ms per token, 20 tokens per second)\n", to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let finished = try #require(collector.collect(context: context).value)
        #expect(finished.models.first?.tokensPerSecond == 20)
        #expect(finished.instances.first?.observations.filter { $0.kind == .generation }.isEmpty == true)
        history.append(finished)
        for interval in AIHistoryInterval.allCases {
            #expect(history.generationSeries(instanceID: instance.id, interval: interval).map(\.value) == [35])
        }
    }

    @Test("generation progress prefers the rolling rate, falls back to tg, and ends prefill")
    func streamingGenerationRates() throws {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("[60662] slot print_timing: id 0 | task 127 | prompt processing, n_tokens = 100, progress = 0.50, t = 1 s / 100 tokens per second"))
        let cases: [(String, Double)] = [
            ("tg = 19.96 t/s, tg_3s = 19.30 t/s", 19.30),
            ("tg = 19.96 t/s", 19.96),
            ("tg = 19.96 t/s, tg_3s = 0.00 t/s", 0),
        ]
        for (fields, rate) in cases {
            parser.beginPoll()
            parser.consume(record("[60662] 2.26.776.273 I slot print_timing: id 0 | task 127 | n_gen = 161, \(fields)"))
            #expect(parser.model?.tokensPerSecond == rate)
            #expect(parser.model?.prefillProgress.isEmpty == true)
            #expect(parser.model?.isActive == true)
            let observation = try #require(parser.observations.first)
            #expect(observation.kind == .generation)
            #expect(observation.value == rate)
            #expect(observation.tokenCount == nil)
            #expect(observation.duration == nil)
        }
        parser.beginPoll()
        for fields in ["n_gen = 12, tg = nan t/s", "n_gen = 12, tg = -1 t/s", "tg = 12 t/s"] {
            parser.consume(record("[60662] slot print_timing: id 0 | task 127 | \(fields)"))
        }
        #expect(parser.observations.isEmpty)
    }

    @Test("streamed request summaries are not counted twice or confused across slots and tasks")
    func streamedSummaryIdentity() {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("slot print_timing: id 0 | task 1 | n_gen = 100, tg = 20 t/s, tg_3s = 25 t/s"))
        parser.beginPoll()
        parser.consume(record("slot print_timing: id 1 | task 2 | eval time = 1000 ms / 30 tokens (33 ms per token, 30 tokens per second)"))
        parser.consume(record("slot print_timing: id 0 | task 1 | eval time = 5000 ms / 100 tokens (50 ms per token, 20 tokens per second)"))
        #expect(parser.observations.map(\.value) == [30])
        parser.beginPoll()
        parser.consume(record("slot operator(): id 0 | task 3 | new prompt, n_tokens = 100"))
        parser.consume(record("slot print_timing: id 0 | task 3 | eval time = 1000 ms / 40 tokens (25 ms per token, 40 tokens per second)"))
        #expect(parser.observations.map(\.value) == [40])
    }

    @Test("Ollama names are read from model metadata and unknown metrics stay absent")
    func ollamaMetadata() throws {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("time=2026-10-26T10:00:00.000Z level=INFO msg=\"starting llama-server\""))
        parser.consume(record("llama_model_loader: - kv 5: general.name str = Qwen3.8 27B"))
        parser.consume(record("print_info: n_ctx_train = 262144"))
        parser.consume(record("load_hparams: model size: 887.99 MiB"))
        let model = try #require(parser.model)
        #expect(model.name == "Qwen3.8 27B")
        #expect(model.contextWindowTotal == nil)
        #expect(model.contextWindowUsed == nil)
        #expect(model.memoryBytes == nil)
        #expect(model.tokensPerSecond == nil)
        parser.consume(record("{\"messages\":[{\"content\":\"eval time = 1 ms / 1 tokens (1000 tokens per second)\"}]}"))
        #expect(parser.observations.isEmpty)
        parser.consume(record("srv operator(): exit command received, exiting..."))
        #expect(parser.model == nil)
    }

    @Test("n/a model metadata never becomes a phantom model named a")
    func unavailableModelName() {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("print_info: general.name = org/model"))
        parser.consume(record("print_info: general.name = n/a"))
        parser.consume(record("llama_context: n_ctx = 262144"))
        #expect(parser.model?.name == "org/model")
        #expect(parser.model?.contextWindowTotal == 262144)
        var unknown = AILogParser(instanceID: UUID())
        unknown.consume(record("print_info: general.name = n/a"))
        #expect(unknown.model?.name != "a")
    }

    @Test("router inventory reconciles separately replayed logs and preserves concurrent runners")
    func routerInventoryReconciliation() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = AILogParser(instanceID: id)
        parser.consume(record("[10] srv load_model: loading model '/models/Old.gguf'"))
        parser.consume(record("[10] llama_context: n_ctx = 4096"))
        parser.consume(record("[20] srv load_model: loading model '/models/Current.gguf'"))
        parser.consume(record("[20] llama_context: n_ctx = 8192"))
        parser.consume(record("srv llama_server: starting server in router mode. models will be automatically loaded on-demand"))
        parser.consume(record("srv load: spawning server instance with name=current-alias on port 20"))
        var snapshot = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(snapshot.models.map(\.name) == ["Current"])
        #expect(snapshot.models.first?.contextWindowTotal == 8192)
        #expect(snapshot.models.first?.aliases.contains("current-alias") == true)
        #expect(snapshot.models.first?.aliases.contains("/models/Current.gguf") == true)
        parser.consume(record("srv load: spawning server instance with name=another-alias on port 30"))
        parser.consume(record("[30] srv load_model: loading model '/models/Another.gguf'"))
        snapshot = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(snapshot.models.map(\.name) == ["Another", "Current"])
        parser.consume(record("srv unload: stopping model instance name=current-alias"))
        snapshot = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(snapshot.models.map(\.name) == ["Another"])
    }

    @Test("a skipped log section invalidates inventory recovered from that file head")
    func sourceDiscontinuity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = AILogParser(instanceID: id)
        var old = record("[10] srv load_model: loading model '/models/Old.gguf'")
        old.sourceIdentity = "file"
        parser.consume(old)
        var newest = record("[20] srv load_model: loading model '/models/Current.gguf'")
        newest.sourceIdentity = "file"
        newest.continuityBreak = true
        parser.consume(newest)
        let snapshot = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(snapshot.models.map(\.name) == ["Current"])
    }

    @Test("loader paths, digests and metadata names become aliases on the same model")
    func measuredModelAliases() throws {
        let digest = String(repeating: "ab", count: 32)
        let path = "/models/blobs/sha256-" + digest
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("time=2026-10-26T10:00:00Z level=INFO msg=\"starting llama-server\""))
        parser.consume(record("time=2026-10-26T10:00:00Z level=INFO source=llama_server.go:1088 msg=\"loading model via llama-server\" model=\(path)"))
        parser.consume(record("srv load_model: loading model '\(path)'"))
        parser.consume(record("print_info: general.name = Human metadata name"))
        parser.consume(record("llama_context: n_ctx = 262144"))
        let model = try #require(parser.model)
        #expect(model.name == "Human metadata name")
        #expect(model.contextWindowTotal == 262144)
        #expect(model.aliases.isSuperset(of: [path, "sha256-" + digest, "sha256:" + digest,
                                             digest, "Human metadata name"]))
        var unrelated = AILogParser(instanceID: UUID())
        unrelated.consume(record("time=2026-10-26T10:00:00Z level=INFO msg=\"loading model via llama-server\" model=\(path)"))
        #expect(unrelated.model == nil)
    }

    @Test("separate runners retain models and unlabelled interleaved metrics stay unknown")
    func multipleRunners() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        var parser = AILogParser(instanceID: id)
        parser.consume(record("[10] srv load_model: loading model '/models/First.gguf'"))
        parser.consume(record("[10] llama_context: n_ctx = 4096"))
        parser.consume(record("[10] load_tensors: MTL0 model buffer size = 16 MiB"))
        parser.consume(record("[10] srv update_slots: all slots are idle"))
        parser.consume(record("[20] srv load_model: loading model '/models/Second.gguf'"))
        parser.consume(record("[20] llama_context: n_ctx = 8192"))
        parser.consume(record("[20] load_tensors: MTL0 model buffer size = 32 MiB"))
        parser.consume(record("[20] srv update_slots: all slots are idle"))
        parser.consume(record("slot print_timing: eval time = 1000 ms / 777 tokens (1 ms per token, 777 tokens per second)"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let instance = parser.snapshot(endpoint: endpoint(dir, id: id),
            read: AILogRead(modifiedAt: now), now: now)
        #expect(instance.models.map(\.name) == ["First", "Second"])
        #expect(instance.models.map(\.contextWindowTotal) == [4096, 8192])
        #expect(instance.models.allSatisfy { $0.tokensPerSecond == nil })
        #expect(instance.memoryBytes == 48 * 1024 * 1024)
        #expect(parser.observations.allSatisfy { $0.kind != .generation })
        parser.consume(record("[10] srv operator(): exit command received, exiting..."))
        let remaining = parser.snapshot(endpoint: endpoint(dir, id: id),
            read: AILogRead(modifiedAt: now), now: now)
        #expect(remaining.models.map(\.name) == ["Second"])
    }

    @Test("daemon restart invalidates models recovered from earlier rotations")
    func daemonRestart() {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("print_info: general.name = Previous session"))
        parser.consume(record("llama_context: n_ctx = 4096"))
        #expect(parser.model != nil)
        parser.consume(record("time=2026-10-26T10:00:00Z level=INFO source=routes.go:2454 msg=\"server config\""))
        #expect(parser.model == nil)
        parser.consume(record("print_info: general.name = Current session"))
        #expect(parser.model?.name == "Current session")
    }

    @Test("unnamed runners still have distinct stable model identities")
    func unnamedRunnerIdentity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = AILogParser(instanceID: id)
        parser.consume(record("[10] llama_context: n_ctx = 4096"))
        parser.consume(record("[20] llama_context: n_ctx = 8192"))
        let instance = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(instance.models.count == 2)
        #expect(Set(instance.models.map(\.id)).count == 2)
        parser.beginPoll()
        let repeated = parser.snapshot(endpoint: endpoint(dir, id: id), read: AILogRead(modifiedAt: now), now: now)
        #expect(instance.models.map(\.id) == repeated.models.map(\.id))
    }

    @Test("one slot finishing leaves other slots active and rates expire by age")
    func concurrentSlotsAndRateAge() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = AILogParser(instanceID: id)
        parser.consume(record("srv load_model: loading model '/models/Test.gguf'"))
        parser.consume(record("llama_context: n_ctx = 8192"))
        parser.consume(record("srv load_model: initializing, n_slots = 2, n_ctx_slot = 4096"))
        parser.consume(record("srv update_slots: all slots are idle"))
        parser.consume(record("slot operator(): id 0 | task 1 | new prompt, n_tokens = 256"))
        parser.consume(record("slot operator(): id 1 | task 2 | new prompt, n_tokens = 512"))
        parser.consume(record("slot release: id 0 | task 1 | stop processing: n_tokens = 300"))
        parser.consume(record("slot print_timing: id 0 | task 1 | eval time = 1000 ms / 20 tokens (50 ms per token, 20 tokens per second)"))
        parser.consume(record("slot print_timing: id 1 | task 2 | prompt processing, n_tokens = 512, t = 1 s / 512 tokens per second"))
        #expect(parser.model?.isActive == true)
        #expect(parser.model?.contextWindowUsed == 812)
        #expect(parser.model?.contextWindowTotal == 8192)
        #expect(parser.observations.filter { $0.kind == .prefill }.isEmpty)
        parser.beginPoll()
        #expect(parser.model?.tokensPerSecond == 20)
        #expect(parser.observations.isEmpty)
        let fresh = parser.snapshot(endpoint: endpoint(dir, id: id),
            read: AILogRead(modifiedAt: date), now: date.addingTimeInterval(10))
        #expect(fresh.models.first?.tokensPerSecond == 20)
        let expired = parser.snapshot(endpoint: endpoint(dir, id: id),
            read: AILogRead(modifiedAt: date), now: date.addingTimeInterval(61))
        #expect(expired.models.first?.tokensPerSecond == nil)
    }

    @Test("the reported prefill fraction is independent of context capacity and supports clipped speed units")
    func measuredPrefillProgress() throws {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("prompt processing, n_tokens = 90527, progress = 0.97, t = 707.35 s / 127.98 tokens per secon"))
        let model = try #require(parser.model)
        let progress = try #require(model.prefillProgress.first)
        #expect(progress.slotID == nil)
        #expect(progress.taskID == nil)
        #expect(progress.fraction == 0.97)
        #expect(progress.processedTokens == 90527)
        #expect(progress.elapsed == 707.35)
        #expect(progress.tokensPerSecond == 127.98)
        #expect(model.contextWindowTotal == nil)
        #expect(model.contextTokensPerSecond == 127.98)
        #expect(model.isActive == true)
        #expect(parser.observations.map(\.kind) == [.prefill])
        #expect(parser.observations.first?.tokenCount == nil)
        parser.consume(record("start decoding"))
        #expect(parser.model?.prefillProgress.isEmpty == true)
        parser.consume(record("llama_context: n_ctx = 262144"))
        parser.consume(record("slot print_timing: id 0 | task 42 | prompt processing, n_tokens = 90527, progress = 0.97, t = 707.35 s / 127.98 tokens per second"))
        let identified = try #require(parser.model?.prefillProgress.first { $0.slotID == 0 })
        #expect(identified.taskID == 42)
        #expect(identified.fraction == 0.97)
        #expect(parser.model?.contextWindowTotal == 262144)
    }

    @Test("invalid progress is absent while a valid fraction does not require speed or elapsed time")
    func invalidPrefillProgress() throws {
        for fraction in ["NaN", "inf", "-0.01", "1.01", "0.97junk"] {
            var parser = AILogParser(instanceID: UUID())
            parser.consume(record("slot print_timing: id 0 | task 1 | prompt processing, n_tokens = 20, progress = \(fraction), t = 1 s / 20 tokens per second"))
            #expect(parser.model?.prefillProgress.isEmpty != false)
        }
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("prompt processing, n_tokens = 90527, progress = 0.97, t = NaN s / unavailable"))
        let progress = try #require(parser.model?.prefillProgress.first)
        #expect(progress.fraction == 0.97)
        #expect(progress.tokensPerSecond == nil)
        #expect(progress.elapsed == nil)
        #expect(parser.model?.contextTokensPerSecond == nil)
        var fractionalTokens = AILogParser(instanceID: UUID())
        fractionalTokens.consume(record("prompt processing, n_tokens = 20.5, progress = 0.97"))
        #expect(fractionalTokens.model?.prefillProgress.isEmpty != false)
    }

    @Test("new tasks replace their own progress and delayed completion cannot erase a newer request")
    func prefillTaskLifecycle() throws {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("print_info: general.name = Concurrent"))
        parser.consume(record("srv load_model: initializing, n_slots = 2, n_ctx_slot = 4096"))
        parser.consume(record("slot print_timing: id 0 | task 10 | prompt processing, n_tokens = 100, progress = 0.10, t = 1 s / 100 tokens per second"))
        parser.consume(record("slot print_timing: id 1 | task 11 | prompt processing, n_tokens = 200, progress = 0.20, t = 2 s / 100 tokens per second"))
        #expect(parser.model?.prefillProgress.map(\.slotID) == [0, 1])
        parser.consume(record("slot operator(): id 0 | task 20 | new prompt, n_tokens = 0"))
        #expect(parser.model?.prefillProgress.map(\.taskID) == [11])
        parser.consume(record("slot print_timing: id 0 | task 20 | prompt processing, n_tokens = 300, progress = 0.30, t = 3 s / 100 tokens per second"))
        parser.consume(record("slot release: id 0 | task 10 | stop processing: n_tokens = 100"))
        #expect(parser.model?.prefillProgress.map(\.taskID) == [20, 11])
        parser.consume(record("slot launch_slot: id 0 | task 21 | processing task"))
        #expect(parser.model?.prefillProgress.map(\.taskID) == [11])
        parser.consume(record("slot print_timing: id 0 | task 21 | prompt processing, n_tokens = 50, progress = 0.05, t = 0.5 s / 100 tokens per second"))
        #expect(parser.model?.prefillProgress.map(\.taskID) == [21, 11])
        parser.consume(record("slot release: id 0 | task 21 | stop processing: n_tokens = 1",
                              at: Date(timeIntervalSince1970: 1_799_999_999)))
        #expect(parser.model?.prefillProgress.map(\.taskID) == [21, 11])
        #expect(parser.observations.map(\.taskID) == [10, 11, 20, 21])
        #expect(parser.observations.allSatisfy { $0.kind == .prefill })
    }

    @Test("prefill completion, decoding, release and reset preserve other slots")
    func prefillSlotCompletion() {
        let endings = [
            "slot print_timing: id 0 | task 10 | prompt eval time = 1000 ms / 100 tokens (10 ms per token, 100 tokens per second)",
            "slot print_timing: id 0 | task 10 | eval time = 1000 ms / 10 tokens (100 ms per token, 10 tokens per second)",
            "slot update_slots: id 0 | task 10 | prompt done, n_tokens = 100",
            "slot update_slots: id 0 | task 10 | start decoding",
            "slot release: id 0 | task 10 | stop processing: n_tokens = 100",
            "slot release: id 0 | task 10 | released",
            "slot reset: id 0 | task 10 | reset slot"
        ]
        for ending in endings {
            var parser = AILogParser(instanceID: UUID())
            parser.consume(record("print_info: general.name = Concurrent"))
            parser.consume(record("srv load_model: initializing, n_slots = 2, n_ctx_slot = 4096"))
            parser.consume(record("slot print_timing: id 0 | task 10 | prompt processing, n_tokens = 100, progress = 0.10, t = 1 s / 100 tokens per second"))
            parser.consume(record("slot print_timing: id 1 | task 11 | prompt processing, n_tokens = 200, progress = 0.20, t = 2 s / 100 tokens per second"))
            parser.consume(record(ending))
            #expect(parser.model?.prefillProgress.map(\.slotID) == [1])
            #expect(parser.model?.contextTokensPerSecond == 100)
        }
    }

    @Test("idle, sleep and model shutdown end every prefill request")
    func prefillGlobalCompletion() {
        for ending in ["srv update_slots: all slots are idle", "srv handle_sleep: server is entering sleeping state",
                       "srv operator(): exit command received, exiting..."] {
            var parser = AILogParser(instanceID: UUID())
            parser.consume(record("print_info: general.name = Concurrent"))
            parser.consume(record("slot print_timing: id 0 | task 10 | prompt processing, n_tokens = 100, progress = 0.10, t = 1 s / 100 tokens per second"))
            parser.consume(record("slot print_timing: id 1 | task 11 | prompt processing, n_tokens = 200, progress = 0.20, t = 2 s / 100 tokens per second"))
            parser.consume(record(ending))
            #expect(parser.model?.prefillProgress.isEmpty != false)
        }
    }

    @Test("progress expires without fresh measurements and timestamp-less backlog stays historical")
    func prefillFreshness() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = AILogParser(instanceID: id)
        parser.consume(record("prompt processing, n_tokens = 90527, progress = 0.97, t = 707.35 s / 127.98 tokens per second", at: now))
        let source = endpoint(dir, id: id)
        let fresh = parser.snapshot(endpoint: source, read: AILogRead(modifiedAt: now), now: now.addingTimeInterval(59))
        #expect(fresh.models.first?.prefillProgress.count == 1)
        let expired = parser.snapshot(endpoint: source, read: AILogRead(modifiedAt: now), now: now.addingTimeInterval(61))
        #expect(expired.models.first?.prefillProgress.isEmpty == true)
        let stale = parser.snapshot(endpoint: source, read: AILogRead(modifiedAt: now.addingTimeInterval(-600)), now: now)
        #expect(stale.models.first?.prefillProgress.isEmpty == true)
        var backlog = AILogParser(instanceID: UUID())
        var old = record("slot print_timing: id 0 | task 1 | prompt processing, n_tokens = 90527, progress = 0.97, t = 707.35 s / 127.98 tokens per second")
        old.canChart = false
        backlog.consume(old)
        #expect(backlog.model?.prefillProgress.isEmpty != false)
        parser.beginPoll()
        #expect(parser.observations.isEmpty)
        #expect(parser.model?.contextTokensPerSecond == 127.98)
    }

    @Test("allocation overflow is unknown rather than a wrapped memory value")
    func allocationOverflow() {
        var parser = AILogParser(instanceID: UUID())
        parser.consume(record("print_info: general.name = Huge"))
        parser.consume(record("load_tensors: CPU model buffer size = 10000000000000000000 bytes"))
        parser.consume(record("load_tensors: MTL0 model buffer size = 10000000000000000000 bytes"))
        #expect(parser.model?.memoryBytes == nil)
    }

    @Test("wildcards, rename rotation and replacement do not replay old measurements")
    func rotations() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.log")
        try Data("print_info: general.name = Test\n".utf8).write(to: file)
        let tailer = AILogTailer()
        let first = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(first.records.count == 1)
        #expect(tailer.read(directory: dir.path, pattern: "server*.log", now: Date()).records.isEmpty)
        try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("server-1.log"))
        try Data("llama_context: n_ctx = 4096\n".utf8).write(to: file)
        let rotated = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(rotated.records.count == 1)
        #expect(rotated.records.first?.text == "llama_context: n_ctx = 4096")
        #expect(rotated.records.first?.id != first.records.first?.id)
        try Data("slot release: n_tokens = 7\n".utf8).write(to: file)
        let truncated = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(truncated.records.count == 1)
        #expect(truncated.records.first?.text == "slot release: n_tokens = 7")
    }

    @Test("copytruncate that regrows past the old offset is detected with an identical startup prefix")
    func regrownCopytruncate() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.log")
        let common = String(repeating: "startup common prefix\n", count: 30)
        try Data((common + "old measurement\n").utf8).write(to: file)
        let tailer = AILogTailer()
        _ = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        let replacement = common + "new measurement A\nnew measurement B\n"
        try Data(replacement.utf8).write(to: file)
        let read = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(read.records.contains { $0.text == "new measurement A" })
        #expect(read.records.contains { $0.text == "new measurement B" })
    }

    @Test("copied rotations preserve dated event identities for history deduplication")
    func copiedRotationIdentity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.log")
        let text = "time=2026-10-26T10:00:00.123Z slot print_timing: eval time = 1000 ms / 20 tokens (50 ms per token, 20 tokens per second)\n"
        try Data(text.utf8).write(to: file)
        let tailer = AILogTailer()
        let first = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        try FileManager.default.copyItem(at: file, to: dir.appendingPathComponent("server-1.log"))
        let copied = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(first.records.count == 1)
        #expect(copied.records.count == 1)
        #expect(first.records.first?.id == copied.records.first?.id)
    }

    @Test("partial UTF-8 records are emitted once after the newline arrives")
    func partialRecords() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stdout.log")
        let line = "print_info: general.name = Model \u{1F680}"
        let bytes = Data((line + "\n").utf8)
        // Leave half the four-byte symbol for the next append.
        let split = bytes.count - 3
        try bytes.prefix(split).write(to: file)
        let tailer = AILogTailer()
        #expect(tailer.read(directory: dir.path, pattern: "std*.log", now: Date()).records.isEmpty)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes.suffix(from: split))
        let read = tailer.read(directory: dir.path, pattern: "std*.log", now: Date())
        #expect(read.records.map(\.text) == [line])
        #expect(tailer.read(directory: dir.path, pattern: "std*.log", now: Date()).records.isEmpty)
    }

    @Test("large initial logs have bounded reads and do not manufacture history timestamps")
    func boundedBackfill() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.log")
        var bytes = Data("print_info: general.name = Large\n".utf8)
        bytes.append(Data(repeating: 120, count: 5 * 1024 * 1024))
        bytes.append(Data("\nslot print_timing: eval time = 1000 ms / 20 tokens (50 ms per token, 20 tokens per second)\n".utf8))
        try bytes.write(to: file)
        let tailer = AILogTailer()
        let first = tailer.read(directory: dir.path, pattern: "server*.log", now: Date())
        #expect(first.bytesRead <= AILogTailer.maximumBytesPerPoll)
        #expect(first.bytesRead <= AILogTailer.maximumBytesPerFile + 384)
        #expect(first.records.contains { $0.text.contains("general.name") })
        #expect(first.records.contains { $0.text.contains("eval time") })
        #expect(first.records.allSatisfy { !$0.canChart })
        #expect(tailer.read(directory: dir.path, pattern: "server*.log", now: Date()).bytesRead == 0)
    }

    @Test("disabled and missing sources report their own status without merging equal models")
    func sourceStatusAndIdentity() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("print_info: general.name = Same\nllama_context: n_ctx = 8192\n".utf8)
            .write(to: dir.appendingPathComponent("server.log"))
        let a = endpoint(dir)
        let b = endpoint(dir)
        let disabled = endpoint(dir, enabled: false)
        let missing = endpoint(dir, pattern: "missing*.log")
        let collector = AICollector()
        collector.setEndpoints([a, b, disabled, missing])
        let snapshot = try #require(collector.collect(context: context).value)
        #expect(snapshot.instances.count == 4)
        #expect(snapshot.models.count == 2)
        #expect(Set(snapshot.models.map(\.id)).count == 2)
        #expect(Set(snapshot.models.map(\.endpointID)) == Set([a.id, b.id]))
        #expect(snapshot.instances.first { $0.id == disabled.id }?.status == .disabled)
        #expect(snapshot.instances.first { $0.id == missing.id }?.status == .missingLogs)
        let next = try #require(collector.collect(context: context).value)
        #expect(snapshot.models.map(\.id) == next.models.map(\.id))
    }

    @Test("timestamp-less backlog cannot establish current activity or generation speed")
    func backlogActivityUnknown() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(("print_info: general.name = Historical\n"
            + "slot operator(): new prompt, n_ctx_slot = 4096, n_tokens = 512\n"
            + "slot print_timing: eval time = 1000 ms / 20 tokens (50 ms per token, 20 tokens per second)\n").utf8)
            .write(to: dir.appendingPathComponent("server.log"))
        let collector = AICollector(apiClient: AIAPIClient(), processInspector: FakeAIProcessInspector())
        collector.setEndpoints([endpoint(dir)])
        let instance = try #require(collector.collect(context: context).value?.instances.first)
        #expect(instance.models.first?.name == "Historical")
        #expect(instance.models.first?.isActive == nil)
        #expect(instance.models.first?.tokensPerSecond == nil)
        #expect(instance.observations.isEmpty)
    }

    @Test("stale logs cannot claim current memory, context use or activity")
    func staleMeasurements() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("server.log")
        try Data("print_info: general.name = Old\nload_tensors: MTL0 model buffer size = 12 MiB\nslot operator(): new prompt, n_ctx_slot = 1024, n_tokens = 64\n".utf8).write(to: file)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: file.path)
        let collector = AICollector(apiClient: AIAPIClient(), processInspector: FakeAIProcessInspector(), now: { now })
        collector.setEndpoints([endpoint(dir)])
        let instance = try #require(collector.collect(context: context).value?.instances.first)
        #expect(instance.status == .stale)
        #expect(instance.memoryBytes == nil)
        #expect(instance.models.first?.isActive == nil)
        #expect(instance.models.first?.contextWindowUsed == nil)
        #expect(instance.models.first?.contextWindowTotal == 1024)
    }
}

@Suite("AI measurement history")
struct AIHistoryTests {
    private let id = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ observations: [AIObservation], at date: Date) -> AISnapshot {
        AISnapshot(instances: [AIInstanceSnapshot(id: id, name: "Test", observations: observations)], capturedAt: date)
    }

    @Test("generation uses token/duration weighting and repeated snapshots are idempotent")
    func weightedAndDeduplicated() throws {
        let a = AIObservation(id: "a", instanceID: id, kind: .generation, date: start,
                              value: 10, tokenCount: 100, duration: 10)
        let b = AIObservation(id: "b", instanceID: id, kind: .generation, date: start.addingTimeInterval(20),
                              value: 30, tokenCount: 30, duration: 1)
        let sample = snapshot([a, b], at: start.addingTimeInterval(30))
        var history = AIHistory()
        history.append(sample)
        history.append(sample)
        #expect(history.count == 2)
        let point = try #require(history.generationSeries(instanceID: id).first)
        #expect(abs(point.value - 130.0 / 11.0) < 0.0001)
        #expect(history.generationSeries(instanceID: UUID()).isEmpty)
    }

    @Test("1m, 5m and 15m buckets preserve gaps and memory remains per instance")
    func bucketIntervals() {
        let events = [0.0, 59, 60, 300, 900].enumerated().map { index, offset in
            AIObservation(id: "\(index)", instanceID: id, kind: .generation,
                          date: start.addingTimeInterval(offset), value: Double(index + 1))
        }
        var history = AIHistory()
        history.append(snapshot(events, at: start.addingTimeInterval(901)))
        let minuteSeries = history.generationSeries(instanceID: id, interval: .oneMinute)
        #expect(minuteSeries.count == 4)
        #expect(minuteSeries.first?.value == 1.5)
        #expect(minuteSeries.map(\.date) == [0.0, 60, 300, 900].map { start.addingTimeInterval($0) })
        #expect(history.generationSeries(instanceID: id, interval: .fiveMinutes).map(\.value) == [2, 4, 5])
        #expect(history.generationSeries(instanceID: id, interval: .fifteenMinutes).map(\.value) == [2.5, 5])
        #expect(history.memorySeries(instanceID: id).isEmpty)
        history.append(snapshot([AIObservation(id: "memory", instanceID: id, kind: .memory,
            date: start.addingTimeInterval(902), value: 1024)], at: start.addingTimeInterval(903)))
        #expect(history.memorySeries(instanceID: id).first?.value == 1024)
    }

    @Test("retention and capacity stay bounded and removing an instance removes its series")
    func boundedHistory() {
        var history = AIHistory(retention: 900, capacity: 3)
        for index in 0..<10 {
            let date = start.addingTimeInterval(Double(index * 100))
            history.append(snapshot([AIObservation(id: "\(index)", instanceID: id,
                kind: .memory, date: date, value: Double(index))], at: date))
        }
        #expect(history.count == 3)
        history.append(snapshot([], at: start.addingTimeInterval(3000)))
        #expect(history.isEmpty)
        history.retainInstances([])
        #expect(history.generationSeries(instanceID: id).isEmpty)
    }
}
