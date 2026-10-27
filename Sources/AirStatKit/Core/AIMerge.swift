import Foundation

/// API inventory can remove unloaded models; current log timings take precedence
/// over API generation rates. A fuzzy name match must never attribute one model's work
/// to another model with a similar family or quantization.
public enum AIMerge {
    public static func snapshot(logs: AIInstanceSnapshot, api: AIAPIReading?,
                                apiStatus: AIAPIStatus, now: Date,
                                maximumAge: TimeInterval = 15) -> AIInstanceSnapshot {
        var result = logs
        result.apiStatus = apiStatus
        result.apiFetchedAt = api?.fetchedAt
        let logIsCurrent = logs.status == .monitoring || logs.status == .idle
        guard apiStatus == .online, let api,
              api.fetchedAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince(api.fetchedAt) >= -1,
              now.timeIntervalSince(api.fetchedAt) <= maximumAge else {
            if apiStatus == .online { result.apiStatus = .stale }
            for index in result.models.indices {
                result.models[index].isLoaded = nil
                if !logIsCurrent {
                    result.models[index].isActive = nil
                    result.models[index].prefillProgress.removeAll()
                    result.models[index].slots = result.models[index].slots.map { $0.current(at: now, available: false) }
                }
            }
            return result
        }

        let liveNames = api.models.map { live in
            normalized((api.aliases[live.name] ?? []).union(live.aliases).union([live.name]))
        }
        result.models = api.models.enumerated().map { index, live in
            var model = live
            model.isLoaded = true
            model.aliases.formUnion(api.aliases[live.name] ?? [])
            let names = liveNames[index]
            let matches = logs.models.filter { logged in
                let logNames = normalized(logged.aliases.union([logged.name]))
                guard !names.isDisjoint(with: logNames) else { return false }
                return liveNames.filter { !$0.isDisjoint(with: logNames) }.count == 1
            }
            if matches.count == 1, let logged = matches.first {
                model.historyID = logged.historyID
                model.slots = mergedSlots(logged: logged.slots, live: live, now: now,
                                          apiDate: api.fetchedAt, logIsCurrent: logIsCurrent)
            }
            if logIsCurrent, matches.count == 1, let logged = matches.first {
                model.aliases.formUnion(logged.aliases)
                model.tokensPerSecond = logged.tokensPerSecond ?? live.tokensPerSecond
                model.contextTokensPerSecond = live.contextTokensPerSecond ?? logged.contextTokensPerSecond
                model.contextWindowTotal = live.contextWindowTotal ?? logged.contextWindowTotal
                model.contextWindowUsed = live.contextWindowUsed ?? logged.contextWindowUsed
                model.memoryBytes = live.memoryBytes ?? logged.memoryBytes
                model.isActive = live.isActive ?? logged.isActive
                model.prefillProgress = logged.prefillProgress.filter { progress in
                    let age = now.timeIntervalSince(progress.updatedAt)
                    guard age >= -1, age <= 60 else { return false }
                    // An older idle API response cannot end a newer logged prompt.
                    return live.isActive != false || api.fetchedAt < progress.updatedAt
                }
                if !model.slots.isEmpty {
                    model.prefillProgress = model.slots.compactMap(\.prefillProgress)
                        + model.prefillProgress.filter { $0.slotID == nil }
                    let generation = model.slots.compactMap(\.tokensPerSecond)
                    let prefill = model.slots.compactMap(\.contextTokensPerSecond)
                    model.tokensPerSecond = generation.isEmpty ? live.tokensPerSecond
                        : generation.reduce(0, +) / Double(generation.count)
                    model.contextTokensPerSecond = prefill.isEmpty ? live.contextTokensPerSecond
                        : prefill.reduce(0, +) / Double(prefill.count)
                    if model.slots.contains(where: { $0.phase.isActive == true }) { model.isActive = true }
                }
                if !model.prefillProgress.isEmpty { model.isActive = true }
            }
            return model
        }
        result.memoryBytes = api.memoryBytes ?? completeMemoryTotal(result.models)
        if let bytes = api.memoryBytes {
            result.observations.removeAll { $0.kind == .memory }
            let stamp = api.fetchedAt.timeIntervalSince1970.bitPattern
            result.observations.append(AIObservation(id: "api:\(stamp):memory", instanceID: logs.id,
                kind: .memory, date: api.fetchedAt, value: Double(bytes)))
        }
        return result
    }

    private static func mergedSlots(logged: [AISlotInfo], live: AIModelInfo, now: Date,
                                    apiDate: Date, logIsCurrent: Bool) -> [AISlotInfo] {
        var slots = Dictionary(live.slots.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for raw in logged {
            var slot = raw.current(at: now, available: logIsCurrent)
            if let apiSlot = slots[slot.id] {
                if let task = slot.taskID, let apiTask = apiSlot.taskID, task != apiTask {
                    slots[slot.id] = slot.updatedAt > apiSlot.updatedAt ? slot : apiSlot
                    continue
                }
                slot.contextWindowTotal = apiSlot.contextWindowTotal ?? slot.contextWindowTotal
                slot.contextWindowUsed = apiSlot.contextWindowUsed ?? slot.contextWindowUsed
                slot.taskID = slot.taskID ?? apiSlot.taskID
                if apiSlot.updatedAt >= slot.updatedAt {
                    if apiSlot.phase == .idle {
                        slot.phase = .idle
                        slot.prefillProgress = nil
                    } else if slot.phase == .unknown { slot.phase = apiSlot.phase }
                    slot.updatedAt = apiSlot.updatedAt
                }
            } else if live.isActive == false, apiDate >= slot.updatedAt {
                slot.phase = .idle
                slot.prefillProgress = nil
            }
            slots[slot.id] = slot
        }
        return slots.values.sorted { $0.id < $1.id }
    }

    static func normalized(_ aliases: Set<String>) -> Set<String> {
        var names = Set<String>()
        for alias in aliases where alias != "Model name unavailable" {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            names.insert(trimmed)
            let basename = URL(fileURLWithPath: trimmed).lastPathComponent
            let digest = basename.replacingOccurrences(of: "sha256-", with: "")
                .replacingOccurrences(of: "sha256:", with: "").lowercased()
            if digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) {
                names.insert("digest:" + digest)
            }
            if trimmed.hasSuffix(".gguf") {
                names.insert(basename)
                names.insert(URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent)
            }
        }
        return names
    }

    static func completeMemoryTotal(_ models: [AIModelInfo]) -> UInt64? {
        guard !models.isEmpty else { return nil }
        var total: UInt64 = 0
        for model in models {
            guard let bytes = model.memoryBytes else { return nil }
            let addition = total.addingReportingOverflow(bytes)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
