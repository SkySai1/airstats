import Foundation
import Darwin

struct AIProcessNode: Equatable {
    var pid: Int32
    var parentPID: Int32
    var startedAt: UInt64
    var startedMicroseconds: UInt64 = 0
    var isRuntime: Bool = false
    var isWorker: Bool = false
    var listeningPorts: Set<UInt16> = []
    var modelIdentifiers: Set<String> = []
}

protocol AIProcessInspecting: AnyObject {
    func inventory() -> [AIProcessNode]?
    func isCurrent(_ process: AIProcessNode) -> Bool
    func memory(for process: AIProcessNode) -> AIProcessMemory?
}

/// The port identifies an instance; parentage identifies its workers. Model aliases
/// only select among those workers, never among unrelated processes on the machine.
final class AIProcessMemoryCollector {
    private let inspector: AIProcessInspecting
    private var inventory: [AIProcessNode]?
    private var discoveredAt: Date?

    init(inspector: AIProcessInspecting = NativeAIProcessInspector()) { self.inspector = inspector }

    func invalidate() { inventory = nil; discoveredAt = nil }

    func apply(to snapshot: AIInstanceSnapshot, endpoint: AIEndpoint, now: Date) -> AIInstanceSnapshot {
        var result = snapshot
        result.memoryBytes = nil
        result.processes = []
        result.observations.removeAll { $0.kind == .memory }
        for index in result.models.indices {
            result.models[index].memoryBytes = nil
            result.models[index].processes = []
        }
        guard let port = Self.localPort(endpoint) else {
            result.processMemoryStatus = .remote
            return result
        }
        if discoveredAt.map({ now.timeIntervalSince($0) < 0 || now.timeIntervalSince($0) >= 5 }) ?? true {
            inventory = inspector.inventory()
            discoveredAt = now
        }
        guard var nodes = inventory else {
            result.processMemoryStatus = .unavailable
            return result
        }
        var roots = nodes.filter { $0.isRuntime && $0.listeningPorts.contains(port) }
        if roots.contains(where: { !inspector.isCurrent($0) }) {
            inventory = inspector.inventory()
            discoveredAt = now
            nodes = inventory ?? []
            roots = nodes.filter { $0.isRuntime && $0.listeningPorts.contains(port) }
        }
        guard roots.count == 1, let root = roots.first else {
            result.processMemoryStatus = roots.isEmpty ? .noListener : .ambiguous
            return result
        }
        guard inspector.isCurrent(root) else {
            result.processMemoryStatus = .unavailable
            invalidate()
            return result
        }
        var descendants: Set<Int32> = [root.pid]
        var changed = true
        while changed {
            changed = false
            for node in nodes where descendants.contains(node.parentPID) && !descendants.contains(node.pid) {
                descendants.insert(node.pid)
                changed = true
            }
        }
        let workers = nodes.filter { descendants.contains($0.pid) && $0.isRuntime && $0.isWorker }
        guard !workers.isEmpty else {
            result.processMemoryStatus = .noWorker
            return result
        }
        let names = result.models.map { AIMerge.normalized($0.aliases.union([$0.name])) }
        var assigned: [Int: [AIProcessNode]] = [:]
        var readings: [Int32: AIProcessMemory] = [:]
        var ambiguous = false
        for worker in workers {
            if let memory = inspector.memory(for: worker) { readings[worker.pid] = memory }
            let identities = AIMerge.normalized(worker.modelIdentifiers)
            let matches = names.indices.filter { !names[$0].isDisjoint(with: identities) }
            if matches.count == 1 { assigned[matches[0], default: []].append(worker) }
            else { ambiguous = true }
        }
        result.processes = readings.values.sorted { $0.pid < $1.pid }
        let allReadable = readings.count == workers.count
        result.memoryBytes = allReadable ? Self.sum(result.processes.map(\.residentBytes)) : nil
        for index in result.models.indices {
            guard let processes = assigned[index], !processes.isEmpty,
                  processes.allSatisfy({ readings[$0.pid] != nil }) else { continue }
            let measured = processes.compactMap { readings[$0.pid] }.sorted { $0.pid < $1.pid }
            result.models[index].processes = measured
            result.models[index].memoryBytes = Self.sum(measured.map(\.residentBytes))
        }
        if !allReadable { result.processMemoryStatus = readings.isEmpty ? .unavailable : .partial; invalidate() }
        else if result.memoryBytes == nil { result.processMemoryStatus = .unavailable }
        else if ambiguous || result.models.contains(where: { $0.memoryBytes == nil }) {
            result.processMemoryStatus = .ambiguous
        } else { result.processMemoryStatus = .measured }
        if let bytes = result.memoryBytes {
            result.observations.append(AIObservation(id: "process-rss:\(now.timeIntervalSince1970.bitPattern)",
                instanceID: snapshot.id, kind: .memory, date: now, value: Double(bytes)))
        }
        return result
    }

