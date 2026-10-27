import Foundation

/// Runs collectors outside the app and prints what they produced.
///
/// This exists so every metric can be verified against the system's own tools
/// (`top`, `vm_stat`, `netstat`, `ioreg`, `pmset`, `system_profiler`) without
/// launching the UI. It is the harness behind `AirStat --probe`.
public enum MetricProbe {

    public struct Options: Sendable {
        public var collectors: Set<CollectorID>
        public var repeatCount: Int
        public var interval: TimeInterval
        public var verbose: Bool
        /// Explicit API/log instances, or the runtime defaults when omitted.
        public var aiEndpoints: [AIEndpoint]

        public init(collectors: Set<CollectorID> = Set(CollectorID.allCases),
                    repeatCount: Int = 2,
                    interval: TimeInterval = 1,
                    verbose: Bool = false,
                    aiEndpoints: [AIEndpoint] = [AIEndpoint(name: "Ollama", runtime: .ollama),
                                                 AIEndpoint(name: "llama.cpp", runtime: .llamaCpp)]) {
            self.collectors = collectors
            self.repeatCount = max(1, repeatCount)
            self.interval = max(0.05, interval)
            self.verbose = verbose
            self.aiEndpoints = aiEndpoints
        }
    }

    /// Samples the requested collectors `repeatCount` times and returns a report.
    ///
    /// Rate-based collectors need at least two samples to produce anything, which is
    /// why the default is two: a single-shot probe of network or disk would honestly
    /// report "no rate yet" and look like a bug.
    public static func run(_ options: Options) -> String {
        var out = ""
        func emit(_ line: String = "") { out += line + "\n" }

        let cpu = CPUCollector()
        let memory = MemoryCollector()
        let gpu = GPUCollector()
        let network = NetworkCollector()
        let disk = DiskCollector()
        let power = PowerCollector()
        let thermal = ThermalCollector()
        let processes = ProcessCollector()
        let system = SystemInfoCollector()
        let ai = AICollector()
        ai.setEndpoints(options.aiEndpoints)

        var started: [CollectorID] = []
        func startIfNeeded<S: MetricSource>(_ source: S) {
            guard options.collectors.contains(source.identifier) else { return }
            source.start()
            started.append(source.identifier)
        }
        startIfNeeded(cpu); startIfNeeded(memory); startIfNeeded(gpu)
        startIfNeeded(network); startIfNeeded(disk); startIfNeeded(power)
        startIfNeeded(thermal); startIfNeeded(processes); startIfNeeded(system)
        startIfNeeded(ai)

        emit("AirStats metric probe")
        emit("collectors: \(options.collectors.map(\.rawValue).sorted().joined(separator: ", "))")
        emit("samples: \(options.repeatCount) every \(options.interval)s")
        emit(String(repeating: "─", count: 68))

        var lastInstant: [CollectorID: ContinuousClock.Instant] = [:]

        for iteration in 0..<options.repeatCount {
            if iteration > 0 { Thread.sleep(forTimeInterval: options.interval) }
            // Every iteration samples — rate collectors need the earlier ones to
            // establish a baseline — but only the last one prints unless asked.
            let isLast = iteration == options.repeatCount - 1

            func sample<S: MetricSource>(_ source: S, describe: (S.Output) -> [String]) {
                guard options.collectors.contains(source.identifier) else { return }
                let now = Monotonic.now
                let elapsed = lastInstant[source.identifier].map { Monotonic.seconds(since: $0) } ?? 0
                lastInstant[source.identifier] = now
                let context = SampleContext(elapsed: elapsed,
                                            isFirstSample: elapsed == 0,
                                            activity: .panel)
                let clock = Monotonic.now
                let state = source.collect(context: context)
                let cost = Monotonic.seconds(since: clock) * 1000

                guard isLast || options.verbose else { return }
                emit()
                emit("[\(source.identifier.rawValue)]  \(String(format: "%.2f", cost)) ms")
                switch state {
                case .value(let value):
                    for line in describe(value) { emit("  " + line) }
                case .failure(let failure):
                    emit("  UNAVAILABLE (\(failureKind(failure))): \(failure.message)")
                }
            }

            sample(system, describe: describeSystem)
            sample(cpu, describe: describeCPU)
            sample(memory, describe: describeMemory)
            sample(gpu, describe: describeGPU)
            sample(network, describe: describeNetwork)
            sample(disk, describe: describeDisk)
            sample(power, describe: describePower)
            sample(thermal, describe: describeThermal)
            sample(processes, describe: describeProcesses)
            sample(ai, describe: describeAI)
        }

        cpu.stop(); memory.stop(); gpu.stop(); network.stop(); disk.stop()
        power.stop(); thermal.stop(); processes.stop(); system.stop()
        ai.stop()

        emit()
        emit(String(repeating: "─", count: 68))
        return out
    }

