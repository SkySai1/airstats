import Foundation
import Testing
@testable import AirStatKit

@MainActor
@Suite("AI engine integration")
struct AIEngineTests {
    private func withEngine(_ run: (MetricsEngine, SettingsStore, AIEndpoint) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory, saveDebounce: .seconds(3600))
        let endpoint = AIEndpoint(name: "Local Ollama")
        store.update { $0.ai = AISettings(endpoints: [endpoint], isEnabled: true) }
        let engine = MetricsEngine(settingsStore: store)
        engine.applySettings()
        try run(engine, store, endpoint)
        store.flush()
    }

    private func sample(_ endpoint: AIEndpoint) -> SystemSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let observation = AIObservation(id: "request-1", instanceID: endpoint.id,
            kind: .generation, date: date, value: 20, tokenCount: 100, duration: 5)
        let instance = AIInstanceSnapshot(id: endpoint.id, name: endpoint.name,
            observations: [observation])
        return SystemSnapshot(ai: .value(AISnapshot(instances: [instance], capturedAt: date)), capturedAt: date)
    }

    @Test("cached AI snapshots in system samples never count a request twice")
    func cachedSnapshot() throws {
        try withEngine { engine, _, endpoint in
            let snapshot = sample(endpoint)
            engine.ingest(snapshot)
            engine.ingest(snapshot)
            #expect(engine.aiHistory.count == 1)
            #expect(engine.aiHistory.generationSeries(instanceID: endpoint.id).last?.value == 20)
        }
    }

    @Test("changing a log source clears that instance's old history")
    func changedSource() throws {
        try withEngine { engine, store, endpoint in
            engine.ingest(sample(endpoint))
            store.update { $0.ai.endpoints[0].logDirectory = "/tmp/another-instance" }
            engine.applySettings()
            #expect(engine.aiHistory.isEmpty)
        }
    }

    @Test("renaming an instance preserves its measured history")
    func renamedInstance() throws {
        try withEngine { engine, store, endpoint in
            engine.ingest(sample(endpoint))
            store.update { $0.ai.endpoints[0].name = "Renamed Ollama" }
            engine.applySettings()
            #expect(engine.aiHistory.count == 1)
        }
    }

    @Test("disabling monitoring clears history and rejects cached samples")
    func disabledMonitoring() throws {
        try withEngine { engine, store, endpoint in
            let snapshot = sample(endpoint)
            engine.ingest(snapshot)
            store.update { $0.ai.isEnabled = false }
            engine.applySettings()
            engine.ingest(snapshot)
            #expect(engine.aiHistory.isEmpty)
        }
    }
}
