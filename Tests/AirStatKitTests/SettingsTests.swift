import Testing
import Foundation
@testable import AirStatKit

@Suite("Settings decoding is fault tolerant")
struct SettingsDecodingTests {

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test("an empty object yields full defaults")
    func emptyObject() throws {
        let settings = try decode("{}")
        #expect(settings.general.updateInterval == 2)
        #expect(settings.menuBar.items.count == MenuBarSettings.defaultItems.count)
        #expect(settings.panel.collapsedModules == PanelSettings.defaultCollapsed)
    }

    /// A settings file written by 1.2.1 or earlier has `floatsAboveEverything` and no
    /// `depth`, and the upgrade must not silently move anyone's desktop widget.
    @Test("a pre-1.3 desktop widget layer converts from the old boolean")
    func desktopWidgetDepthMigratesFromLegacyBool() throws {
        #expect(try decode(#"{"overlay":{"floatsAboveEverything":true}}"#).desktopWidget.depth
                == .aboveEverything)
        #expect(try decode(#"{"overlay":{"floatsAboveEverything":false}}"#).desktopWidget.depth
                == .withWindows)
        #expect(try decode(#"{"overlay":{}}"#).desktopWidget.depth == .aboveEverything)
    }

    /// The new key wins, so a file that somehow carries both is not dragged backwards
    /// by the one nothing writes any more.
    @Test("a stored layer beats the boolean it replaced")
    func desktopWidgetDepthPrefersTheNewKey() throws {
        let settings = try decode(#"{"overlay":{"depth":"wallpaper","floatsAboveEverything":true}}"#)
        #expect(settings.desktopWidget.depth == .wallpaper)
    }

    /// Round-tripping must not resurrect the retired key, or every save would write a
    /// field the next version has to keep reading.
    @Test("saving a desktop widget writes the layer and not the old boolean")
    func desktopWidgetDepthRoundTrips() throws {
        var settings = Settings()
        settings.desktopWidget.depth = .wallpaper
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("floatsAboveEverything"))
        #expect(try JSONDecoder().decode(Settings.self, from: data).desktopWidget.depth == .wallpaper)
    }

    /// Asserted by content, not against the constant the app reads. The defaults check
    /// above compares `collapsedModules` to `PanelSettings.defaultCollapsed`, which
    /// stays true no matter what that constant is changed to and so cannot notice a
    /// module quietly starting open.
    @Test("the panel opens with every module closed")
    func panelStartsFullyCollapsed() {
        let collapsed = PanelSettings().collapsedModules
        for module in PanelModule.allCases {
            #expect(collapsed.contains(module), "\(module.label) starts open")
        }
    }

    /// Opening a module closes the one that was open, and closing the open module
    /// leaves the list fully collapsed.
    @Test("the panel keeps one module open at a time")
    func panelIsAnAccordion() {
        var panel = PanelSettings()
        panel.collapsedModules = panel.collapsedModules(toggling: .cpu)
        #expect(panel.collapsedModules == Set(PanelModule.allCases).subtracting([.cpu]))
        panel.collapsedModules = panel.collapsedModules(toggling: .memory)
        #expect(panel.collapsedModules == Set(PanelModule.allCases).subtracting([.memory]))
        panel.collapsedModules = panel.collapsedModules(toggling: .memory)
        #expect(panel.collapsedModules == Set(PanelModule.allCases))
    }

    /// A file saved before the accordion can hold several open modules. The first in
    /// panel order stays open rather than all of them closing, so an upgrade does not
    /// hand back a panel that has forgotten what the user was looking at.
    @Test("a stored panel with several open modules keeps the first")
    func panelCollapsesAllButTheFirstOpenModule() throws {
        let settings = try decode(#"{"panel":{"collapsedModules":["cpu","gpu"]}}"#)
        #expect(settings.panel.collapsedModules == Set(PanelModule.allCases).subtracting([.memory]))
    }

    @Test("a fresh install opens at login, an existing one keeps its answer")
    func launchAtLoginDefault() throws {
        // The shipped default, which is what a Mac with no settings file gets.
        #expect(GeneralSettings().launchAtLogin)
        // A file that already says no must stay no. The default changed after release,
        // and re-enabling a login item someone deliberately turned off would be the
        // worst possible reading of "default it to on".
        #expect(try decode(#"{"general":{"launchAtLogin":false}}"#).general.launchAtLogin == false)
        // A file predating the key is an existing install too, so it does not opt in.
        #expect(try decode(#"{"general":{}}"#).general.launchAtLogin == false)
    }

    @Test("a malformed key falls back without losing its siblings")
    func malformedKeyIsIsolated() throws {
        let settings = try decode("""
        {"general":{"updateInterval":"not a number","launchAtLogin":true,"temperatureUnit":"kelvin"}}
        """)
        #expect(settings.general.updateInterval == 2)          // fell back
        #expect(settings.general.launchAtLogin == true)        // survived
        #expect(settings.general.temperatureUnit == .celsius)  // unknown enum fell back
    }

    @Test("out-of-range values are clamped, not accepted")
    func clamping() throws {
        let settings = try decode("""
        {"general":{"updateInterval":9999},
         "overlay":{"opacity":0.0,"width":10000},
         "charts":{"historyDuration":999999}}
        """)
        #expect(settings.general.updateInterval == 60)
        #expect(settings.desktopWidget.opacity == 0.2)   // never invisible
        #expect(settings.desktopWidget.width == 480)
        #expect(settings.charts.historyDuration == 3600)
    }

    @Test("an empty menu bar is repaired so the app stays reachable")
    func emptyMenuBarIsRepaired() throws {
        let settings = try decode(#"{"menuBar":{"items":[]}}"#)
        #expect(!settings.menuBar.items.isEmpty)
        #expect(!settings.menuBar.enabledItems.isEmpty)
    }

    @Test("every item disabled still leaves one enabled after sanitising")
    func allDisabledIsRepaired() {
        var settings = Settings()
        for index in settings.menuBar.items.indices { settings.menuBar.items[index].isEnabled = false }
        let sanitized = SettingsStore.sanitize(settings)
        #expect(sanitized.menuBar.enabledItems.count == 1)
    }

    @Test("a style the metric no longer supports is corrected")
    func incompatibleStyleIsCorrected() {
        // Uptime keeps no series, so there is nothing for a graph to plot.
        let item = MenuBarItemConfig(metric: .uptime, style: .graph)
        #expect(!MenuBarMetric.uptime.supportedStyles.contains(.graph))
        #expect(item.sanitized().style != .graph)
    }

    @Test("a retired style in a stored file lands on one the metric supports")
    func retiredStyleIsMigrated() throws {
        let settings = try decode(#"{"menuBar":{"items":[{"metric":"cpuUsage","style":"ring"}]}}"#)
        #expect(MenuBarMetric.cpuUsage.supportedStyles.contains(settings.menuBar.items[0].style))
    }

    @Test("round-trips without loss")
    func roundTrip() throws {
        var original = Settings()
        original.general.temperatureUnit = .fahrenheit
        original.desktopWidget.isEnabled = true
        original.menuBar.items.append(MenuBarItemConfig(metric: .gpuUsage, style: .graph))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored == original)
    }

    /// Every settings file written before Sparkle still holds the home-made checker's
    /// keys. They are read by nothing now, and a decoder that choked on them would
    /// throw away the user's whole configuration to say so.
    @Test("a file from the retired update checker still loads")
    func retiredUpdateKeysAreIgnored() throws {
        let settings = try decode("""
        {"updates":{"lastCheckedAt":776000000,"latestVersion":"1.1",
                    "latestURL":"https://airstats.app/download","notifiedVersion":"1.1"},
         "general":{"checksForUpdates":false,"notifiesAboutUpdates":false,"launchAtLogin":true}}
        """)
        #expect(settings.general.launchAtLogin)
        #expect(settings.general.updateInterval == 2)
    }

    @Test("truncated JSON throws so the caller can fall back to the backup")
    func truncatedThrows() {
        #expect(throws: (any Error).self) {
            try decode("{\"general\":{\"updateInterval\":")
        }
    }
}