    private static func failureKind(_ failure: MetricFailure) -> String {
        switch failure {
        case .unsupported: return "unsupported"
        case .failed: return "failed"
        case .denied: return "denied"
        case .pending: return "pending"
        }
    }

    // MARK: Describers

    private static let fmt = MetricFormatter()

    private static func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func describeSystem(_ s: SystemInfoSnapshot) -> [String] {
        [
            "model        \(s.modelName) (\(s.modelIdentifier))",
            "chip         \(s.chipName)  applesilicon=\(s.isAppleSilicon)",
            "cores        \(s.logicalCores) logical / \(s.physicalCores) physical  P=\(s.performanceCores) E=\(s.efficiencyCores)",
            "gpu cores    \(s.gpuCoreCount.map(String.init) ?? "—")",
            "memory       \(fmt.memory(s.totalMemoryBytes))",
            "os           \(s.osName) \(s.osVersion) (\(s.osBuild))",
            "host         \(s.computerName) / \(s.hostName)",
            "uptime       \(fmt.uptime(s.uptime))  booted \(s.bootTime)",
        ]
    }

    private static func describeCPU(_ s: CPUSnapshot) -> [String] {
        var lines = [
            "total        \(pct(s.total.busy))  user=\(pct(s.total.user)) sys=\(pct(s.total.system)) idle=\(pct(s.total.idle)) nice=\(pct(s.total.nice))",
            "loadavg      \(String(format: "%.2f %.2f %.2f", s.loadAverage.one, s.loadAverage.five, s.loadAverage.fifteen))",
            "procs        \(s.processCount) processes / \(s.threadCount) threads",
        ]
        if let p = s.performanceBusy { lines.append("P-cores      \(pct(p))") }
        if let e = s.efficiencyBusy { lines.append("E-cores      \(pct(e))") }
        let cores = s.perCore.enumerated().map { index, load in
            let kind = index < s.coreKinds.count ? s.coreKinds[index].shortLabel : ""
            return "\(index)\(kind):\(String(format: "%3.0f", load.busy * 100))"
        }
        lines.append("per-core     \(cores.joined(separator: " "))")
        return lines
    }

    private static func describeMemory(_ s: MemorySnapshot) -> [String] {
        [
            "total        \(fmt.memory(s.totalBytes))",
            "used         \(fmt.memory(s.usedBytes))  (\(pct(s.usedFraction)))",
            "  app        \(fmt.memory(s.appBytes))",
            "  wired      \(fmt.memory(s.wiredBytes))",
            "  compressed \(fmt.memory(s.compressedBytes))",
            "cached       \(fmt.memory(s.cachedBytes))",
            "free         \(fmt.memory(s.freeBytes))",
            "pressure     \(s.memoryPressure.label) (\(pct(s.pressureFraction)))",
            "swap         \(fmt.memory(s.swapUsedBytes)) / \(fmt.memory(s.swapTotalBytes))",
            "paging       in=\(String(format: "%.0f", s.pageInsPerSecond))/s out=\(String(format: "%.0f", s.pageOutsPerSecond))/s",
            "swapping     in=\(String(format: "%.0f", s.swapInsPerSecond))/s out=\(String(format: "%.0f", s.swapOutsPerSecond))/s",
        ]
    }

    private static func describeGPU(_ s: GPUSnapshot) -> [String] {
        guard !s.devices.isEmpty else { return ["no devices"] }
        return s.devices.map { device in
            var parts = ["\(device.name)"]
            parts.append("util=\(device.utilization.map(pct) ?? "—")")
            if let used = device.vramUsedBytes {
                // Unified memory is system RAM, so it follows the binary convention
                // Apple uses for RAM; discrete VRAM is quoted decimally by vendors.
                let label = device.hasUnifiedMemory ? "unified-mem" : "vram"
                let fmtUsed = device.hasUnifiedMemory ? fmt.memory(used) : fmt.bytes(used)
                let fmtTotal = device.vramTotalBytes.map {
                    device.hasUnifiedMemory ? fmt.memory($0) : fmt.bytes($0)
                }
                parts.append("\(label)=\(fmtUsed)" + (fmtTotal.map { "/\($0)" } ?? ""))
            }
            if let cores = device.coreCount { parts.append("cores=\(cores)") }
            parts.append(device.isBuiltIn ? "builtin" : "external")
            return parts.joined(separator: "  ")
        }
    }

