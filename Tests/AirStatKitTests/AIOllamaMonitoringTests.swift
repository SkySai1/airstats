import Foundation
import Testing
@testable import AirStatKit

@Suite("Ollama runner identity and lifecycle")
struct AIOllamaMonitoringTests {
    private let id = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let blob = String(repeating: "b", count: 64)
    private let manifest = String(repeating: "a", count: 64)

    private func record(_ text: String) -> AILogRecord {
        AILogRecord(id: UUID().uuidString, text: text, date: date, canChart: true)
    }

    private func load(_ parser: inout AILogParser, name: String, blob: String, tag: String, count: Int) {
        let path = "/models/blobs/sha256-" + blob
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"starting llama-server\" cmd=\"/Applications/Ollama.app/Contents/Resources/llama-server --model \(path) --port 63879 --no-log-prefix\""))
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"loading model via llama-server\" model=\(path)"))
        parser.consume(record("print_info: general.name = \(name)"))
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"template selection\" model=\(tag)"))
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"loaded runners\" count=\(count)"))
    }

    private func snapshot(_ parser: AILogParser) -> AIInstanceSnapshot {
        parser.snapshot(endpoint: AIEndpoint(id: id), read: AILogRead(modifiedAt: date), now: date)
    }

    @Test("the public tag joins API manifest identity to GGUF log and process identity")
    func publicTagAndBlob() throws {
        var parser = AILogParser(instanceID: id)
        load(&parser, name: "Metadata Name", blob: blob, tag: "registry.ollama.ai/library/custom:27b", count: 1)
        parser.consume(record("slot operator(): id 0 | task 12 | new prompt, n_ctx_slot = 8192, n_tokens = 4000"))
        parser.consume(record("slot print_timing: id 0 | task 12 | n_gen = 100, tg = 20 t/s, tg_3s = 40 t/s"))
        let endpoint = AIEndpoint(id: id)
        let data = Data("{\"models\":[{\"name\":\"custom:27b\",\"model\":\"custom:27b\",\"digest\":\"\(manifest)\",\"context_length\":8192}]}".utf8)
        let api = try AIAPIClient.ollama(data, endpoint: endpoint, fetchedAt: date)
        let merged = AIMerge.snapshot(logs: snapshot(parser), api: api, apiStatus: .online, now: date)
        let model = try #require(merged.models.first)
        #expect(model.name == "custom:27b")
        #expect(model.tokensPerSecond == 40)
        #expect(model.slots.first?.taskID == 12)
        #expect(model.slots.first?.phase == .answer)
        #expect(model.aliases.contains("/models/blobs/sha256-" + blob))
        #expect(model.aliases.contains(manifest))
        let inspector = FakeAIProcessInspector(nodes: [
            AIProcessNode(pid: 10, parentPID: 1, startedAt: 1, isRuntime: true, listeningPorts: [11434]),
            AIProcessNode(pid: 11, parentPID: 10, startedAt: 2, isRuntime: true, isWorker: true,
                          modelIdentifiers: ["/models/blobs/sha256-" + blob]),
        ], readings: [11: AIProcessMemory(pid: 11, residentBytes: 8192)])
        let measured = AIProcessMemoryCollector(inspector: inspector).apply(to: merged, endpoint: endpoint, now: date)
        #expect(measured.processMemoryStatus == .measured)
        #expect(measured.models.first?.memoryBytes == 8192)
        var history = AIHistory()
        history.append(AISnapshot(instances: [measured], capturedAt: date))
        #expect(history.generationSeries(instanceID: id, modelID: model.historyID, slotID: 0).map(\.value) == [40])
    }

    @Test("a single loaded runner retires previous unlabelled states after model reloads")
    func singleRunnerReload() {
        var parser = AILogParser(instanceID: id)
        load(&parser, name: "Previous", blob: String(repeating: "c", count: 64), tag: "registry.ollama.ai/library/old:latest", count: 1)
        load(&parser, name: "Current", blob: blob, tag: "registry.ollama.ai/library/current:latest", count: 1)
        parser.consume(record("slot print_timing: id 0 | task 15 | prompt processing, n_tokens = 100, progress = 0.5, t = 1 s / 100 tokens per second"))
        let instance = snapshot(parser)
        #expect(instance.models.map(\.name) == ["Current"])
        #expect(instance.models.first?.prefillProgress.first?.fraction == 0.5)
        parser.beginPoll()
        parser.consume(record("slot print_timing: id 0 | task 15 | n_gen = 100, tg = 20 t/s, tg_3s = 25 t/s"))
        #expect(snapshot(parser).models.first?.tokensPerSecond == 25)
        #expect(parser.observations.map(\.kind) == [.generation])
    }

    @Test("multiple loaded runners keep unlabelled output ambiguous and preserve namespaces")
    func concurrentRunners() {
        var parser = AILogParser(instanceID: id)
        load(&parser, name: "First", blob: blob, tag: "registry.ollama.ai/team/custom:latest", count: 1)
        load(&parser, name: "Second", blob: String(repeating: "c", count: 64), tag: "registry.ollama.ai/other/custom:latest", count: 2)
        parser.beginPoll()
        parser.consume(record("slot print_timing: id 0 | task 15 | n_gen = 100, tg = 20 t/s, tg_3s = 25 t/s"))
        let models = snapshot(parser).models
        #expect(models.count == 2)
        #expect(models[0].aliases.contains("team/custom:latest"))
        #expect(models[1].aliases.contains("other/custom:latest"))
        #expect(models.allSatisfy { !$0.aliases.contains("custom:latest") && $0.tokensPerSecond == nil })
        #expect(parser.observations.isEmpty)
    }

    @Test("a template query outside an observed load cannot alias an existing model")
    func unrelatedTemplate() {
        var parser = AILogParser(instanceID: id)
        load(&parser, name: "Current", blob: blob, tag: "registry.ollama.ai/library/current:latest", count: 1)
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"template selection\" model=registry.ollama.ai/library/unrelated:latest"))
        #expect(parser.model?.aliases.contains("unrelated:latest") == false)
        parser.consume(record("time=2027-01-15T08:00:00Z level=INFO msg=\"loaded runners\" count=0"))
        #expect(snapshot(parser).models.isEmpty)
    }
}