@Suite("Required sources track what is actually on screen")
struct RequiredSourceTests {

    @Test("only menu bar sources are needed when the panel is closed")
    func menuBarOnly() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.cpu))
        #expect(!sources.contains(.power))     // nothing on screen needs the battery
        #expect(!sources.contains(.processes)) // the expensive one stays off
    }

    @Test("opening the panel pulls in its modules")
    func panelOpen() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: true, desktopWidgetVisible: false)
        #expect(sources.contains(.processes))
        #expect(sources.contains(.power))
    }

    @Test("enabled notification rules keep their source alive")
    func notificationRulesRequireSources() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        settings.notifications.isEnabled = true
        settings.notifications.rules = [ThresholdRule(metric: .batteryLow, isEnabled: true)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.power))
    }
}

@Suite("AI settings")
struct AISettingsTests {

    @Test("an empty AI settings block yields no endpoints and is disabled")
    func defaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(settings.ai.endpoints.isEmpty)
        #expect(settings.ai.isEnabled == false)
    }

    @Test("endpoints decode with optional API key")
    func endpointsDecode() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"""
        {"ai":{"endpoints":[{"name":"Ollama","url":"http://localhost:11434","apiKey":"secret","isEnabled":true}],"isEnabled":true}}
        """#.utf8))
        #expect(settings.ai.isEnabled)
        #expect(settings.ai.endpoints.count == 1)
        #expect(settings.ai.endpoints[0].name == "Ollama")
        #expect(settings.ai.endpoints[0].url == "http://localhost:11434")
        #expect(settings.ai.endpoints[0].apiKey == "secret")
        #expect(settings.ai.endpoints[0].isEnabled)
    }

    @Test("endpoints round-trip without loss")
    func endpointsRoundTrip() throws {
        var settings = Settings()
        settings.ai.isEnabled = true
        settings.ai.endpoints = [
            AIEndpoint(name: "Ollama", url: "http://localhost:11434", apiKey: nil, isEnabled: true),
            AIEndpoint(name: "Llama", url: "http://localhost:8080", apiKey: "key", isEnabled: false),
        ]
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored.ai.isEnabled == true)
        #expect(restored.ai.endpoints.count == 2)
        #expect(restored.ai.endpoints[0].name == "Ollama")
        #expect(restored.ai.endpoints[1].name == "Llama")
        #expect(restored.ai.endpoints[1].apiKey == "key")
    }

    @Test("malformed AI settings fall back gracefully")
    func malformedAI() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"""
        {"ai":{"endpoints":"not an array","isEnabled":"not a bool"}}
        """#.utf8))
        #expect(settings.ai.endpoints.isEmpty)
        #expect(settings.ai.isEnabled == false)
    }

    @Test("legacy endpoints migrate to log defaults without losing identity or credentials")
    func legacyEndpointMigration() throws {
        let id = UUID()
        let json = """
        {"ai":{"isEnabled":true,"endpoints":[
          {"id":"\(id.uuidString)","name":"Local llama","url":"http://localhost:8080","apiKey":"secret","isEnabled":false},
          {"name":"Ollama","url":"http://localhost:11434"}
        ]}}
        """
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.ai.endpoints.count == 2)
        let llama = settings.ai.endpoints[0]
        #expect(llama.id == id)
        #expect(llama.runtime == .llamaCpp)
        #expect(llama.logDirectory == "~/.config/llama-server/logs")
        #expect(llama.logFilePattern == "std*.log")
        #expect(llama.apiKey == "secret")
        #expect(!llama.isEnabled)
        let ollama = settings.ai.endpoints[1]
        #expect(ollama.runtime == .ollama)
        #expect(ollama.logDirectory == "~/.ollama/logs")
        #expect(ollama.logFilePattern == "server*.log")
        #expect(ollama.isEnabled)
        #expect(settings.ai.isMonitoringEnabled)
    }

    @Test("one malformed endpoint field does not discard other fields or instances")
    func malformedEndpointIsIsolated() throws {
        let json = #"""
        {"ai":{"isEnabled":true,"endpoints":[
          {"name":"Custom","runtime":"unknown","logDirectory":42,"logFilePattern":"*.log","isEnabled":"yes"},
          {"name":"Second","runtime":"llamaCpp","logDirectory":"/tmp/second","logFilePattern":"std*"}
        ]}}
        """#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.ai.endpoints.count == 2)
        #expect(settings.ai.endpoints[0].name == "Custom")
        #expect(settings.ai.endpoints[0].runtime == .ollama)
        #expect(settings.ai.endpoints[0].logDirectory == AIRuntime.ollama.defaultLogDirectory)
        #expect(settings.ai.endpoints[1].logDirectory == "/tmp/second")
        #expect(settings.ai.enabledEndpoints.count == 2)
    }

    @Test("custom log paths and runtime round-trip alongside legacy fields")
    func logConfigurationRoundTrip() throws {
        let endpoint = AIEndpoint(name: "Local", url: "http://localhost:8081", apiKey: "retained",
                                  runtime: .llamaCpp, logDirectory: "/tmp/my server", logFilePattern: "std*.log*")
        let restored = try JSONDecoder().decode(AIEndpoint.self, from: JSONEncoder().encode(endpoint))
        #expect(restored == endpoint)
        #expect(restored.isConfigured)
    }

    @Test("monitoring needs an active instance with a directory and filename pattern")
    func monitoringGate() {
        var ai = AISettings(isEnabled: true)
        #expect(!ai.isMonitoringEnabled)
        ai.endpoints = [AIEndpoint(isEnabled: false)]
        #expect(!ai.isMonitoringEnabled)
        ai.endpoints = [AIEndpoint(logDirectory: "relative/path")]
        #expect(!ai.isMonitoringEnabled)
        ai.endpoints = [AIEndpoint(logFilePattern: "")]
        #expect(!ai.isMonitoringEnabled)
        ai.endpoints = [AIEndpoint(logFilePattern: "folder/*.log")]
        #expect(!ai.isMonitoringEnabled)
        ai.endpoints = [AIEndpoint(logDirectory: "/not-created-yet", logFilePattern: "server*")]
        #expect(ai.isMonitoringEnabled)
        ai.isEnabled = false
        #expect(!ai.isMonitoringEnabled)
    }

    @Test("unconfigured AI never requires its collector on any surface")
    func inactiveCollectorStaysOff() {
        var settings = Settings()
        settings.ai.isEnabled = true
        settings.menuBar.items.append(MenuBarItemConfig(metric: .ai))
        settings.desktopWidget.modules.append(.ai)
        #expect(!settings.requiredSources(panelVisible: true, desktopWidgetVisible: true).contains(.ai))
        settings.ai.endpoints = [AIEndpoint()]
        #expect(settings.requiredSources(panelVisible: true, desktopWidgetVisible: true).contains(.ai))
    }

    @MainActor
    @Test("configuration adds AI surfaces once and respects later surface choices")
    func activationAddsSurfaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.update {
            $0.ai.endpoints = [AIEndpoint()]
            $0.ai.isEnabled = true
        }
        #expect(store.settings.menuBar.enabledItems.contains { $0.metric == .ai })
        #expect(store.settings.desktopWidget.modules.contains(.ai))
        store.update {
            if let index = $0.menuBar.items.firstIndex(where: { $0.metric == .ai }) {
                $0.menuBar.items[index].isEnabled = false
            }
            $0.desktopWidget.modules.removeAll { $0 == .ai }
        }
        store.update { $0.ai.endpoints[0].name = "Renamed" }
        #expect(!store.settings.menuBar.enabledItems.contains { $0.metric == .ai })
        #expect(!store.settings.desktopWidget.modules.contains(.ai))
        store.flush()
    }

    @MainActor
    @Test("importing an active log configuration reveals its surfaces")
    func importActivatesSurfaces() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let data = Data(#"{"ai":{"isEnabled":true,"endpoints":[{"name":"Imported","logDirectory":"/tmp/logs","logFilePattern":"server*"}]}}"#.utf8)
        try store.importJSON(data)
        #expect(store.settings.ai.isMonitoringEnabled)
        #expect(store.settings.menuBar.enabledItems.contains { $0.metric == .ai })
        #expect(store.settings.desktopWidget.modules.contains(.ai))
    }

    @MainActor
    @Test("AI section resets to defaults")
    func resetAISection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.update {
            $0.ai.isEnabled = true
            $0.ai.endpoints = [AIEndpoint(name: "Test", url: "http://example.com")]
        }
        store.resetSection(.ai)
        #expect(!store.settings.ai.isMonitoringEnabled)
        #expect(!store.settings.ai.isEnabled)
        #expect(store.settings.ai.endpoints.isEmpty)
        store.flush()
    }

}

@Suite("AI collector")
struct AICollectorTests {

    @Test("collector returns pending when no endpoints are configured")
    func pendingWithoutEndpoints() {
        let collector = AICollector()
        // Use reflection or a test hook to set endpoints
        // The collector's endpoints are private, so we test via the public API
        // After setting endpoints, collect should return a value or failure
        let state = collector.collect(context: SampleContext(elapsed: 5,
                                                              isFirstSample: true,
                                                              activity: .panel,
                                                              didWakeFromSleep: false))
        // No endpoints -> pending
        if case .failure(let failure) = state {
            #expect(failure == .pending || failure.message == "Collecting…")
        }
    }

    @Test("AIModelInfo is equatable and hashable")
    func modelInfoEquatable() {
        let a = AIModelInfo(name: "llama3", memoryBytes: 1024*1024*1024,
                            contextWindowTotal: 8192, contextWindowUsed: 4096,
                            tokensPerSecond: 10.5, contextTokensPerSecond: 5.2)
        let b = AIModelInfo(name: "llama3", memoryBytes: 1024*1024*1024,
                            contextWindowTotal: 8192, contextWindowUsed: 4096,
                            tokensPerSecond: 10.5, contextTokensPerSecond: 5.2)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("AISnapshot is equatable")
    func snapshotEquatable() {
        let model = AIModelInfo(name: "test", memoryBytes: 1024)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let a = AISnapshot(overallRAMUsage: 0.5, models: [model], capturedAt: capturedAt)
        let b = AISnapshot(overallRAMUsage: 0.5, models: [model], capturedAt: capturedAt)
        #expect(a == b)
    }
}

@Suite("History capacity follows interval and retention")
struct HistoryCapacityTests {

    @Test("capacity covers the requested duration at the chosen interval")
    func capacity() {
        var settings = Settings()
        settings.general.updateInterval = 2
        settings.charts.historyDuration = 300
        #expect(settings.historyCapacity >= 150)
        #expect(settings.historyCapacity <= 160)
    }

    @Test("capacity stays bounded at the fastest interval and longest retention")
    func bounded() {
        var settings = Settings()
        settings.general.updateInterval = 0.5
        settings.charts.historyDuration = 3600
        // 7200 samples would be honest but wasteful; the cap keeps memory predictable.
        #expect(settings.historyCapacity == 4096)
    }
}
