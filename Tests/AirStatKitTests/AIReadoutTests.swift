import Foundation
import Testing
@testable import AirStatKit
@testable import AirStatUI

@Suite("AI surfaces preserve instance identity and measurement uncertainty")
struct AIReadoutTests {
    private let formatter = MetricFormatter(settings: GeneralSettings())

    @Test("instance warnings describe failures without treating disabled APIs or idle models as errors")
    func instanceWarnings() {
        var instance = SnapshotFixtures.ai().instances[0]
        #expect(AIReadoutSummary.issues(instance) == nil)
        instance.apiStatus = .disabled
        #expect(AIReadoutSummary.issues(instance) == nil)
        instance.apiStatus = .unavailable
        instance.status = .missingLogs
        instance.processMemoryStatus = .partial
        let details = AIReadoutSummary.issues(instance) ?? ""
        #expect(details.contains(AIAPIStatus.unavailable.message))
        #expect(details.contains(AIInstanceStatus.missingLogs.message))
        #expect(details.contains(AIProcessMemoryStatus.partial.message))
        instance.apiStatus = .online
        instance.status = .monitoring
        instance.models = []
        instance.processMemoryStatus = .noWorker
        #expect(AIReadoutSummary.issues(instance) == nil)
    }

    @Test("process memory tooltips include PID, RSS and physical footprint")
    func processMemoryTooltip() {
        let processes = [AIProcessMemory(pid: 42, residentBytes: 1024, physicalFootprintBytes: 2048)]
        let tooltip = AIReadoutSummary.memoryDetails(processes, formatter: formatter)
        #expect(tooltip.contains("PID 42"))
        #expect(tooltip.contains("RSS \(formatter.memory(UInt64(1024)))"))
        #expect(tooltip.contains("physical footprint \(formatter.memory(UInt64(2048)))"))
    }

