import Foundation
import Testing
@testable import AirStatKit
@testable import AirStatUI

@Suite("Independent AI slot measurements")
struct AISlotMonitoringTests {
    private let id = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ text: String, offset: TimeInterval = 0) -> AILogRecord {
        AILogRecord(id: UUID().uuidString, text: text, date: date.addingTimeInterval(offset), canChart: true)
    }

    private func snapshot(_ parser: AILogParser, offset: TimeInterval = 0) -> AIInstanceSnapshot {
        let now = date.addingTimeInterval(offset)
        return parser.snapshot(endpoint: AIEndpoint(id: id), read: AILogRead(modifiedAt: now), now: now)
    }

    private func concurrent() -> AILogParser {
        var parser = AILogParser(instanceID: id)
        parser.consume(record("[10] srv load_model: loading model '/models/Alpha.gguf'"))
        parser.consume(record("[10] srv load_model: initializing, n_slots = 2, n_ctx_slot = 8192"))
        parser.consume(record("[10] slot operator(): id 0 | task 101 | new prompt, n_ctx_slot = 8192, n_tokens = 4000"))
        parser.consume(record("[10] slot print_timing: id 0 | task 101 | prompt processing, n_tokens = 4000, progress = 0.50, t = 20 s / 200 tokens per second"))
        parser.consume(record("[10] slot operator(): id 1 | task 202 | new prompt, n_ctx_slot = 8192, n_tokens = 100"))
        parser.consume(record("[10] slot print_timing: id 1 | task 202 | n_gen = 120, tg = 30 t/s, tg_3s = 40 t/s"))
        return parser
    }

    @Test("parallel prefill and answer keep separate task, context, speed and history")
    func parallelMeasurements() throws {
        let parser = concurrent()
        let instance = snapshot(parser)
        let model = try #require(instance.models.first)
        #expect(model.slots.map(\.id) == [0, 1])
        #expect(model.slots.map(\.taskID) == [101, 202])
        #expect(model.slots.map(\.phase) == [.prefill, .answer])
        #expect(model.slots.map(\.contextWindowUsed) == [4000, 100])
        #expect(model.slots.map(\.contextWindowTotal) == [8192, 8192])
        #expect(model.slots[0].prefillProgress?.fraction == 0.5)
        #expect(model.slots[0].contextTokensPerSecond == 200)
        #expect(model.slots[0].tokensPerSecond == nil)
        #expect(model.slots[1].tokensPerSecond == 40)
        #expect(model.slots[1].contextTokensPerSecond == nil)
        #expect(model.slots[1].generatedTokens == 120)
        var history = AIHistory()
        history.append(AISnapshot(instances: [instance], capturedAt: date))
        for interval in AIHistoryInterval.allCases {
            #expect(history.prefillSeries(instanceID: id, modelID: model.historyID, slotID: 0,
                                          interval: interval).map(\.value) == [200])
            #expect(history.generationSeries(instanceID: id, modelID: model.historyID, slotID: 0,
                                             interval: interval).isEmpty)
            #expect(history.generationSeries(instanceID: id, modelID: model.historyID, slotID: 1,
                                             interval: interval).map(\.value) == [40])
            #expect(history.prefillSeries(instanceID: id, modelID: model.historyID, slotID: 1,
                                          interval: interval).isEmpty)
        }
        #expect(AIReadoutSummary.value(AISnapshot(instances: [instance], capturedAt: date)) == "1 prefill · 1 answer")
        #expect(AIReadoutSummary.activity(model, status: .monitoring, now: date) == "Prefill + Answer")
    }

    @Test("completion, slot reuse and delayed old summaries do not replace another task")
    func slotLifecycle() throws {
        var parser = concurrent()
        parser.beginPoll()
        parser.consume(record("[10] slot release: id 1 | task 202 | stop processing", offset: 1))
        var slots = try #require(snapshot(parser, offset: 1).models.first?.slots)
        #expect(slots.map(\.phase) == [.prefill, .idle])
        #expect(slots[0].prefillProgress?.taskID == 101)
        parser.consume(record("[10] slot operator(): id 1 | task 303 | new prompt, n_tokens = 50", offset: 2))
        parser.consume(record("[10] slot print_timing: id 1 | task 202 | eval time = 1000 ms / 30 tokens (33 ms per token, 30 tokens per second)", offset: 3))
        slots = try #require(snapshot(parser, offset: 3).models.first?.slots)
        #expect(slots[1].taskID == 303)
        #expect(slots[1].phase == .prefill)
        #expect(slots[1].tokensPerSecond == nil)
        #expect(slots[1].generatedTokens == nil)
        parser.consume(record("[10] slot print_timing: id 0 | task 101 | prompt eval time = 20000 ms / 4000 tokens (5 ms per token, 200 tokens per second)", offset: 4))
        slots = try #require(snapshot(parser, offset: 4).models.first?.slots)
        #expect(slots[0].phase == .answer)
        #expect(slots[0].prefillProgress == nil)
        #expect(slots[1].phase == .prefill)
        #expect(parser.observations.filter { $0.kind == .prefill }.isEmpty)
        let expired = try #require(snapshot(parser, offset: 70).models.first?.slots)
        #expect(expired.allSatisfy { $0.phase == .unknown && $0.tokensPerSecond == nil && $0.contextTokensPerSecond == nil })
        parser.consume(record("[10] slot print_timing: id 1 | task 303 | n_gen = 120, tg = 20 t/s, tg_3s = 25 t/s", offset: 70))
        let independent = try #require(snapshot(parser, offset: 70).models.first?.slots)
        #expect(independent[0].phase == .unknown)
        #expect(independent[0].contextTokensPerSecond == nil)
        #expect(independent[1].phase == .answer)
        #expect(independent[1].tokensPerSecond == 25)
    }

    @Test("matching API aliases retain log history identities and never mix equal slot numbers across models")
    func modelIdentityAndAPI() throws {
        var parser = concurrent()
        parser.consume(record("[20] srv load_model: loading model '/models/Beta.gguf'"))
        parser.consume(record("[20] slot print_timing: id 0 | task 101 | n_gen = 100, tg = 60 t/s, tg_3s = 70 t/s"))
        let logs = snapshot(parser)
        let reading = AIAPIReading(models: [AIModelInfo(endpointID: id, name: "public-alpha"),
                                            AIModelInfo(endpointID: id, name: "public-beta")],
            aliases: ["public-alpha": ["Alpha"], "public-beta": ["Beta"]], fetchedAt: date)
        let merged = AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online, now: date)
        let alpha = try #require(merged.models.first { $0.name == "public-alpha" })
        let beta = try #require(merged.models.first { $0.name == "public-beta" })
        #expect(alpha.historyID != beta.historyID)
        #expect(alpha.slots[0].prefillProgress?.fraction == 0.5)
        #expect(beta.slots[0].tokensPerSecond == 70)
        var history = AIHistory()
        history.append(AISnapshot(instances: [logs], capturedAt: date))
        history.append(AISnapshot(instances: [merged], capturedAt: date))
        #expect(history.generationSeries(instanceID: id, modelID: alpha.historyID, slotID: 0).isEmpty)
        #expect(history.generationSeries(instanceID: id, modelID: beta.historyID, slotID: 0).map(\.value) == [70])
        #expect(history.prefillSeries(instanceID: id, modelID: alpha.historyID, slotID: 0).map(\.value) == [200])
        parser.consume(record("[10] srv load_model: loading model '/models/Alpha.gguf'", offset: 0.5))
        let sameSource = try #require(snapshot(parser, offset: 0.5).models.first { $0.name == "Alpha" })
        #expect(sameSource.historyID == alpha.historyID)
        parser.consume(record("[10] srv load_model: loading model '/models/Gamma.gguf'", offset: 1))
        parser.consume(record("[10] slot print_timing: id 0 | task 101 | n_gen = 100, tg = 10 t/s, tg_3s = 12 t/s", offset: 1))
        let reloaded = try #require(snapshot(parser, offset: 1).models.first { $0.name == "Gamma" })
        #expect(reloaded.historyID != alpha.historyID)
    }

    @Test("fresh API task changes discard the previous task's log rates and progress")
    func apiTaskReplacement() throws {
        let logs = snapshot(concurrent())
        let live = AIModelInfo(endpointID: id, name: "Alpha", isActive: true, slots: [
            AISlotInfo(id: 0, taskID: 999, phase: .processing, contextWindowTotal: 8192,
                       contextWindowUsed: 500, updatedAt: date.addingTimeInterval(1)),
            AISlotInfo(id: 1, taskID: 202, phase: .idle, updatedAt: date.addingTimeInterval(1)),
        ])
        let reading = AIAPIReading(models: [live], fetchedAt: date.addingTimeInterval(1))
        let model = try #require(AIMerge.snapshot(logs: logs, api: reading, apiStatus: .online,
                                                 now: date.addingTimeInterval(1)).models.first)
        #expect(model.slots[0].taskID == 999)
        #expect(model.slots[0].prefillProgress == nil)
        #expect(model.slots[0].contextTokensPerSecond == nil)
        #expect(model.slots[0].contextWindowUsed == 500)
        #expect(model.slots[1].phase == .idle)
        #expect(model.prefillProgress.isEmpty)
    }

    @Test("selecting a slot filters readouts without attributing model memory or missing fields to another slot")
    func slotSelection() throws {
        var instance = snapshot(concurrent())
        instance.models[0].memoryBytes = 8192
        let model = instance.models[0]
        let selection = AISlotSelection(modelID: model.historyID, slotID: 0)
        #expect(AIReadoutSummary.slotSelection(selection, in: instance) == selection)
        let prefill = try #require(AIReadoutSummary.model(model, slotID: 0))
        let answer = try #require(AIReadoutSummary.model(model, slotID: 1))
        #expect(prefill.contextWindowUsed == 4000)
        #expect(prefill.contextTokensPerSecond == 200)
        #expect(prefill.tokensPerSecond == nil)
        #expect(answer.tokensPerSecond == 40)
        #expect(answer.contextTokensPerSecond == nil)
        #expect(answer.prefillProgress.isEmpty)
        #expect(answer.memoryBytes == model.memoryBytes)
        #expect(AIReadoutSummary.model(model, slotID: 8) == nil)
        instance.models.removeAll()
        #expect(AIReadoutSummary.slotSelection(selection, in: instance) == nil)
    }

    @Test("unlabelled measurements remain in All slots and scoped prefill timings stay weighted")
    func unlabelledAndWeightedHistory() throws {
        let model = UUID()
        let otherModel = UUID()
        let observations = [
            AIObservation(id: "a", instanceID: id, kind: .prefill, date: date,
                          value: 10, tokenCount: 100, duration: 10, modelID: model, slotID: 0),
            AIObservation(id: "b", instanceID: id, kind: .prefill, date: date,
                          value: 30, tokenCount: 30, duration: 1, modelID: model, slotID: 0),
            AIObservation(id: "other-model", instanceID: id, kind: .prefill, date: date,
                          value: 200, modelID: otherModel, slotID: 0),
            AIObservation(id: "unlabelled", instanceID: id, kind: .prefill, date: date, value: 900),
        ]
        var history = AIHistory()
        history.append(AISnapshot(instances: [AIInstanceSnapshot(id: id, name: "Local", observations: observations)],
                                  capturedAt: date))
        let point = try #require(history.prefillSeries(instanceID: id, modelID: model, slotID: 0).first)
        #expect(abs(point.value - 130.0 / 11.0) < 0.0001)
        #expect(history.prefillSeries(instanceID: id, modelID: model, slotID: 1).isEmpty)
        #expect(history.prefillSeries(instanceID: id, modelID: otherModel, slotID: 0).map(\.value) == [200])
        #expect(history.prefillSeries(instanceID: id).map(\.value) == [285])
    }
}
