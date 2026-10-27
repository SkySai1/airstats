import SwiftUI
import AirStatKit

struct AISlotSelection: Hashable {
    var modelID: UUID
    var slotID: Int
}

/// Shared wording for the menu bar, panel and desktop widget. A model found in an
/// old startup log is evidence that it was loaded, not that it is still running.
enum AIReadoutSummary {
    static func value(_ snapshot: AISnapshot) -> String {
        let current = snapshot.instances.filter { $0.apiStatus == .online || $0.status == .monitoring || $0.status == .idle }
        let prefilling = current.reduce(0) { count, instance in
            count + instance.models.reduce(0) {
                $0 + prefill($1, status: instance.status, apiStatus: instance.apiStatus,
                             now: snapshot.capturedAt).count
            }
        }
        let active = current.flatMap(\.models).reduce(0) { count, model in
            if !model.slots.isEmpty {
                return count + model.slots.filter { $0.phase == .answer || $0.phase == .processing }.count
            }
            return count + (model.isActive == true && model.prefillProgress.isEmpty ? 1 : 0)
        }
        if prefilling > 0, active > 0 { return "\(prefilling) prefill · \(active) answer" }
        if prefilling > 0 { return "\(prefilling) prefill" }
        if active > 0 { return "\(active) generating" }
        let loaded = snapshot.instances.filter { $0.apiStatus == .online }
            .flatMap(\.models).filter { $0.isLoaded == true }.count
        if loaded > 0 { return "\(loaded) loaded" }
        if !snapshot.models.isEmpty { return "\(snapshot.models.count) observed" }
        return snapshot.instances.isEmpty ? "No instances" : "No models"
    }

    static func instanceSelection(_ selection: UUID?, in snapshot: AISnapshot,
                                  allowsAllInstances: Bool) -> UUID? {
        if let selection, snapshot.instances.contains(where: { $0.id == selection }) { return selection }
        return allowsAllInstances ? nil : snapshot.instances.first?.id
    }

    static func slotSelection(_ selection: AISlotSelection?, in instance: AIInstanceSnapshot) -> AISlotSelection? {
        guard let selection, instance.models.contains(where: { model in
            model.historyID == selection.modelID && model.slots.contains { $0.id == selection.slotID }
        }) else { return nil }
        return selection
    }

    static func model(_ model: AIModelInfo, slotID: Int) -> AIModelInfo? {
        guard let slot = model.slots.first(where: { $0.id == slotID }) else { return nil }
        var result = model
        result.slots = [slot]
        result.contextWindowTotal = slot.contextWindowTotal
        result.contextWindowUsed = slot.contextWindowUsed
        result.tokensPerSecond = slot.tokensPerSecond
        result.contextTokensPerSecond = slot.contextTokensPerSecond
        result.prefillProgress = slot.prefillProgress.map { [$0] } ?? []
        result.isActive = slot.phase.isActive
        return result
    }

    static func activity(_ model: AIModelInfo, status: AIInstanceStatus? = nil,
                         apiStatus: AIAPIStatus? = nil, now: Date? = nil) -> String {
        if let status, status != .monitoring && status != .idle && apiStatus != .online {
            return "Activity unknown"
        }
        if model.slots.contains(where: { $0.phase == .prefill }),
           model.slots.contains(where: { $0.phase == .answer }) { return "Prefill + Answer" }
        if !prefill(model, status: status, apiStatus: apiStatus, now: now).isEmpty {
            return "Reading context"
        }
        switch model.isActive {
        case true?: return "Generating"
        case false?: return "Idle"
        case nil: return "Activity unknown"
        }
    }

    static func prefill(_ model: AIModelInfo, status: AIInstanceStatus? = nil,
                        apiStatus: AIAPIStatus? = nil, now: Date? = nil) -> [AIPrefillProgress] {
        if let status, status != .monitoring && status != .idle && apiStatus != .online { return [] }
        return model.prefillProgress.filter { progress in
            guard progress.fraction.isFinite, (0.0...1.0).contains(progress.fraction),
                  progress.processedTokens >= 0 else { return false }
            guard let now else { return true }
            let age = now.timeIntervalSince(progress.updatedAt)
            return age >= -1 && age <= 60
        }
    }

