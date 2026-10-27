import Foundation

/// Parses runtime measurements without retaining request bodies or generated text.
struct AILogParser {
    private enum PrefillKey: Hashable {
        case slot(Int), task(Int), unidentified
    }

    private struct GenerationTask: Hashable {
        var slotID: Int?
        var taskID: Int?
    }

    private struct ModelState {
        var info: AIModelInfo
        var allocations: [String: UInt64] = [:]
        var generationAt: Date?
        var prefillAt: Date?
        var slotCount: Int?
        var contextCapacity: Int?
        var slotCapacity: Int?
        var usedSlots: [Int: Int] = [:]
        var activeSlots = Set<Int>()
        var activityKnown = false
        var loading = true
        var sourceIdentities = Set<String>()
        var prefillProgress: [PrefillKey: AIPrefillProgress] = [:]
        var sampledGenerations: [GenerationTask: Date] = [:]
        var sampledPrefills: [GenerationTask: Date] = [:]
        var slots: [Int: AISlotInfo] = [:]
    }
    private var states: [String: ModelState] = [:]
    private var currentKey: String?
    private var nextLoad = 0
    private var pendingOllamaLoad: String?
    private var routerPorts: [String: String] = [:]
    private var hasRouterInventory = false
    private(set) var lastEventAt: Date?
    private(set) var observations: [AIObservation] = []
    private let instanceID: UUID
    var model: AIModelInfo? { currentKey.flatMap { states[$0]?.info } }

    init(instanceID: UUID) { self.instanceID = instanceID }
    mutating func beginPoll() { observations.removeAll(keepingCapacity: true) }