    @Test("historical or unknown activity is never counted as active")
    func activityRequiresCurrentEvidence() {
        var snapshot = SnapshotFixtures.ai()
        #expect(AIReadoutSummary.value(snapshot) == "1 generating")
        snapshot.instances[0].status = .stale
        snapshot.instances[0].apiStatus = .stale
        #expect(AIReadoutSummary.value(snapshot) == "2 observed")
        #expect(AIReadoutSummary.activity(snapshot.instances[0].models[0], status: .stale)
                == "Activity unknown")
        #expect(AIReadoutSummary.activity(AIModelInfo(name: "unknown")) == "Activity unknown")
    }

    @Test("missing context and rates remain unavailable, including partial context")
    func missingMeasurementsRemainUnknown() {
        var model = AIModelInfo(name: "partial", contextWindowTotal: 8192)
        #expect(AIReadoutSummary.context(model, formatter: formatter).hasPrefix("— / "))
        #expect(AIReadoutSummary.contextFraction(model) == nil)
        #expect(AIReadoutSummary.rate(nil, formatter: formatter) == MetricFormatter.unavailable)
        #expect(AIReadoutSummary.rate(.nan, formatter: formatter) == MetricFormatter.unavailable)
        model.contextWindowUsed = 2048
        #expect(AIReadoutSummary.contextFraction(model) == 0.25)
        #expect(AIReadoutSummary.rate(0, formatter: formatter)
                == "\(formatter.fixed(0, decimals: 1)) tok/s")
    }

    @Test("the menu bar describes both instances without borrowing a system chart")
    func menuPreservesInstances() throws {
        var snapshot = SnapshotFixtures.nominal
        snapshot.ai = .value(SnapshotFixtures.ai())
        var settings = Settings()
        settings.ai = AISettings(endpoints: SnapshotFixtures.aiEndpoints, isEnabled: true)
        settings.menuBar.items = [MenuBarItemConfig(metric: .ai, style: .text)]
        let model = MenuBarRenderModel(snapshot: snapshot, history: SnapshotFixtures.history(),
                                       settings: settings, isStale: false)
        let item = try #require(model.items.first)
        #expect(item.primary.valueText == "1 generating")
        #expect(item.primary.series.isEmpty)
        #expect(item.accessibilityLabel.contains("Ollama · local"))
        #expect(item.accessibilityLabel.contains("llama.cpp · research"))
        #expect(item.accessibilityLabel.contains("Activity unknown"))
        #expect(snapshot.ai.value?.instances[0].models[0].id
                != snapshot.ai.value?.instances[1].models[0].id)
    }

    @Test("loaded inventory and live request activity are independent")
    func loadedDoesNotImplyGenerating() {
        var snapshot = SnapshotFixtures.ai()
        snapshot.instances[0].status = .missingLogs
        snapshot.instances[0].models[0].isActive = nil
        #expect(AIReadoutSummary.value(snapshot) == "1 loaded")
        #expect(AIReadoutSummary.loaded(snapshot.instances[0].models[0], apiStatus: .online) == "Yes")
        #expect(AIReadoutSummary.activity(snapshot.instances[0].models[0], status: .missingLogs,
                                          apiStatus: .online) == "Activity unknown")
        snapshot.instances[0].models[0].isActive = true
        #expect(AIReadoutSummary.value(snapshot) == "1 generating")
        #expect(AIReadoutSummary.activity(snapshot.instances[0].models[0], status: .missingLogs,
                                          apiStatus: .online) == "Generating")
        snapshot.instances[0].apiStatus = .unavailable
        #expect(AIReadoutSummary.value(snapshot) == "2 observed")
        #expect(AIReadoutSummary.loaded(snapshot.instances[0].models[0], apiStatus: .unavailable)
                == MetricFormatter.unavailable)
    }

    @Test("prefill progress uses the reported fraction independently of context capacity")
    func prefillIsNotContextUtilization() throws {
        var snapshot = SnapshotFixtures.aiPrefill()
        let instance = snapshot.instances[1]
        var model = instance.models[0]
        let progress = try #require(model.prefillProgress.first)
        #expect(AIReadoutSummary.value(snapshot) == "1 prefill · 1 answer")
        #expect(AIReadoutSummary.activity(model, status: instance.status, apiStatus: instance.apiStatus,
                                          now: snapshot.capturedAt) == "Reading context")
        #expect(AIReadoutSummary.prefillPercent(progress, formatter: formatter) == "97%")
        #expect(AIReadoutSummary.contextFraction(model) != progress.fraction)
        model.contextWindowUsed = nil
        model.contextWindowTotal = nil
        #expect(AIReadoutSummary.contextFraction(model) == nil)
        #expect(AIReadoutSummary.prefill(model, status: .monitoring, now: snapshot.capturedAt).first == progress)
        let summary = AIReadoutSummary.prefillSummary(progress, formatter: formatter)
        #expect(summary.contains("\(formatter.count(90_527)) tokens processed"))
        #expect(summary.contains("\(formatter.fixed(127.98, decimals: 2)) tok/s"))
        #expect(summary.contains("\(formatter.fixed(707.35, decimals: 2)) seconds"))
        #expect(!summary.contains(" / "))
        snapshot.instances[1].status = .stale
        snapshot.instances[1].apiStatus = .unavailable
        #expect(AIReadoutSummary.value(snapshot) == "1 generating")
        #expect(AIReadoutSummary.prefill(model, status: .stale, apiStatus: .unavailable,
                                         now: snapshot.capturedAt).isEmpty)
    }

    @Test("prefill progress remains independent per slot and expires without estimating a total")
    func prefillSlotsAndUnknownRates() {
        let now = SnapshotFixtures.referenceDate
        let first = AIPrefillProgress(slotID: 0, taskID: 10, fraction: 0.42,
                                      processedTokens: 420, updatedAt: now)
        let second = AIPrefillProgress(slotID: 1, taskID: 20, fraction: 0.97,
                                       processedTokens: 90_527, updatedAt: now)
        let model = AIModelInfo(name: "parallel", prefillProgress: [first, second])
        #expect(first.id != second.id)
        #expect(AIReadoutSummary.prefill(model, status: .monitoring, now: now).count == 2)
        #expect(AIReadoutSummary.prefill(model, status: .monitoring,
                                         now: now.addingTimeInterval(61)).isEmpty)
        let summary = AIReadoutSummary.prefillSummary(first, formatter: formatter)
        #expect(summary == "42% complete, \(formatter.count(420)) tokens processed")
        let instance = AIInstanceSnapshot(id: UUID(), name: "parallel", models: [model])
        #expect(AIReadoutSummary.value(AISnapshot(instances: [instance], capturedAt: now)) == "2 prefill")
    }

    @Test("disable and removal hide AI without changing saved item choices")
    func menuConfigurationFollowsMonitoring() {
        var settings = Settings()
        let cpu = MenuBarItemConfig(metric: .cpuUsage, style: .text)
        let ai = MenuBarItemConfig(metric: .ai, style: .text)
        settings.menuBar = MenuBarSettings(items: [cpu, ai], usesCombinedItem: false)
        settings.ai = AISettings(endpoints: SnapshotFixtures.aiEndpoints, isEnabled: true)
        #expect(MenuBarItemLayout(settings: settings) == .separate([cpu.id, ai.id]))

        settings.ai.isEnabled = false
        #expect(MenuBarItemLayout(settings: settings) == .separate([cpu.id]))
        #expect(settings.menuBar.items == [cpu, ai])
        settings.ai.isEnabled = true
        settings.ai.endpoints = []
        #expect(MenuBarItemLayout(settings: settings) == .separate([cpu.id]))
        let model = MenuBarRenderModel(snapshot: SnapshotFixtures.nominal,
                                       history: MetricHistory(), settings: settings, isStale: false)
        #expect(model.items.map(\.id) == [cpu.id])
        settings.menuBar.isVisible = false
        #expect(MenuBarItemLayout(settings: settings) == .hidden)
    }
}