    static func loaded(_ model: AIModelInfo, apiStatus: AIAPIStatus) -> String {
        guard apiStatus == .online, let loaded = model.isLoaded else { return MetricFormatter.unavailable }
        return loaded ? "Yes" : "No"
    }

    static func apiStatus(_ status: AIAPIStatus) -> String {
        switch status {
        case .disabled: return "Disabled"
        case .pending: return "Connecting…"
        case .online: return "Online"
        case .unavailable: return "Unavailable"
        case .stale: return "Stale"
        }
    }

    static func context(_ model: AIModelInfo, formatter: MetricFormatter) -> String {
        let used = model.contextWindowUsed.map { formatter.count($0) } ?? MetricFormatter.unavailable
        let total = model.contextWindowTotal.map { formatter.count($0) } ?? MetricFormatter.unavailable
        return "\(used) / \(total) tokens"
    }

    static func contextFraction(_ model: AIModelInfo) -> Double? {
        guard let total = model.contextWindowTotal, total > 0,
              let used = model.contextWindowUsed, used >= 0 else { return nil }
        return min(Double(used) / Double(total), 1)
    }

    static func rate(_ value: Double?, formatter: MetricFormatter, decimals: Int = 1) -> String {
        guard let value, value.isFinite, value >= 0 else { return MetricFormatter.unavailable }
        let number = formatter.fixed(value, decimals: decimals)
        return number == MetricFormatter.unavailable ? number : "\(number) tok/s"
    }

    static func prefillPercent(_ progress: AIPrefillProgress, formatter: MetricFormatter) -> String {
        guard progress.fraction.isFinite else { return MetricFormatter.unavailable }
        return "\(formatter.fixed(progress.fraction * 100, decimals: 0))%"
    }

    static func prefillSummary(_ progress: AIPrefillProgress, formatter: MetricFormatter) -> String {
        var summary = "\(prefillPercent(progress, formatter: formatter)) complete, \(formatter.count(progress.processedTokens)) tokens processed"
        if let speed = progress.tokensPerSecond, speed.isFinite, speed >= 0 {
            summary += ", reading at \(rate(speed, formatter: formatter, decimals: 2))"
        }
        if let elapsed = progress.elapsed, elapsed.isFinite, elapsed >= 0 {
            summary += ", elapsed \(formatter.fixed(elapsed, decimals: 2)) seconds"
        }
        return summary
    }

