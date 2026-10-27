import Foundation

extension SnapshotFixtures {
    /// Stable instance identities exercise the same model name on two servers.
    public static var aiEndpoints: [AIEndpoint] {
        [
            AIEndpoint(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                       name: "Ollama · local", runtime: .ollama),
            AIEndpoint(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                       name: "llama.cpp · research", runtime: .llamaCpp),
        ]
    }

    public static func ai(capturedAt: Date = referenceDate) -> AISnapshot {
        let endpoints = aiEndpoints
        let active = AIModelInfo(endpointID: endpoints[0].id, name: "Qwen3-8B-Q4_K_M",
                                 memoryBytes: 6_845_104_128,
                                 contextWindowTotal: 32_768, contextWindowUsed: 8_640,
                                 tokensPerSecond: 42.8, contextTokensPerSecond: 618.4,
                                 isActive: true, lastObservedAt: capturedAt,
                                 isLoaded: true, gpuMemoryBytes: 5_368_709_120,
                                 processes: [AIProcessMemory(pid: 4201, residentBytes: 6_845_104_128,
                                                            physicalFootprintBytes: 5_792_333_824)])
        let historical = AIModelInfo(endpointID: endpoints[1].id, name: "Qwen3-8B-Q4_K_M",
                                     contextWindowTotal: 8_192,
                                     lastObservedAt: capturedAt.addingTimeInterval(-2_400))
        return AISnapshot(overallRAMUsage: 0.71, instances: [
            AIInstanceSnapshot(id: endpoints[0].id, name: endpoints[0].name, runtime: .ollama,
                               models: [active], memoryBytes: active.memoryBytes,
                               lastEventAt: capturedAt, apiStatus: .online, apiFetchedAt: capturedAt,
                               processes: active.processes, processMemoryStatus: .measured),
            AIInstanceSnapshot(id: endpoints[1].id, name: endpoints[1].name, runtime: .llamaCpp,
                               status: .stale, models: [historical],
                               memoryBytes: historical.memoryBytes,
                               lastEventAt: historical.lastObservedAt,
                               apiStatus: .unavailable, apiFetchedAt: historical.lastObservedAt,
                               processMemoryStatus: .unavailable),
        ], capturedAt: capturedAt)
    }

    public static func aiPrefill(capturedAt: Date = referenceDate) -> AISnapshot {
        let snapshot = ai(capturedAt: capturedAt)
        var instances = snapshot.instances
        var instance = instances[1]
        instance.status = .monitoring
        instance.apiStatus = .online
        instance.lastEventAt = capturedAt
        instance.apiFetchedAt = capturedAt
        var model = instance.models[0]
        model.contextWindowTotal = 262_144
        model.contextWindowUsed = 90_527
        model.contextTokensPerSecond = 127.98
        model.isActive = true
        model.isLoaded = true
        model.lastObservedAt = capturedAt
        model.memoryBytes = 5_792_333_824
        model.processes = [AIProcessMemory(pid: 4202, residentBytes: 5_792_333_824,
                                          physicalFootprintBytes: 6_845_104_128)]
        model.prefillProgress = [AIPrefillProgress(
            slotID: 0, taskID: 1956, fraction: 0.97, processedTokens: 90_527,
            elapsed: 707.35, tokensPerSecond: 127.98, updatedAt: capturedAt)]
        instance.models = [model]
        instance.memoryBytes = model.memoryBytes
        instance.processes = model.processes
        instance.processMemoryStatus = .measured
        instances[1] = instance
        return AISnapshot(overallRAMUsage: snapshot.overallRAMUsage, instances: instances,
                          capturedAt: capturedAt)
    }

