import Foundation
import Testing
@testable import AirStatKit

@Suite("Prefill progress across API and log sources")
struct AIPrefillMergeTests {
    private let id = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func logs(status: AIInstanceStatus = .monitoring) -> AIInstanceSnapshot {
        let progress = AIPrefillProgress(slotID: 0, taskID: 12, fraction: 0.97,
            processedTokens: 90_527, elapsed: 707.35, tokensPerSecond: 127.98, updatedAt: date)
        let model = AIModelInfo(endpointID: id, name: "Qwen", contextWindowTotal: 262_144,
            contextWindowUsed: 90_527, isActive: true, prefillProgress: [progress])
        return AIInstanceSnapshot(id: id, name: "Local", status: status, models: [model])
    }

    private func api(active: Bool? = nil, fetchedAt: Date) -> AIAPIReading {
        let model = AIModelInfo(endpointID: id, name: "served", isActive: active, isLoaded: true)
        return AIAPIReading(models: [model], aliases: ["served": ["Qwen"]], fetchedAt: fetchedAt)
    }

    @Test("fresh API inventory preserves matching log prefill percentage and token count")
    func matchingInventory() throws {
        let merged = AIMerge.snapshot(logs: logs(), api: api(fetchedAt: date), apiStatus: .online,
                                      now: date.addingTimeInterval(1))
        let model = try #require(merged.models.first)
        let progress = try #require(model.prefillProgress.first)
        #expect(progress.fraction == 0.97)
        #expect(progress.processedTokens == 90_527)
        #expect(progress.elapsed == 707.35)
        #expect(progress.tokensPerSecond == 127.98)
        #expect(model.contextWindowTotal == 262_144)
        #expect(model.isActive == true)
    }

    @Test("an older idle response cannot hide a newer context-reading event")
    func olderIdleReading() {
        let merged = AIMerge.snapshot(logs: logs(), api: api(active: false, fetchedAt: date.addingTimeInterval(-1)),
                                      apiStatus: .online, now: date.addingTimeInterval(1))
        #expect(merged.models.first?.prefillProgress.count == 1)
        #expect(merged.models.first?.isActive == true)
    }

    @Test("a newer idle API response ends an earlier prefill progress display")
    func newerIdleReading() {
        let merged = AIMerge.snapshot(logs: logs(), api: api(active: false, fetchedAt: date.addingTimeInterval(2)),
                                      apiStatus: .online, now: date.addingTimeInterval(3))
        #expect(merged.models.first?.prefillProgress.isEmpty == true)
        #expect(merged.models.first?.isActive == false)
    }

    @Test("API failure keeps fresh log progress but unavailable logs cannot claim current progress")
    func fallback() {
        let fresh = AIMerge.snapshot(logs: logs(), api: nil, apiStatus: .unavailable, now: date)
        #expect(fresh.models.first?.prefillProgress.count == 1)
        for status in [AIInstanceStatus.stale, .missingLogs, .unreadable] {
            let missing = AIMerge.snapshot(logs: logs(status: status), api: nil,
                                          apiStatus: .unavailable, now: date)
            #expect(missing.models.first?.prefillProgress.isEmpty == true)
        }
    }

    @Test("unloaded API inventory and expired progress do not leave a stuck progress bar")
    func expiryAndUnload() {
        let now = date.addingTimeInterval(61)
        let stale = AIMerge.snapshot(logs: logs(), api: api(fetchedAt: now), apiStatus: .online, now: now)
        #expect(stale.models.first?.prefillProgress.isEmpty == true)
        let unloaded = AIMerge.snapshot(logs: logs(), api: AIAPIReading(fetchedAt: date),
                                        apiStatus: .online, now: date)
        #expect(unloaded.models.isEmpty)
    }

    @Test("incremental log reading publishes progress and temporarily increases sampling cadence")
    func incrementalCollection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("stdout.log")
        var now = date
        let timestamp = ISO8601DateFormatter().string(from: now)
        let initial = "time=\(timestamp) print_info: general.name = Test\ntime=\(timestamp) llama_context: n_ctx = 262144\ntime=\(timestamp) slot print_timing: id 0 | task 1956 | prompt processing, n_tokens = 90527, progress = 0.97, t = 707.35 s / 127.98 tokens per second\n"
        try Data(initial.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let endpoint = AIEndpoint(runtime: .llamaCpp, logDirectory: directory.path, usesAPI: false)
        let collector = AICollector(now: { now })
        defer { collector.stop() }
        collector.setEndpoints([endpoint])
        let context = SampleContext(elapsed: 2, isFirstSample: false, activity: .panel)
        #expect(collector.preferredInterval == 5)
        let first = try #require(collector.collect(context: context).value)
        #expect(first.models.first?.prefillProgress.first?.fraction == 0.97)
        #expect(collector.preferredInterval == 1)
        now = now.addingTimeInterval(2)
        let completedAt = ISO8601DateFormatter().string(from: now)
        let completed = "time=\(completedAt) slot print_timing: id 0 | task 1956 | prompt eval time = 710000 ms / 93000 tokens (7.63 ms per token, 130.99 tokens per second)\n"
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(completed.utf8))
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let next = try #require(collector.collect(context: context).value)
        #expect(next.models.first?.prefillProgress.isEmpty == true)
        #expect(collector.preferredInterval == 5)
    }
}