    static func issues(_ instance: AIInstanceSnapshot) -> String? {
        var messages: [String] = []
        if instance.apiStatus == .unavailable || instance.apiStatus == .stale {
            messages.append(instance.apiStatus.message)
        }
        if [.stale, .missingLogs, .unreadable].contains(instance.status) {
            messages.append(instance.status.message)
        }
        let noLoadedWorker = instance.processMemoryStatus == .noWorker
            && instance.models.isEmpty && instance.apiStatus == .online
        if instance.processMemoryStatus != .measured && instance.processMemoryStatus != .pending && !noLoadedWorker {
            messages.append(instance.processMemoryStatus.message)
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    static func memoryDetails(_ processes: [AIProcessMemory], formatter: MetricFormatter) -> String {
        guard !processes.isEmpty else { return "Process memory is unavailable. API model sizes and logged buffer sizes are not used as process memory." }
        return processes.map { process in
            let footprint = process.physicalFootprintBytes.map { formatter.memory($0) } ?? MetricFormatter.unavailable
            return "PID \(process.pid): RSS \(formatter.memory(process.residentBytes)); physical footprint \(footprint)"
        }.joined(separator: "\n")
    }
}

/// Instances retain their identity even when two servers load the same model.
/// Both surfaces show the same measured fields; compact only reduces chart height.
struct AIInstanceMetricsView: View {
    let snapshot: AISnapshot
    let history: AIHistory
    let isCompact: Bool
    let tint: Color
    var usesMetricGrid = false
    var allowsAllInstances = true
    var rememberedInstanceID: Binding<UUID?> = .constant(nil)

    @State private var interval: AIHistoryInterval = .oneMinute
    @State private var selectedInstanceID: UUID?
    @State private var selectedSlots: [UUID: AISlotSelection] = [:]
    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        let requestedID = allowsAllInstances ? selectedInstanceID : rememberedInstanceID.wrappedValue
        let selection = AIReadoutSummary.instanceSelection(requestedID, in: snapshot,
                                                           allowsAllInstances: allowsAllInstances)
        let selectedInstance = snapshot.instances.first { $0.id == selection }
        return VStack(alignment: .leading, spacing: Design.Space.m) {
            if snapshot.instances.isEmpty {
                Text("Configure an Ollama or llama.cpp instance in Settings → AI.")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
            } else {
                instancePicker(selection: selectedInstance?.id)
                HStack(spacing: Design.Space.s) {
                    Text("Chart step")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.secondaryText)
                    Spacer(minLength: 0)
                    Picker("Chart step", selection: $interval) {
                        ForEach(AIHistoryInterval.allCases, id: \.self) { step in
                            Text(step.label).tag(step)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .fixedSize()
                    .accessibilityLabel("AI chart aggregation interval")
                }
                ForEach(selectedInstance.map { [$0] } ?? snapshot.instances) { instance in
                    instanceRows(instance)
                }
                HStack {
                    Spacer(minLength: 0)
                    AIWarningIcon(message: "A dash means the source did not report a measurement. API inventory confirms loaded models; logs provide timings and prefill progress. Memory and its chart use the RSS of matched local model processes. Physical footprint is available in the memory tooltip. Shared resident pages may appear in more than one process; sizes from API and log buffers are not substituted for process measurements.")
                }
            }
        }
        .onChange(of: selection, initial: true) { _, id in
            if !allowsAllInstances, let id, rememberedInstanceID.wrappedValue != id {
                rememberedInstanceID.wrappedValue = id
            }
        }
    }

    private func instancePicker(selection: UUID?) -> some View {
        HStack(spacing: Design.Space.s) {
            Text("Instance").font(Design.Text.caption).foregroundStyle(Design.Palette.secondaryText)
            Spacer(minLength: 0)
            Picker("Instance", selection: Binding<UUID?>(
                get: { selection }, set: { id in
                    if allowsAllInstances {
                        selectedInstanceID = id
                    } else if let id {
                        rememberedInstanceID.wrappedValue = id
                    }
                })) {
                if allowsAllInstances {
                    Text("All instances").tag(Optional<UUID>.none)
                }
                ForEach(snapshot.instances) { instance in
                    Text(instance.name).tag(Optional(instance.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .help("Select an instance to view its models, slots and charts.")
            .accessibilityLabel("AI instance")
        }
    }

    private func instanceRows(_ instance: AIInstanceSnapshot) -> some View {
        let selection = AIReadoutSummary.slotSelection(selectedSlots[instance.id], in: instance)
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(instance.name)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(instance.name)
                if let issues = AIReadoutSummary.issues(instance) {
                    AIWarningIcon(message: issues)
                }
                Spacer(minLength: 0)
                Text(instance.runtime.label)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .fixedSize()
            }
            if instance.models.contains(where: { !$0.slots.isEmpty }) {
                slotPicker(instance, selection: selection)
            }
            if instance.models.isEmpty {
                Text("No model activity reported")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            ForEach(instance.models.filter { selection == nil || $0.historyID == selection?.modelID }) { model in
                if let selection, let scoped = AIReadoutSummary.model(model, slotID: selection.slotID) {
                    modelRows(scoped, status: instance.status, apiStatus: instance.apiStatus, selectedSlot: true)
                        .padding(.top, Design.Space.xxs)
                } else {
                    modelRows(model, status: instance.status, apiStatus: instance.apiStatus)
                        .padding(.top, Design.Space.xxs)
                }
            }
            AIInstanceHistoryChart(
                title: "Answer", points: history.generationSeries(
                    instanceID: instance.id, modelID: selection?.modelID, slotID: selection?.slotID,
                    interval: interval, now: snapshot.capturedAt),
                interval: interval, now: snapshot.capturedAt, retention: history.retention,
                isMemory: false, isCompact: isCompact, tint: tint)
            AIInstanceHistoryChart(
                title: "Prefill", points: history.prefillSeries(
                    instanceID: instance.id, modelID: selection?.modelID, slotID: selection?.slotID,
                    interval: interval, now: snapshot.capturedAt),
                interval: interval, now: snapshot.capturedAt, retention: history.retention,
                isMemory: false, isCompact: isCompact, tint: tint, isPrefill: true)
            AIInstanceHistoryChart(
                title: isCompact ? "Memory" : "Memory (RSS)", points: history.memorySeries(
                    instanceID: instance.id, interval: interval, now: snapshot.capturedAt),
                interval: interval, now: snapshot.capturedAt, retention: history.retention,
                isMemory: true, isCompact: isCompact, tint: tint)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(instance.name), \(instance.runtime.label)")
    }

    private func slotPicker(_ instance: AIInstanceSnapshot, selection: AISlotSelection?) -> some View {
        HStack(spacing: Design.Space.s) {
            Text("Slot").font(Design.Text.caption).foregroundStyle(Design.Palette.secondaryText)
            Spacer(minLength: 0)
            Picker("Slot", selection: Binding<AISlotSelection?>(
                get: { selection }, set: { selectedSlots[instance.id] = $0 })) {
                Text("All slots").tag(Optional<AISlotSelection>.none)
                ForEach(instance.models) { model in
                    ForEach(model.slots) { slot in
                        Text("\(instance.models.count > 1 ? model.name + " · " : "")Slot \(slot.id) · \(slot.phase.label)")
                            .tag(Optional(AISlotSelection(modelID: model.historyID, slotID: slot.id)))
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .help("Select a slot to inspect its task, context, prefill and answer history. Memory is shared by the model's slots.")
            .accessibilityLabel("\(instance.name) slot")
        }
    }

    private func modelRows(_ model: AIModelInfo, status: AIInstanceStatus,
                           apiStatus: AIAPIStatus, selectedSlot: Bool = false) -> some View {
        let progress = AIReadoutSummary.prefill(model, status: status, apiStatus: apiStatus,
                                               now: snapshot.capturedAt)
        return VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(model.name)
                    .font(Design.Text.body)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.name)
                Spacer(minLength: 0)
                Text(selectedSlot ? (model.slots.first?.phase.label ?? "Activity unknown")
                     : AIReadoutSummary.activity(model, status: status, apiStatus: apiStatus, now: snapshot.capturedAt))
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .fixedSize()
            }
            if selectedSlot, let slot = model.slots.first {
                if let task = slot.taskID {
                    AIValueRow(label: "Task", value: String(task))
                }
                if let generated = slot.generatedTokens {
                    AIValueRow(label: "Generated", value: "\(formatter.count(generated)) tokens")
                }
            }
            ForEach(progress) { reading in
                AIPrefillProgressView(progress: reading, tint: tint,
                                     showsReadouts: !usesMetricGrid,
                                     usesMetricGrid: usesMetricGrid && progress.count > 1)
            }
            AIValueRow(label: "Context", value: AIReadoutSummary.context(model, formatter: formatter))
            if let fraction = AIReadoutSummary.contextFraction(model) {
                CapacityBar(fraction: fraction, tint: tint, height: 3)
                    .accessibilityLabel("Context utilisation")
                    .accessibilityValue(formatter.percent(fraction))
            }
            if usesMetricGrid {
                PanelDetailGrid(entries: metricEntries(model, progress: progress.count == 1 ? progress.first : nil))
                    .minimumScaleFactor(0.75)
                    .help(AIReadoutSummary.memoryDetails(model.processes, formatter: formatter))
            } else {
                AIValueRow(label: "Generation", value: AIReadoutSummary.rate(model.tokensPerSecond, formatter: formatter))
                AIValueRow(label: "Prefill", value: AIReadoutSummary.rate(model.contextTokensPerSecond, formatter: formatter))
                AIValueRow(label: "Memory", value: model.memoryBytes.map { formatter.memory($0) } ?? MetricFormatter.unavailable)
                    .help(AIReadoutSummary.memoryDetails(model.processes, formatter: formatter))
            }
        }
    }

    private func metricEntries(_ model: AIModelInfo, progress: AIPrefillProgress?) -> [PanelDetailEntry] {
        var entries: [PanelDetailEntry] = []
        if let progress {
            entries.append(PanelDetailEntry("Processed", "\(formatter.count(progress.processedTokens)) tokens"))
            entries.append(PanelDetailEntry("Reading speed", AIReadoutSummary.rate(progress.tokensPerSecond, formatter: formatter, decimals: 2)))
            entries.append(PanelDetailEntry("Elapsed", progress.elapsed.map { "\(formatter.fixed($0, decimals: 2)) s" } ?? MetricFormatter.unavailable))
        }
        entries.append(PanelDetailEntry("Generation", AIReadoutSummary.rate(model.tokensPerSecond, formatter: formatter)))
        entries.append(PanelDetailEntry("Prefill", AIReadoutSummary.rate(model.contextTokensPerSecond, formatter: formatter)))
        entries.append(PanelDetailEntry("Memory", model.memoryBytes.map { formatter.memory($0) } ?? MetricFormatter.unavailable))
        return entries
    }
}

private struct AIWarningIcon: View {
    let message: String

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(Design.Text.caption)
            .foregroundStyle(Design.Palette.secondaryText)
            .help(message)
            .accessibilityLabel(message)
    }
}

/// Progress belongs to a request, while context utilisation belongs to a loaded
/// model. Keep the reported fraction and token count independent: inferring a
/// request total from a rounded percentage would manufacture a measurement.
private struct AIPrefillProgressView: View {
    let progress: AIPrefillProgress
    let tint: Color
    var showsReadouts = true
    var usesMetricGrid = false

    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            AIValueRow(label: "Prefill progress",
                       value: AIReadoutSummary.prefillPercent(progress, formatter: formatter))
            CapacityBar(fraction: progress.fraction, tint: tint, height: Design.Space.xs)
            if !identity.isEmpty {
                Text(identity)
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            if usesMetricGrid {
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Processed", "\(formatter.count(progress.processedTokens)) tokens"),
                    PanelDetailEntry("Reading speed", AIReadoutSummary.rate(progress.tokensPerSecond, formatter: formatter, decimals: 2)),
                    PanelDetailEntry("Elapsed", progress.elapsed.map { "\(formatter.fixed($0, decimals: 2)) s" } ?? MetricFormatter.unavailable),
                ])
                .minimumScaleFactor(0.75)
            } else if showsReadouts {
                AIValueRow(label: "Processed", value: "\(formatter.count(progress.processedTokens)) tokens")
                if let speed = progress.tokensPerSecond {
                    AIValueRow(label: "Reading speed", value: AIReadoutSummary.rate(speed, formatter: formatter, decimals: 2))
                }
                if let elapsed = progress.elapsed, elapsed.isFinite, elapsed >= 0 {
                    AIValueRow(label: "Elapsed", value: "\(formatter.fixed(elapsed, decimals: 2)) s")
                }
            }
        }
        .padding(.vertical, Design.Space.xxs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(identity.isEmpty ? "Prefill progress" : "Prefill progress, \(identity)")
        .accessibilityValue(AIReadoutSummary.prefillSummary(progress, formatter: formatter))
    }

    private var identity: String {
        [progress.slotID.map { "Slot \($0)" }, progress.taskID.map { "Task \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

private struct AIValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(label)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.tertiaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(value)
                .font(Design.Text.caption.monospacedDigit())
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Timestamp geometry preserves empty buckets as gaps. A silent minute cannot be
/// treated as zero throughput, and a cached allocation is not a fresh measurement.
private struct AIInstanceHistoryChart: View {
    let title: String
    let points: [AIHistoryPoint]
    let interval: AIHistoryInterval
    let now: Date
    let retention: TimeInterval
    let isMemory: Bool
    let isCompact: Bool
    let tint: Color
    var isPrefill = false

    @Environment(\.metricFormatter) private var formatter

    private var span: TimeInterval { min(retention, interval.duration * 60) }
    private var end: Date {
        Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / interval.duration)
             * interval.duration)
    }
    private var start: Date { end.addingTimeInterval(-span) }
    private var visible: [AIHistoryPoint] {
        points.filter { $0.date >= start && $0.date <= end && $0.value.isFinite && $0.value >= 0 }
    }

    var body: some View {
        let visible = self.visible
        let scale = ChartScale.resolve(peak: visible.map(\.value).max() ?? 0,
                                       domain: nil, naturalUpperBound: nil, adaptive: true)
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            AIValueRow(label: "\(title) · \(interval.label) mean",
                       value: visible.last.map { string($0.value) } ?? MetricFormatter.unavailable)
            GeometryReader { proxy in
                let rect = ChartLayout.plotRect(in: proxy.size)
                ZStack {
                    PlotShape(ChartPlot.gridPath(in: rect, divisions: 2))
                        .stroke(Design.Palette.separator, lineWidth: Design.Space.hairline)
                    if visible.isEmpty {
                        EmptyBaseline(rect: rect)
                        Text("No \(isMemory ? "memory" : title.lowercased()) measurements")
                            .font(Design.Text.micro)
                            .foregroundStyle(Design.Palette.tertiaryText)
                    } else {
                        PlotShape(path(visible, rect: rect, scale: scale))
                            .stroke(tint, style: StrokeStyle(lineWidth: Design.Chart.lineWidth,
                                                             lineCap: .round, lineJoin: .round))
                        PlotShape(markers(visible, rect: rect, scale: scale))
                            .fill(tint)
                    }
                }
            }
            .frame(height: isCompact ? 32 : 48)
            HStack {
                Text(ChartCaption.window(span))
                Spacer(minLength: 0)
                Text("0–\(string(scale.upperBound))")
            }
            .font(Design.Text.micro)
            .foregroundStyle(Design.Palette.tertiaryText)
        }
        .padding(.top, Design.Space.xs)
        .help(isMemory
              ? "Mean RSS of the local model worker processes. Shared resident pages may appear in multiple processes. Gaps have no measurements."
              : (isPrefill
                 ? "Prompt tokens divided by prefill time when reported together; mean of reported reading rates otherwise. Gaps have no measurements."
                 : "Generated tokens divided by generation time when reported together; mean of reported rates otherwise. Gaps have no measurements."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) history, \(interval.label) steps")
        .accessibilityValue(visible.isEmpty ? "No measurements" :
            "\(visible.count) measured intervals over \(ChartCaption.window(span)); latest measured interval \(string(visible.last!.value))")
    }

    private func string(_ value: Double) -> String {
        isMemory ? formatter.memory(value) : AIReadoutSummary.rate(value, formatter: formatter)
    }

    private func location(_ point: AIHistoryPoint, rect: CGRect, scale: ChartScale) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(point.date.timeIntervalSince(start) / span) * rect.width,
                y: rect.maxY - CGFloat(point.value / scale.upperBound) * rect.height)
    }

    private func path(_ points: [AIHistoryPoint], rect: CGRect, scale: ChartScale) -> Path {
        var result = Path()
        var previous: Date?
        for point in points {
            let location = location(point, rect: rect, scale: scale)
            if let previous, point.date.timeIntervalSince(previous) <= interval.duration * 1.5 {
                result.addLine(to: location)
            } else {
                result.move(to: location)
            }
            previous = point.date
        }
        return result
    }

    private func markers(_ points: [AIHistoryPoint], rect: CGRect, scale: ChartScale) -> Path {
        var result = Path()
        for (index, point) in points.enumerated() {
            let hasPrevious = index > 0 && point.date.timeIntervalSince(points[index - 1].date)
                <= interval.duration * 1.5
            let hasNext = index + 1 < points.count
                && points[index + 1].date.timeIntervalSince(point.date) <= interval.duration * 1.5
            if !hasPrevious && !hasNext || index == points.count - 1 {
                result.addPath(ChartLayout.marker(at: location(point, rect: rect, scale: scale), radius: 1.8))
            }
        }
        return result
    }
}