    static func localPort(_ endpoint: AIEndpoint) -> UInt16? {
        guard let url = endpoint.apiBaseURL, let host = url.host?.lowercased() else { return nil }
        let local = host == "localhost" || host == "::1" || host == "[::1]"
            || (host.split(separator: ".").count == 4 && host.hasPrefix("127.")
                && host.split(separator: ".").allSatisfy { UInt8($0) != nil })
        guard local else { return nil }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard port > 0, port <= Int(UInt16.max) else { return nil }
        return UInt16(port)
    }

    static func sum(_ values: [UInt64]) -> UInt64? {
        var total: UInt64 = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}

/// libproc provides RSS and physical footprint without spawning lsof, ps or vmmap.
final class NativeAIProcessInspector: AIProcessInspecting {
    func inventory() -> [AIProcessNode]? {
        let requested = proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), nil, 0)
        guard requested > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: min(16_384, Int(requested) / MemoryLayout<Int32>.stride + 256))
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), geteuid(), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        var nodes: [AIProcessNode] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<Int32>.stride) where pid > 0 {
            guard let bsd = Self.bsd(pid) else { continue }
            let name = withUnsafeBytes(of: bsd.pbi_comm) { buffer in
                String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            }.lowercased()
            let runtime = name.hasPrefix("ollama") || name == "llama" || name.hasPrefix("llama-server")
            var node = AIProcessNode(pid: pid, parentPID: Int32(bsd.pbi_ppid),
                startedAt: bsd.pbi_start_tvsec, startedMicroseconds: bsd.pbi_start_tvusec, isRuntime: runtime)
            if runtime {
                let arguments = Self.arguments(pid)
                node.modelIdentifiers = Self.modelIdentifiers(arguments)
                let router = arguments.contains { $0 == "--models-dir" || $0 == "--models-preset"
                    || $0.hasPrefix("--models-dir=") || $0.hasPrefix("--models-preset=") }
                node.isWorker = !router && (!node.modelIdentifiers.isEmpty || arguments.contains("runner"))
                node.listeningPorts = Self.listeningPorts(pid)
            }
            nodes.append(node)
        }
        return nodes
    }

    func isCurrent(_ process: AIProcessNode) -> Bool {
        guard let current = Self.bsd(process.pid) else { return false }
        return current.pbi_start_tvsec == process.startedAt && current.pbi_start_tvusec == process.startedMicroseconds
    }

    func memory(for process: AIProcessNode) -> AIProcessMemory? {
        guard isCurrent(process) else { return nil }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let read = withUnsafeMutablePointer(to: &task) {
            proc_pidinfo(process.pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        guard read == size else { return nil }
        var usage = rusage_info_v4()
        let usageOK = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(process.pid, RUSAGE_INFO_V4, $0)
            }
        } == 0
        guard isCurrent(process) else { return nil }
        return AIProcessMemory(pid: process.pid, residentBytes: task.pti_resident_size,
                               physicalFootprintBytes: usageOK ? usage.ri_phys_footprint : nil)
    }

    private static func bsd(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return read == size ? info : nil
    }

    private static func listeningPorts(_ pid: Int32) -> Set<UInt16> {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(),
            count: min(8192, Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16))
        let read = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard read > 0 else { return [] }
        var ports = Set<UInt16>()
        for descriptor in descriptors.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
            where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let count = withUnsafeMutablePointer(to: &socket) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard count == size, socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
        }
        return ports
    }

    private static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 2 * 1024 * 1024 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        let success = bytes.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard success == 0 else { return [] }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 4096 else { return [] }
        var position = MemoryLayout<Int32>.size
        while position < size && bytes[position] != 0 { position += 1 }
        while position < size && bytes[position] == 0 { position += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            let start = position
            while position < size && bytes[position] != 0 { position += 1 }
            guard position < size else { return [] }
            result.append(String(decoding: bytes[start..<position], as: UTF8.self))
            position += 1
        }
        return result
    }

    static func modelIdentifiers(_ arguments: [String]) -> Set<String> {
        var result = Set<String>()
        for (index, argument) in arguments.enumerated() {
            if ["--model", "-m", "--alias", "-a"].contains(argument), index + 1 < arguments.count {
                result.insert(arguments[index + 1])
            } else if argument.hasPrefix("--model=") || argument.hasPrefix("--alias=") {
                result.insert(String(argument.split(separator: "=", maxSplits: 1)[1]))
            }
        }
        return AIMerge.normalized(result)
    }
}
