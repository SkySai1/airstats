import Foundation
import Testing
@testable import AirStatKit

final class FakeAIProcessInspector: AIProcessInspecting {
    var nodes: [AIProcessNode]?
    var readings: [Int32: AIProcessMemory]
    var invalidPIDs = Set<Int32>()
    private(set) var inventoryCount = 0

    init(nodes: [AIProcessNode] = [], readings: [Int32: AIProcessMemory] = [:]) {
        self.nodes = nodes
        self.readings = readings
    }
    func inventory() -> [AIProcessNode]? { inventoryCount += 1; return nodes }
    func isCurrent(_ process: AIProcessNode) -> Bool { !invalidPIDs.contains(process.pid) }
    func memory(for process: AIProcessNode) -> AIProcessMemory? {
        isCurrent(process) ? readings[process.pid] : nil
    }
}

@Suite("AI memory follows local model processes")
struct AIProcessMemoryTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let endpoint = AIEndpoint(url: "http://localhost:11436", runtime: .llamaCpp)

    private func root(_ pid: Int32 = 10, port: UInt16 = 11436) -> AIProcessNode {
        AIProcessNode(pid: pid, parentPID: 1, startedAt: 1, isRuntime: true, listeningPorts: [port])
    }
    private func worker(_ pid: Int32, parent: Int32 = 10, model: String) -> AIProcessNode {
        AIProcessNode(pid: pid, parentPID: parent, startedAt: 2, isRuntime: true,
                      isWorker: true, modelIdentifiers: [model])
    }
    private func snapshot(_ names: [String] = ["A", "B"]) -> AIInstanceSnapshot {
        AIInstanceSnapshot(id: endpoint.id, name: endpoint.name,
            models: names.map { AIModelInfo(endpointID: endpoint.id, name: $0, memoryBytes: 999_999) },
            memoryBytes: 999_999, observations: [
                AIObservation(id: "api-memory", instanceID: endpoint.id, kind: .memory, date: date, value: 999_999),
                AIObservation(id: "generation", instanceID: endpoint.id, kind: .generation, date: date, value: 50),
            ])
    }

    @Test("workers are selected by listening port and ancestry rather than global model names")
    func processTree() {
        let wrapper = AIProcessNode(pid: 12, parentPID: 10, startedAt: 2)
        let inspector = FakeAIProcessInspector(nodes: [root(), worker(11, model: "A"), wrapper,
            worker(13, parent: 12, model: "B"), root(20, port: 11437), worker(21, parent: 20, model: "A")], readings: [
                10: AIProcessMemory(pid: 10, residentBytes: 999_999),
                11: AIProcessMemory(pid: 11, residentBytes: 1000, physicalFootprintBytes: 800),
                13: AIProcessMemory(pid: 13, residentBytes: 2000, physicalFootprintBytes: 1500),
                21: AIProcessMemory(pid: 21, residentBytes: 888_888),
            ])
        let result = AIProcessMemoryCollector(inspector: inspector).apply(to: snapshot(), endpoint: endpoint, now: date)
        #expect(result.memoryBytes == 3000)
        #expect(result.models.map(\.memoryBytes) == [1000, 2000])
        #expect(result.processes.map(\.pid) == [11, 13])
        #expect(result.processMemoryStatus == .measured)
        #expect(result.observations.filter { $0.kind == .memory }.map(\.value) == [3000])
        #expect(result.observations.contains { $0.kind == .generation })
    }

    @Test("direct servers are measured and loaded paths match model aliases")
    func directServer() {
        var server = root()
        server.isWorker = true
        server.modelIdentifiers = ["/models/weights.gguf"]
        let inspector = FakeAIProcessInspector(nodes: [server], readings: [10: AIProcessMemory(pid: 10, residentBytes: 4096)])
        var input = snapshot(["Custom API name"])
        input.models[0].aliases = ["weights"]
        let result = AIProcessMemoryCollector(inspector: inspector).apply(to: input, endpoint: endpoint, now: date)
        #expect(result.models.first?.memoryBytes == 4096)
        #expect(result.models.first?.processes.first?.physicalFootprintBytes == nil)
    }

    @Test("ambiguous model aliases never assign one worker's memory to multiple models")
    func ambiguousAliases() {
        let inspector = FakeAIProcessInspector(nodes: [root(), worker(11, model: "shared")],
            readings: [11: AIProcessMemory(pid: 11, residentBytes: 1000)])
        var input = snapshot()
        for index in input.models.indices { input.models[index].aliases = ["shared"] }
        let result = AIProcessMemoryCollector(inspector: inspector).apply(to: input, endpoint: endpoint, now: date)
        #expect(result.memoryBytes == 1000)
        #expect(result.models.allSatisfy { $0.memoryBytes == nil })
        #expect(result.processMemoryStatus == .ambiguous)
    }

    @Test("an unreadable worker makes the total unavailable without substituting API sizes")
    func partialMeasurement() {
        let inspector = FakeAIProcessInspector(nodes: [root(), worker(11, model: "A"), worker(12, model: "B")],
            readings: [11: AIProcessMemory(pid: 11, residentBytes: 1000)])
        let result = AIProcessMemoryCollector(inspector: inspector).apply(to: snapshot(), endpoint: endpoint, now: date)
        #expect(result.memoryBytes == nil)
        #expect(result.models.map(\.memoryBytes) == [1000, nil])
        #expect(result.processMemoryStatus == .partial)
        #expect(result.observations.allSatisfy { $0.kind != .memory })
    }

    @Test("discovery is cached while RSS is measured again on each sample")
    func liveMeasurements() {
        let inspector = FakeAIProcessInspector(nodes: [root(), worker(11, model: "A")],
            readings: [11: AIProcessMemory(pid: 11, residentBytes: 1000)])
        let collector = AIProcessMemoryCollector(inspector: inspector)
        #expect(collector.apply(to: snapshot(["A"]), endpoint: endpoint, now: date).memoryBytes == 1000)
        inspector.readings[11] = AIProcessMemory(pid: 11, residentBytes: 2000)
        #expect(collector.apply(to: snapshot(["A"]), endpoint: endpoint, now: date.addingTimeInterval(1)).memoryBytes == 2000)
        #expect(inspector.inventoryCount == 1)
        _ = collector.apply(to: snapshot(["A"]), endpoint: endpoint, now: date.addingTimeInterval(5))
        #expect(inspector.inventoryCount == 2)
        inspector.invalidPIDs.insert(10)
        let exited = collector.apply(to: snapshot(["A"]), endpoint: endpoint, now: date.addingTimeInterval(6))
        #expect(exited.memoryBytes == nil)
        #expect(exited.processMemoryStatus == .unavailable)
    }

    @Test("remote addresses cannot be attributed to a local process sharing the port")
    func remoteEndpoint() {
        let inspector = FakeAIProcessInspector(nodes: [root(), worker(11, model: "A")])
        var remote = endpoint
        remote.url = "https://inference.example.com:11436"
        let result = AIProcessMemoryCollector(inspector: inspector).apply(to: snapshot(), endpoint: remote, now: date)
        #expect(result.processMemoryStatus == .remote)
        #expect(result.memoryBytes == nil)
        #expect(inspector.inventoryCount == 0)
    }

    @Test("process arguments expose model identifiers without retaining keys or other options")
    func modelArguments() {
        let identifiers = NativeAIProcessInspector.modelIdentifiers([
            "llama-server", "--api-key", "private-test-key", "--model", "/models/Test.gguf", "--alias=served",
        ])
        #expect(identifiers.contains("Test"))
        #expect(identifiers.contains("served"))
        #expect(!identifiers.contains("private-test-key"))
        #expect(AIProcessMemoryCollector.sum([UInt64.max, 1]) == nil)
    }
}