    public static func aiSlots(capturedAt: Date = referenceDate) -> AISnapshot {
        var instance = aiPrefill(capturedAt: capturedAt).instances[1]
        var model = instance.models[0]
        model.tokensPerSecond = 18.47
        model.contextWindowUsed = 98_719
        model.slots = [
            AISlotInfo(id: 0, taskID: 1956, phase: .prefill, contextWindowTotal: 131_072,
                       contextWindowUsed: 90_527, contextTokensPerSecond: 127.98,
                       prefillProgress: model.prefillProgress.first, updatedAt: capturedAt,
                       prefillMeasuredAt: capturedAt),
            AISlotInfo(id: 1, taskID: 2021, phase: .answer, contextWindowTotal: 131_072,
                       contextWindowUsed: 8192, generatedTokens: 885, tokensPerSecond: 18.47,
                       contextTokensPerSecond: 246.12, updatedAt: capturedAt,
                       generationMeasuredAt: capturedAt, prefillMeasuredAt: capturedAt),
            AISlotInfo(id: 2, taskID: 1840, phase: .idle, contextWindowTotal: 131_072,
                       updatedAt: capturedAt),
        ]
        instance.models = [model]
        return AISnapshot(instances: [instance], capturedAt: capturedAt)
    }

    public static func aiSlotHistory(capturedAt: Date = referenceDate) -> AIHistory {
        let instance = aiSlots(capturedAt: capturedAt).instances[0]
        let model = instance.models[0]
        var observations: [AIObservation] = []
        for minute in 0..<60 where minute % 17 != 0 {
            let date = capturedAt.addingTimeInterval(Double(minute - 59) * 60 - 5)
            observations.append(AIObservation(id: "slot-answer-\(minute)", instanceID: instance.id,
                kind: .generation, date: date, value: 18 + sin(Double(minute) / 4) * 4,
                modelID: model.historyID, slotID: 1, taskID: 2021))
            observations.append(AIObservation(id: "slot-prefill-\(minute)", instanceID: instance.id,
                kind: .prefill, date: date, value: 135 + sin(Double(minute) / 5) * 12,
                modelID: model.historyID, slotID: 0, taskID: 1956))
            observations.append(AIObservation(id: "slot-memory-\(minute)", instanceID: instance.id,
                kind: .memory, date: date, value: 5_792_333_824 + sin(Double(minute) / 10) * 100_000_000))
        }
        var history = AIHistory()
        history.append(AISnapshot(instances: [AIInstanceSnapshot(id: instance.id, name: instance.name,
                                                               observations: observations)], capturedAt: capturedAt))
        return history
    }

    /// Actual observation events, including gaps, rather than cached screen values.
    public static func aiHistory(capturedAt: Date = referenceDate) -> AIHistory {
        var history = AIHistory()
        let endpoints = aiEndpoints
        let instances = endpoints.enumerated().map { index, endpoint -> AIInstanceSnapshot in
            var observations: [AIObservation] = []
            for minute in 0..<120 {
                if index == 1 && minute > 80 { continue }
                if minute % 17 == 0 { continue }
                let date = capturedAt.addingTimeInterval(Double(minute - 119) * 60 - 10)
                let duration = 4.0 + Double(minute % 7)
                let rate = (index == 0 ? 43.0 : 31.0) + sin(Double(minute) * 0.22) * 9
                let tokens = Int(rate * duration)
                observations.append(AIObservation(
                    id: "fixture-generation-\(minute)", instanceID: endpoint.id, kind: .generation,
                    date: date, value: Double(tokens) / duration, tokenCount: tokens,
                    duration: duration))
                let memory = (index == 0 ? 6_845_104_128.0 : 5_792_333_824.0)
                    + sin(Double(minute) * 0.08) * 260_000_000
                observations.append(AIObservation(
                    id: "fixture-memory-\(minute)", instanceID: endpoint.id, kind: .memory,
                    date: date, value: memory))
            }
            return AIInstanceSnapshot(id: endpoint.id, name: endpoint.name, runtime: endpoint.runtime,
                                      observations: observations)
        }
        history.append(AISnapshot(instances: instances, capturedAt: capturedAt))
        return history
    }
}