    mutating func consume(_ record: AILogRecord) {
        let line = record.text
        guard !line.contains("\"messages\""), !line.contains("\"content\""),
              !line.contains("\"prompt\":") else { return }
        let lower = line.lowercased()
        if record.continuityBreak, let source = record.sourceIdentity {
            // The skipped middle may contain an exit or a switch to another model.
            states = states.filter { !$0.value.sourceIdentities.contains(source) }
            if let currentKey, states[currentKey] == nil { self.currentKey = nil }
            if let pendingOllamaLoad, states[pendingOllamaLoad] == nil { self.pendingOllamaLoad = nil }
        }
        if lower.contains("starting server in router mode") {
            hasRouterInventory = true
            routerPorts.removeAll(keepingCapacity: true)
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            return
        }
        if let spawned = Self.captures(#"spawning server instance with name=([^\s]+) on port (\d+)"#, line) {
            hasRouterInventory = true
            routerPorts[spawned[1]] = spawned[0]
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            return
        }
        if lower.contains("msg=\"server config\"") {
            // A daemon restart invalidates loaded models from earlier rotations.
            states.removeAll(keepingCapacity: true)
            currentKey = nil
            pendingOllamaLoad = nil
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            return
        }
        let runner = Self.capture(#"\brunner(?:_id)?[=:]\s*\"?([a-zA-Z0-9._:-]+)"#, line)
            ?? Self.capture(#"\bpid[=:]\s*(\d+)"#, line)
            ?? Self.capture(#"^\[(\d+)\]\s"#, line)
        let namedModel = Self.capture(#"\bmodel[=:]\s*[\"']?([^\s\"',]+)"#, line)
        if lower.contains("msg=\"template selection\""), let reference = namedModel,
           let pendingOllamaLoad, var pending = states[pendingOllamaLoad] {
            // Ollama reports the public tag separately from the GGUF path during
            // this load. /api/ps exposes a manifest digest, not that GGUF's digest.
            pending.info.aliases.formUnion(Self.ollamaAliases(reference))
            states[pendingOllamaLoad] = pending
            return
        }
        if lower.contains("msg=\"loaded runners\""),
           let count = Self.integer(#"\bcount=(\d+)\b"#, line) {
            if count == 0 {
                states.removeAll()
                currentKey = nil
            } else if let pendingOllamaLoad, var loaded = states[pendingOllamaLoad] {
                loaded.loading = false
                if count == 1 {
                    // The scheduler explicitly confirms a single loaded runner;
                    // old unlabelled states must not make its live output ambiguous.
                    states = [pendingOllamaLoad: loaded]
                } else { states[pendingOllamaLoad] = loaded }
                currentKey = pendingOllamaLoad
            }
            pendingOllamaLoad = nil
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            return
        }
        if lower.contains("msg=\"loading model via llama-server\""),
           let reference = namedModel, let currentKey, var pending = states[currentKey], pending.loading,
           pending.info.name == "Model name unavailable" || runner.map({ "runner:" + $0 }) == currentKey {
            pending.info.aliases.formUnion(Self.pathAliases(reference))
            if let source = record.sourceIdentity { pending.sourceIdentities.insert(source) }
            states[currentKey] = pending
            return
        }
        let attributedKey = runner.map { "runner:" + $0 }
            ?? namedModel.map { name in states.first(where: { $0.value.info.name == name })?.key ?? "model:" + name }
        let commandPath = lower.contains("msg=\"starting llama-server\"")
            ? Self.capture(#"\s--model(?:=|\s+)([^\s\"\\]+)"#, line) : nil
        let loadedPath = Self.capture(#"(?:load_model: loading model|model path\s*=)\s*['\"]([^'\"]+)"#, line) ?? commandPath
        let starting = lower.contains("starting llama-server") || lower.contains("starting llama server")
            || lower.contains("starting runner") || lower.contains("load_model: loading model")
        if starting {
            let key: String
            if let attributedKey { key = attributedKey }
            else if let currentKey, states[currentKey]?.loading == true,
                    states[currentKey]?.info.name == "Model name unavailable" { key = currentKey }
            else { nextLoad += 1; key = "load:\(nextLoad)" }
            let loadingDetail = lower.contains("load_model: loading model")
            if !(loadingDetail && states[key]?.loading == true
                && states[key]?.info.name == "Model name unavailable") {
                states[key] = newState(key: key, name: "Model name unavailable", reference: loadedPath ?? namedModel)
            }
            currentKey = key
            if lower.contains("msg=\"starting llama-server\"") { pendingOllamaLoad = key }
        }
        let exiting = lower.contains("exit command received") || lower.contains("stopping model instance")
            || lower.contains("shutting down") || lower.contains("unloading model")
        if exiting {
            let unloadName = Self.capture(#"stopping model instance name=([^\s]+)"#, line)
            if let attributedKey {
                states.removeValue(forKey: attributedKey)
                if let runner { routerPorts.removeValue(forKey: runner) }
            } else if let unloadName {
                let ports = Set(routerPorts.filter { $0.value == unloadName }.map(\.key))
                routerPorts = routerPorts.filter { $0.value != unloadName }
                states = states.filter {
                    $0.value.info.name != unloadName && !ports.contains(String($0.key.dropFirst("runner:".count)))
                }
            } else { states.removeAll() }
            if let currentKey, states[currentKey] == nil { self.currentKey = states.keys.sorted().first }
            if let pendingOllamaLoad, states[pendingOllamaLoad] == nil { self.pendingOllamaLoad = nil }
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            return
        }
        let generalName = Self.capture(#"(?:llama_model_loader:|print_info:).*general\.name\s+(?:str\s+)?=\s*(.+?)\s*$"#, line)
        let metadataName = generalName ?? loadedPath
        let context = Self.integer(#"\bn_ctx(?:_slot|_seq|_per_seq)?\s*=\s*(\d+)"#, line)
        let measurement = Self.timing(line)
        let slot = Self.integer(#"\bid\s+(\d+)\s*\|"#, line)
        let task = Self.integer(#"\btask\s+(\d+)\s*\|"#, line)
        let progress = record.canChart ? Self.progress(line, slotID: slot, taskID: task, at: record.date) : nil
        let allocation = Self.allocation(line)
        let newPrompt = lower.contains("new prompt")
        let finishedPrefill = lower.contains("prompt eval time") || lower.contains("prompt done")
        let decoding = measurement?.isProgress == true
            || (!lower.contains("prompt") && lower.contains("eval time"))
            || lower.contains("start decoding") || lower.contains("decoding started")
            || lower.contains("start generation") || lower.contains("generation started")
        let released = lower.contains("stop processing") || (lower.contains("slot") && lower.contains("release:"))
        let reset = lower.contains("slot") && lower.contains("reset")
        let allIdle = lower.contains("all slots are idle") || lower.contains("server is entering sleeping state")
        let terminal = finishedPrefill || decoding || released
        let key: String
        if let attributedKey {
            key = attributedKey
        } else if states.count == 1, let only = states.keys.first {
            key = only
        } else if let currentKey, states[currentKey]?.loading == true, metadataName != nil || starting {
            key = currentKey
        } else if states.isEmpty, metadataName != nil || context != nil || measurement != nil || progress != nil || allocation != nil {
            nextLoad += 1
            key = "load:\(nextLoad)"
        } else {
            // Ollama can interleave unlabelled output from multiple runners. The log
            // cannot then identify whose context, rate or allocation this is.
            return
        }
        guard starting || metadataName != nil || context != nil || measurement != nil || progress != nil || allocation != nil
            || newPrompt || terminal || reset || allIdle
            || lower.contains("slot") || lower.contains("context_used")
            || lower.contains("server is entering sleeping state") else { return }
        var state = states[key] ?? newState(key: key, name: namedModel ?? "Model name unavailable",
                                          reference: loadedPath ?? namedModel)
        currentKey = key
        var recognized = starting
        if let loadedPath { state.info.aliases.formUnion(Self.pathAliases(loadedPath)) }
        if let name = metadataName {
            let cleanName = generalName != nil ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            let unavailableNames: Set<String> = ["n/a", "unknown", "none", "(null)"]
            if !cleanName.isEmpty && !cleanName.hasPrefix("sha256-")
                && !unavailableNames.contains(cleanName.lowercased()) {
                state.info.name = cleanName
                state.info.aliases.insert(cleanName)
                state.info.id = AIModelInfo.stableID(endpointID: instanceID,
                    name: cleanName + (key.hasPrefix("runner:") ? "@" + key : ""))
                // An unlabelled reload of the same named model replaces its previous
                // allocation state; explicitly separate runners retain their identities.
                if !key.hasPrefix("runner:") {
                    states = states.filter { $0.key == key || $0.value.info.name != cleanName }
                }
                recognized = true
            }
        }
        if let slots = Self.integer(#"\bn_slots\s*=\s*(\d+)"#, line), slots > 0 { state.slotCount = slots }
        if let context, context > 0, !lower.contains("n_ctx_train"), !lower.contains("n_ctx_orig") {
            if lower.contains("n_ctx_slot") || lower.contains("n_ctx_seq") || lower.contains("n_ctx_per_seq") {
                state.slotCapacity = context
            } else { state.contextCapacity = context }
            state.info.contextWindowTotal = state.contextCapacity ?? Self.product(state.slotCapacity, state.slotCount ?? 1)
            recognized = true
        }
        if newPrompt || reset {
            let keep: (Dictionary<GenerationTask, Date>.Element) -> Bool = {
                if let slot { return $0.key.slotID != slot }
                if let task { return $0.key.taskID != task }
                return false
            }
            state.sampledGenerations = state.sampledGenerations.filter(keep)
            state.sampledPrefills = state.sampledPrefills.filter(keep)
        }
        if allIdle || lower.contains("reset all slots") || lower.contains("all slots reset") {
            state.prefillProgress = state.prefillProgress.filter { $0.value.updatedAt > record.date }
        } else if newPrompt || reset {
            Self.clearProgress(&state, slotID: slot, taskID: slot == nil ? task : nil, through: record.date)
        } else if terminal {
            Self.clearProgress(&state, slotID: slot, taskID: task, through: record.date)
        } else if let slot, let task, let previous = state.prefillProgress[.slot(slot)],
                  previous.taskID != task && previous.updatedAt <= record.date {
            Self.clearProgress(&state, slotID: slot, taskID: nil, through: record.date)
        }
        if terminal || reset || allIdle { recognized = true }
        if let progress, !terminal && !newPrompt && !reset && !allIdle {
            let progressKey = Self.progressKey(slotID: slot, taskID: task)
            if state.prefillProgress[progressKey].map({ $0.updatedAt <= progress.updatedAt }) ?? true {
                state.prefillProgress[progressKey] = progress
                if state.prefillProgress.count > 128,
                   let oldest = state.prefillProgress.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
                    state.prefillProgress.removeValue(forKey: oldest)
                }
                recognized = true
            }
        }
        state.info.prefillProgress = Self.sortedProgress(state.prefillProgress.values)
        if let used = Self.integer(#"(?:\bn_tokens|\bn_past|\bcontext_used)\s*[=:]\s*(\d+)"#, line),
           lower.contains("slot") || lower.contains("context_used") {
            if let slot {
                state.usedSlots[slot] = used
                state.info.contextWindowUsed = Self.sum(state.usedSlots.values)
            } else if (state.slotCount ?? 1) == 1 { state.info.contextWindowUsed = used }
            recognized = true
        }
        if lower.contains("new prompt") || lower.contains("prompt processing") {
            if record.canChart { state.activeSlots.insert(slot ?? -1) }
            state.info.isActive = record.canChart ? true : nil
            recognized = true
        }
        if lower.contains("all slots are idle") || lower.contains("server is entering sleeping state") {
            state.activeSlots.removeAll()
            state.activityKnown = record.canChart
            state.loading = false
            state.info.isActive = record.canChart ? false : nil
            recognized = true
        } else if lower.contains("stop processing") {
            state.activeSlots.remove(slot ?? -1)
            state.info.isActive = record.canChart
                ? (!state.activeSlots.isEmpty ? true : (state.activityKnown || (state.slotCount ?? 1) == 1 ? false : nil))
                : nil
            recognized = true
        }
        if let measurement {
            let prefill = lower.contains("prompt")
            let generationTask = GenerationTask(slotID: slot, taskID: task)
            let livePrefill = prefill && progress != nil && lower.contains("prompt processing")
            if prefill {
                state.info.contextTokensPerSecond = record.canChart ? measurement.rate : nil
                state.prefillAt = record.canChart ? record.date : nil
            } else {
                state.info.tokensPerSecond = record.canChart ? measurement.rate : nil
                state.generationAt = record.canChart ? record.date : nil
            }
            if measurement.isProgress {
                if record.canChart {
                    state.activeSlots.insert(slot ?? -1)
                    state.sampledGenerations[generationTask] = record.date
                    if state.sampledGenerations.count > 128,
                       let oldest = state.sampledGenerations.min(by: { $0.value < $1.value })?.key {
                        state.sampledGenerations.removeValue(forKey: oldest)
                    }
                }
                state.info.isActive = record.canChart ? true : nil
            }
            if livePrefill, record.canChart {
                state.sampledPrefills[generationTask] = record.date
                if state.sampledPrefills.count > 128,
                   let oldest = state.sampledPrefills.min(by: { $0.value < $1.value })?.key {
                    state.sampledPrefills.removeValue(forKey: oldest)
                }
            }
            // A completed request's cumulative timing overlaps its live samples.
            // Keep the summary as a fallback only for requests not sampled live.
            let alreadySampled = prefill ? state.sampledPrefills[generationTask] != nil
                : state.sampledGenerations[generationTask] != nil
            let shouldChart = measurement.isProgress || livePrefill
                || (measurement.duration != nil && measurement.tokens != nil && !alreadySampled)
            if record.canChart, shouldChart {
                observations.append(AIObservation(id: record.id + (prefill ? ":prefill" : ":generation"),
                    instanceID: instanceID, kind: prefill ? .prefill : .generation,
                    date: record.date, value: measurement.rate,
                    tokenCount: measurement.tokens, duration: measurement.duration,
                    modelID: state.info.historyID, slotID: slot, taskID: task))
            }
            recognized = true
        }
        Self.updateSlots(&state, record: record, slotID: slot, taskID: task,
                         newPrompt: newPrompt, reset: reset, allIdle: allIdle,
                         released: released, decoding: decoding, finishedPrefill: finishedPrefill,
                         progress: progress, measurement: measurement)
        state.info.slots = state.slots.values.sorted { $0.id < $1.id }
        if let allocation {
            state.allocations[allocation.key] = allocation.bytes
            state.info.memoryBytes = Self.sumBytes(state.allocations.values)
            recognized = true
        }
        if recognized {
            lastEventAt = max(lastEventAt ?? record.date, record.date)
            state.info.lastObservedAt = max(state.info.lastObservedAt ?? record.date, record.date)
        }
        if let source = record.sourceIdentity { state.sourceIdentities.insert(source) }
        states[key] = state
        if states.count > 64 {
            let oldest = states.keys.filter { $0 != key }.min {
                (states[$0]?.info.lastObservedAt ?? .distantPast) < (states[$1]?.info.lastObservedAt ?? .distantPast)
            }
            if let oldest { states.removeValue(forKey: oldest) }
        }
        if allocation != nil, record.canChart, let bytes = memoryBytes(at: record.date) {
            observations.append(AIObservation(id: record.id + ":memory", instanceID: instanceID,
                kind: .memory, date: record.date, value: Double(bytes)))
        }
    }

    private func newState(key: String, name: String, reference: String? = nil) -> ModelState {
        let id = AIModelInfo.stableID(endpointID: instanceID, name: name + "@" + key)
        let aliases: Set<String> = name == "Model name unavailable" ? [] : [name]
        let historyID = AIModelInfo.stableID(endpointID: instanceID, name: (reference ?? name) + "@" + key)
        return ModelState(info: AIModelInfo(id: id, endpointID: instanceID, name: name,
                                           aliases: aliases, historyID: historyID))
    }

    private func memoryBytes(at date: Date) -> UInt64? {
        let measured = states.filter { visibleModelKey($0.key) }.map(\.value)
        guard !measured.isEmpty, measured.allSatisfy({
            $0.info.memoryBytes != nil && ($0.info.lastObservedAt.map { date.timeIntervalSince($0) <= 300 } ?? false)
        }) else { return nil }
        return Self.sumBytes(measured.compactMap { $0.info.memoryBytes })
    }

    private func visibleModelKey(_ key: String) -> Bool {
        guard hasRouterInventory else { return true }
        return key.hasPrefix("runner:") && routerPorts[String(key.dropFirst("runner:".count))] != nil
    }

    func snapshot(endpoint: AIEndpoint, read: AILogRead, now: Date) -> AIInstanceSnapshot {
        var status = read.status
        let stale = read.modifiedAt.map { now.timeIntervalSince($0) > 300 } ?? true
        let unavailable = stale || status == .missingLogs || status == .unreadable
        var models: [AIModelInfo] = []
        for (key, state) in states {
            guard visibleModelKey(key) else { continue }
            var info = state.info
            if key.hasPrefix("runner:"), let alias = routerPorts[String(key.dropFirst("runner:".count))] {
                info.aliases.insert(alias)
            }
            let modelStale = info.lastObservedAt.map { now.timeIntervalSince($0) > 300 } ?? true
            info.slots = state.slots.values.map { $0.current(at: now, available: !unavailable && !modelStale) }
                .sorted { $0.id < $1.id }
            if unavailable || modelStale {
                info.isActive = nil
                info.memoryBytes = nil
                info.contextWindowUsed = nil
                info.tokensPerSecond = nil
                info.contextTokensPerSecond = nil
                info.prefillProgress = []
            } else {
                if state.generationAt.map({ now.timeIntervalSince($0) > 60 }) ?? true { info.tokensPerSecond = nil }
                if state.prefillAt.map({ now.timeIntervalSince($0) > 60 }) ?? true { info.contextTokensPerSecond = nil }
                if info.lastObservedAt.map({ now.timeIntervalSince($0) > 300 }) ?? true { info.isActive = nil }
                let generation = info.slots.compactMap(\.tokensPerSecond)
                let prefill = info.slots.compactMap(\.contextTokensPerSecond)
                if !generation.isEmpty { info.tokensPerSecond = generation.reduce(0, +) / Double(generation.count) }
                if !prefill.isEmpty { info.contextTokensPerSecond = prefill.reduce(0, +) / Double(prefill.count) }
                if info.slots.contains(where: { $0.phase.isActive == true }) { info.isActive = true }
            }
            info.prefillProgress = info.prefillProgress.filter {
                let age = now.timeIntervalSince($0.updatedAt)
                return age >= -1 && age <= 60
            }
            models.append(info)
        }
        models.sort { left, right in
            if left.name == right.name { return left.id.uuidString < right.id.uuidString }
            return left.name < right.name
        }
        if status == .monitoring {
            if stale { status = .stale }
            else if !models.isEmpty && models.allSatisfy({ $0.isActive == false }) { status = .idle }
        }
        let currentMemory: UInt64?
        if !unavailable && !models.isEmpty && models.allSatisfy({ $0.memoryBytes != nil }) {
            currentMemory = Self.sumBytes(models.compactMap(\.memoryBytes))
        } else { currentMemory = nil }
        return AIInstanceSnapshot(id: endpoint.id, name: endpoint.name, runtime: endpoint.runtime,
            status: status, models: models, memoryBytes: currentMemory,
            lastEventAt: lastEventAt, observations: observations)
    }

    private static func updateSlots(_ state: inout ModelState, record: AILogRecord,
                                    slotID: Int?, taskID: Int?, newPrompt: Bool, reset: Bool,
                                    allIdle: Bool, released: Bool, decoding: Bool, finishedPrefill: Bool,
                                    progress: AIPrefillProgress?,
                                    measurement: (rate: Double, tokens: Int?, duration: TimeInterval?, isProgress: Bool)?) {
        if allIdle {
            for id in Array(state.slots.keys) where state.slots[id]!.updatedAt <= record.date {
                state.slots[id]!.phase = record.canChart ? .idle : .unknown
                state.slots[id]!.prefillProgress = nil
                state.slots[id]!.updatedAt = record.date
            }
        }
        guard let slotID else { return }
        var slot = state.slots[slotID] ?? AISlotInfo(id: slotID, updatedAt: record.date)
        guard slot.updatedAt <= record.date else { return }
        let differentTask = taskID != nil && slot.taskID != nil && taskID != slot.taskID
        // An old task's trailing summary must not replace the request now using the slot.
        if differentTask, slot.phase.isActive == true, !newPrompt,
           released || finishedPrefill || (measurement != nil && !measurement!.isProgress) { return }
        if newPrompt || reset || differentTask {
            slot = AISlotInfo(id: slotID, contextWindowTotal: slot.contextWindowTotal, updatedAt: record.date)
        }
        slot.taskID = taskID ?? slot.taskID
        slot.updatedAt = record.date
        if let total = integer(#"\bn_ctx(?:_slot|_seq|_per_seq)?\s*=\s*(\d+)"#, record.text), total > 0 {
            slot.contextWindowTotal = total
        } else if slot.contextWindowTotal == nil { slot.contextWindowTotal = state.slotCapacity }
        if record.canChart,
           let used = integer(#"(?:\bn_tokens|\bn_past|\bcontext_used)\s*[=:]\s*(\d+)"#, record.text) {
            slot.contextWindowUsed = used
        }
        if newPrompt { slot.phase = record.canChart ? .prefill : .unknown }
        if reset { slot.phase = record.canChart ? .idle : .unknown }
        if let progress {
            slot.phase = .prefill
            slot.prefillProgress = progress
        }
        if let measurement {
            if record.text.lowercased().contains("prompt") {
                slot.contextTokensPerSecond = record.canChart ? measurement.rate : nil
                slot.prefillMeasuredAt = record.canChart ? record.date : nil
            } else {
                slot.tokensPerSecond = record.canChart ? measurement.rate : nil
                slot.generationMeasuredAt = record.canChart ? record.date : nil
                slot.generatedTokens = record.canChart
                    ? (integer(#"\bn_gen\s*=\s*(\d+)\b"#, record.text) ?? measurement.tokens) : nil
            }
        }
        if finishedPrefill || decoding {
            slot.prefillProgress = nil
            if slot.phase != .idle { slot.phase = record.canChart ? .answer : .unknown }
        }
        if released {
            slot.phase = record.canChart ? .idle : .unknown
            slot.prefillProgress = nil
        }
        state.slots[slotID] = slot
        if state.slots.count > 128, let oldest = state.slots.min(by: { $0.value.updatedAt < $1.value.updatedAt })?.key {
            state.slots.removeValue(forKey: oldest)
        }
    }

    private static func progressKey(slotID: Int?, taskID: Int?) -> PrefillKey {
        if let slotID { return .slot(slotID) }
        if let taskID { return .task(taskID) }
        return .unidentified
    }

    private static func clearProgress(_ state: inout ModelState, slotID: Int?, taskID: Int?, through date: Date) {
        if let slotID {
            let key = PrefillKey.slot(slotID)
            if let current = state.prefillProgress[key], current.updatedAt <= date,
               taskID == nil || current.taskID == nil || current.taskID == taskID {
                state.prefillProgress.removeValue(forKey: key)
            }
            if let taskID, let current = state.prefillProgress[.task(taskID)], current.updatedAt <= date {
                state.prefillProgress.removeValue(forKey: .task(taskID))
            }
        } else if let taskID {
            state.prefillProgress = state.prefillProgress.filter {
                $0.value.taskID != taskID || $0.value.updatedAt > date
            }
        } else if state.slotCount == 1 {
            state.prefillProgress = state.prefillProgress.filter { $0.value.updatedAt > date }
        } else if let current = state.prefillProgress[.unidentified], current.updatedAt <= date {
            state.prefillProgress.removeValue(forKey: .unidentified)
        }
    }

    private static func sortedProgress<S: Sequence>(_ values: S) -> [AIPrefillProgress] where S.Element == AIPrefillProgress {
        values.sorted { left, right in
            let leftSlot = left.slotID ?? -1
            let rightSlot = right.slotID ?? -1
            if leftSlot != rightSlot { return leftSlot < rightSlot }
            return (left.taskID ?? -1) < (right.taskID ?? -1)
        }
    }

    private static func progress(_ line: String, slotID: Int?, taskID: Int?, at date: Date) -> AIPrefillProgress? {
        guard line.lowercased().contains("prompt processing"),
              let rawFraction = capture(#"\bprogress\s*=\s*([^,\s]+)"#, line),
              let fraction = Double(rawFraction), fraction.isFinite, (0...1).contains(fraction),
              let processed = integer(#"\bn_tokens\s*=\s*(\d+)(?=\s*(?:,|$))"#, line) else { return nil }
        let elapsed = nonnegative(capture(#"\bt\s*=\s*([^,\s]+)\s*s\b"#, line))
        let rate = nonnegative(capture(#"([^,\s()]+)\s+tokens per secon(?:d)?\b"#, line))
        // The logged fraction is rounded; dividing tokens by it would invent a total.
        return AIPrefillProgress(slotID: slotID, taskID: taskID, fraction: fraction,
            processedTokens: processed, elapsed: elapsed, tokensPerSecond: rate, updatedAt: date)
    }

    private static func nonnegative(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func pathAliases(_ path: String) -> Set<String> {
        var aliases: Set<String> = [path]
        let basename = URL(fileURLWithPath: path).lastPathComponent
        if !basename.isEmpty {
            aliases.insert(basename)
            aliases.insert((basename as NSString).deletingPathExtension)
        }
        if let digest = capture(#"(?:^|/)sha256[-:]([0-9a-f]{64})$"#, path)?.lowercased() {
            aliases.formUnion([digest, "sha256-" + digest, "sha256:" + digest])
        }
        return aliases
    }

    private static func ollamaAliases(_ name: String) -> Set<String> {
        var aliases: Set<String> = [name]
        let registry = "registry.ollama.ai/"
        if name.hasPrefix(registry) {
            let qualified = String(name.dropFirst(registry.count))
            aliases.insert(qualified)
            if qualified.hasPrefix("library/") {
                aliases.insert(String(qualified.dropFirst("library/".count)))
            }
        }
        return aliases
    }

    private static var expressions: [String: NSRegularExpression] = [:]
    private static let expressionLock = NSLock()
    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        expressionLock.lock()
        let regex: NSRegularExpression
        if let cached = expressions[pattern] { regex = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                expressionLock.unlock()
                return nil
            }
            expressions[pattern] = compiled
            regex = compiled
        }
        expressionLock.unlock()
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
    private static func capture(_ pattern: String, _ text: String) -> String? { captures(pattern, text)?.first }
    private static func integer(_ pattern: String, _ text: String) -> Int? { capture(pattern, text).flatMap(Int.init) }
    private static func product(_ value: Int?, _ factor: Int) -> Int? {
        guard let value else { return nil }
        let result = value.multipliedReportingOverflow(by: factor)
        return result.overflow ? nil : result.partialValue
    }
    private static func sum<S: Sequence>(_ values: S) -> Int? where S.Element == Int {
        var result = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }
    private static func sumBytes<S: Sequence>(_ values: S) -> UInt64? where S.Element == UInt64 {
        var result: UInt64 = 0
        for value in values {
            let next = result.addingReportingOverflow(value)
            guard !next.overflow else { return nil }
            result = next.partialValue
        }
        return result
    }
    private static func timing(_ line: String) -> (rate: Double, tokens: Int?, duration: TimeInterval?, isProgress: Bool)? {
        if line.contains("print_timing:"), integer(#"\bn_gen\s*=\s*(\d+)\b"#, line) != nil,
           let rate = nonnegative(capture(#"\btg_3s\s*=\s*([^,\s]+)\s+t/s\b"#, line))
                ?? nonnegative(capture(#"\btg\s*=\s*([^,\s]+)\s+t/s\b"#, line)) {
            // n_gen is cumulative, not a new token count for every progress line.
            return (rate, nil, nil, true)
        }
        guard line.contains("eval time") || line.contains("prompt processing") || line.contains("eval_time"),
              let text = capture(#"([^,\s()]+)\s+tokens per secon(?:d)?\b"#, line),
              let rate = Double(text), rate.isFinite, rate >= 0 else { return nil }
        if let fields = captures(#"eval time\s*=\s*([0-9.]+)\s*ms\s*/\s*(\d+)\s+(?:tokens|runs)"#, line),
           let milliseconds = Double(fields[0]), milliseconds.isFinite, milliseconds > 0,
           let tokens = Int(fields[1]) {
            return (rate, tokens, milliseconds / 1000, false)
        }
        return (rate, nil, nil, false)
    }
    private static func allocation(_ line: String) -> (key: String, bytes: UInt64)? {
        guard let fields = captures(#"(?:load_tensors:|llama_context:|llama_kv_cache:|llama_memory_recurrent:|sched_reserve:|reserve_compute_meta:)\s*(\S+)\s+(model|KV|RS|compute|output)\s+buffer size\s*=\s*([0-9.]+)\s*(KiB|MiB|GiB|KB|MB|GB|bytes)"#, line),
              let number = Double(fields[2]), number >= 0 else { return nil }
        let multiplier: Double
        switch fields[3].lowercased() {
        case "kib": multiplier = 1024
        case "mib": multiplier = 1024 * 1024
        case "gib": multiplier = 1024 * 1024 * 1024
        case "kb": multiplier = 1000
        case "mb": multiplier = 1000 * 1000
        case "gb": multiplier = 1000 * 1000 * 1000
        default: multiplier = 1
        }
        let value = number * multiplier
        guard value.isFinite, value < Double(UInt64.max) else { return nil }
        return (fields[0].lowercased() + ":" + fields[1].lowercased(), UInt64(value))
    }
}