    private static func describeNetwork(_ s: NetworkSnapshot) -> [String] {
        var lines = [
            "throughput   ↓ \(fmt.networkRate(s.downloadBytesPerSecond))   ↑ \(fmt.networkRate(s.uploadBytesPerSecond))",
            "since boot   ↓ \(fmt.bytes(s.totalDownloadBytes))  ↑ \(fmt.bytes(s.totalUploadBytes))",
            "primary      \(s.primaryInterfaceName ?? "—") (\(s.connectionType.label))  vpn=\(s.isVPNActive)",
            "address      \(s.localIPv4 ?? "—")",
            // The probe builds its own collector, so the lookup is off here unless a
            // test turns it on. Printing the state is how that stays visible.
            "public ip    \(s.publicIP.value ?? failureKind(s.publicIP.failure ?? .pending))",
        ]
        if let wifi = s.wifi {
            lines.append("wi-fi        ssid=\(wifi.ssid ?? "—") rssi=\(wifi.rssi.map(String.init) ?? "—") "
                         + "ch=\(wifi.channel.map(String.init) ?? "—") rate=\(wifi.transmitRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "—")")
        }
        for interface in s.interfaces.filter(\.isActive) {
            lines.append("  \(interface.name.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                         + "\(interface.type.rawValue)  ↓\(fmt.networkRate(interface.downloadBytesPerSecond)) ↑\(fmt.networkRate(interface.uploadBytesPerSecond))")
        }
        return lines
    }

    private static func describeDisk(_ s: DiskSnapshot) -> [String] {
        var lines = [
            "activity     read \(fmt.diskRate(s.readBytesPerSecond))  write \(fmt.diskRate(s.writeBytesPerSecond))",
            "ops          read \(String(format: "%.0f", s.readOpsPerSecond))/s  write \(String(format: "%.0f", s.writeOpsPerSecond))/s",
            "since boot   read \(fmt.bytes(s.totalReadBytes))  write \(fmt.bytes(s.totalWriteBytes))",
        ]
        for volume in s.volumes {
            lines.append("  \(volume.name.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                         + "\(fmt.storage(volume.usedBytes)) / \(fmt.storage(volume.totalBytes)) "
                         + "(\(pct(volume.usedFraction)))  free \(fmt.storage(volume.availableBytes))"
                         + (volume.isRoot ? "  [root]" : "")
                         + (volume.isRemovable ? "  [removable]" : ""))
        }
        return lines
    }

    private static func describePower(_ s: PowerSnapshot) -> [String] {
        guard s.hasBattery else {
            return ["no battery", "adapter      \(s.adapterName ?? "—") \(s.adapterWatts.map { "\($0)W" } ?? "")",
                    "system power \(fmt.watts(s.systemWatts))"]
        }
        return [
            "charge       \(s.percentage.map { String(format: "%.0f%%", $0) } ?? "—")  charging=\(s.isCharging) plugged=\(s.isPluggedIn) full=\(s.isFullyCharged)",
            "remaining    empty=\(fmt.duration(s.timeToEmpty))  full=\(fmt.duration(s.timeToFull))",
            "health       \(s.healthPercent.map { String(format: "%.1f%%", $0) } ?? "—")  cycles=\(s.cycleCount.map(String.init) ?? "—")  condition=\(s.condition ?? "—")",
            "capacity     \(s.currentCapacitymAh.map(String.init) ?? "—") / \(s.maxCapacitymAh.map(String.init) ?? "—") mAh (design \(s.designCapacitymAh.map(String.init) ?? "—"))",
            "electrical   \(s.voltage.map { String(format: "%.2f V", $0) } ?? "—")  \(s.amperage.map { String(format: "%.0f mA", $0) } ?? "—")  \(fmt.watts(s.batteryWatts))",
            "temperature  \(fmt.temperature(s.temperatureCelsius, decimals: 1))",
            "adapter      \(s.adapterName ?? "—") \(s.adapterWatts.map { "\($0)W" } ?? "")",
            "system power \(fmt.watts(s.systemWatts))",
            "low power    \(s.isLowPowerMode)   optimized-hold=\(s.isOptimizedChargingPaused)",
        ]
    }

    private static func describeThermal(_ s: ThermalSnapshot) -> [String] {
        var lines = ["pressure     \(s.pressure.label)"]
        if let reason = s.sensorsUnavailableReason {
            lines.append("sensors      unavailable: \(reason)")
        }
        if let cpu = s.cpuCelsius { lines.append("cpu          \(fmt.temperature(cpu, decimals: 1))") }
        if let gpu = s.gpuCelsius { lines.append("gpu          \(fmt.temperature(gpu, decimals: 1))") }
        for fan in s.fans {
            lines.append("  fan \(fan.id)      \(fmt.rpm(fan.currentRPM))"
                         + (fan.minRPM.map { " min \(Int($0))" } ?? "")
                         + (fan.maxRPM.map { " max \(Int($0))" } ?? ""))
        }
        for sensor in s.sensors.prefix(24) {
            lines.append("  \(sensor.id.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                         + "\(sensor.name.padding(toLength: 26, withPad: " ", startingAt: 0)) "
                         + fmt.temperature(sensor.celsius, decimals: 1))
        }
        if s.sensors.count > 24 { lines.append("  … \(s.sensors.count - 24) more sensors") }
        return lines
    }

    private static func describeProcesses(_ s: ProcessSnapshot) -> [String] {
        var lines = ["\(s.totalProcessCount) processes / \(s.totalThreadCount) threads"]
        lines.append("  PID     CPU%    MEM        THR  NAME")
        for process in s.processes.prefix(12) {
            lines.append("  " + String(format: "%-7d %6.1f  %-9s %4d  %@",
                                       process.pid,
                                       process.cpuPercent,
                                       (fmt.bytes(process.memoryBytes) as NSString).utf8String!,
                                       process.threadCount,
                                       process.name))
        }
        return lines
    }

    private static func describeAI(_ snapshot: AISnapshot) -> [String] {
        if snapshot.instances.isEmpty { return ["no log sources configured"] }
        return snapshot.instances.flatMap { instance -> [String] in
            var lines = ["\(instance.name) [\(instance.runtime.label)]  \(instance.status.message)"]
            lines.append("  API         \(instance.apiStatus.message)")
            if let date = instance.apiFetchedAt { lines.append("  API success \(date)") }
            if let date = instance.lastEventAt { lines.append("  last event  \(date)") }
            lines.append("  memory      \(instance.memoryBytes.map { fmt.memory($0) } ?? "—") (process RSS)")
            lines.append("  processes   \(instance.processMemoryStatus.message)")
            for process in instance.processes {
                let footprint = process.physicalFootprintBytes.map { fmt.memory($0) } ?? "—"
                lines.append("  PID \(process.pid)  RSS=\(fmt.memory(process.residentBytes))  physical-footprint=\(footprint)")
            }
            for model in instance.models {
                let active = model.isActive.map { $0 ? "generating" : "idle" } ?? "activity unknown"
                let loaded = model.isLoaded.map { $0 ? "loaded" : "unloaded" } ?? "load state unknown"
                let context = model.contextWindowUsed.map(String.init) ?? "—"
                let total = model.contextWindowTotal.map(String.init) ?? "—"
                let generation = model.tokensPerSecond.map { String(format: "%.2f tok/s", $0) } ?? "—"
                let prefill = model.contextTokensPerSecond.map { String(format: "%.2f tok/s", $0) } ?? "—"
                lines.append("  model       \(model.name) (\(loaded), \(active))")
                lines.append("  context     \(context) / \(total) tokens  generation=\(generation)  prefill=\(prefill)")
                for slot in model.slots {
                    let task = slot.taskID.map(String.init) ?? "—"
                    let answer = slot.tokensPerSecond.map { String(format: "%.2f", $0) } ?? "—"
                    let prefill = slot.contextTokensPerSecond.map { String(format: "%.2f", $0) } ?? "—"
                    let used = slot.contextWindowUsed.map(String.init) ?? "—"
                    let capacity = slot.contextWindowTotal.map(String.init) ?? "—"
                    lines.append("  slot \(slot.id)      \(slot.phase.label)  task=\(task)  context=\(used)/\(capacity)  answer=\(answer) tok/s  prefill=\(prefill) tok/s")
                }
                for progress in model.prefillProgress {
                    let slot = progress.slotID.map { " slot=\($0)" } ?? ""
                    let task = progress.taskID.map { " task=\($0)" } ?? ""
                    let elapsed = progress.elapsed.map { fmt.fixed($0, decimals: 2) + "s" } ?? "—"
                    let rate = progress.tokensPerSecond.map { fmt.fixed($0, decimals: 2) + " tok/s" } ?? "—"
                    lines.append("  reading     \(fmt.percent(progress.fraction))  \(progress.processedTokens) tokens\(slot)\(task)  elapsed=\(elapsed)  rate=\(rate)")
                }
            }
            lines.append("  new metrics \(instance.observations.count)")
            return lines
        }
    }
}
