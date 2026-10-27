import Foundation
import Darwin

struct AILogRecord {
    var id: String
    var text: String
    var date: Date
    /// Timestamp-less backlog can restore state but cannot honestly fill minute buckets.
    var canChart: Bool
    var sourceIdentity: String? = nil
    var continuityBreak = false
}

struct AILogRead {
    var records: [AILogRecord] = []
    var status: AIInstanceStatus = .monitoring
    var modifiedAt: Date?
    var bytesRead = 0
}

/// File identities survive a rename; offsets reset after replacement or copytruncate.
/// Work is bounded even when a configured directory contains gigabytes of rotations.
final class AILogTailer {
    private struct Cursor {
        var offset: UInt64 = 0
        var pending = Data()
        var prefix = Data()
        var modifiedAt: Date?
        var checkpoint = Data()
        var generation = 0
    }
    private var cursors: [String: Cursor] = [:]
    static let maximumBytesPerPoll = 2 * 1024 * 1024
    static let maximumBytesPerFile = 512 * 1024
    static let maximumFiles = 16
    private static let maximumLineBytes = 32 * 1024

    func read(directory: String, pattern: String, now: Date) -> AILogRead {
        var result = AILogRead()
        let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let directoryURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let fileManager = FileManager.default
        guard !pattern.isEmpty, !pattern.contains("/"), pattern != ".", pattern != ".." else {
            result.status = .missingLogs
            return result
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        } catch {
            result.status = fileManager.fileExists(atPath: directoryURL.path) ? .unreadable : .missingLogs
            return result
        }
        let files = urls.compactMap { url -> (URL, Date, UInt64, String)? in
            guard fnmatch(pattern, url.lastPathComponent, 0) == 0,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber else { return nil }
            return (url, values.contentModificationDate ?? now, UInt64(values.fileSize ?? 0), "\(device):\(inode)")
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 < $1.1 }
        guard !files.isEmpty else { result.status = .missingLogs; return result }
        let selected = Array(files.suffix(Self.maximumFiles))
        let liveIDs = Set(selected.map { $0.3 })
        cursors = cursors.filter { liveIDs.contains($0.key) }
        var hadReadableFile = false
        var hadUnreadableFile = false
        // Prioritise the newest source when a large backlog exhausts the budget.
        var batches: [(Date, [AILogRecord])] = []
        for (url, modified, size, identity) in selected.reversed() {
            result.modifiedAt = max(result.modifiedAt ?? modified, modified)
            guard result.bytesRead < Self.maximumBytesPerPoll else { continue }
            var cursor = cursors[identity] ?? Cursor()
            guard fileManager.isReadableFile(atPath: url.path) else { hadUnreadableFile = true; continue }
            if cursor.modifiedAt == modified && cursor.offset == size {
                hadReadableFile = true
                continue
            }
            let handle: FileHandle
            do { handle = try FileHandle(forReadingFrom: url) }
            catch { hadUnreadableFile = true; continue }
            defer { try? handle.close() }
            hadReadableFile = true
            do {
                let prefix = try handle.read(upToCount: min(256, Self.maximumBytesPerPoll - result.bytesRead)) ?? Data()
                result.bytesRead += prefix.count
                var checkpointChanged = false
                if cursor.offset <= size, !cursor.checkpoint.isEmpty,
                   result.bytesRead + cursor.checkpoint.count <= Self.maximumBytesPerPoll {
                    try handle.seek(toOffset: cursor.offset - UInt64(cursor.checkpoint.count))
                    let checkpoint = try handle.read(upToCount: cursor.checkpoint.count) ?? Data()
                    result.bytesRead += checkpoint.count
                    checkpointChanged = checkpoint != cursor.checkpoint
                }
                let replaced = cursor.offset > size || checkpointChanged || (!cursor.prefix.isEmpty
                    && !prefix.starts(with: cursor.prefix))
                if replaced {
                    cursor.offset = 0
                    cursor.pending.removeAll(keepingCapacity: true)
                    cursor.generation += 1
                }
                let firstRead = cursor.offset == 0
                let allowance = min(Self.maximumBytesPerFile, Self.maximumBytesPerPoll - result.bytesRead)
                guard allowance > 0 else { continue }
                var ranges: [(UInt64, Int, Bool)] = []
                if firstRead && size > UInt64(allowance) {
                    let headSize = min(64 * 1024, allowance / 4)
                    ranges.append((0, headSize, false))
                    ranges.append((size - UInt64(allowance - headSize), allowance - headSize, true))
                } else {
                    // A writer faster than our budget must not starve the other collectors.
                    let start = max(cursor.offset, size > UInt64(allowance) ? size - UInt64(allowance) : 0)
                    ranges.append((start, Int(min(UInt64(allowance), size - start)), start > cursor.offset))
                }
                var records: [AILogRecord] = []
                for (offset, count, skipsPartialFirstLine) in ranges {
                    try handle.seek(toOffset: offset)
                    let data = try handle.read(upToCount: count) ?? Data()
                    result.bytesRead += data.count
                    var combined = skipsPartialFirstLine || offset == 0 ? Data() : cursor.pending
                    let pendingCount = combined.count
                    combined.append(data)
                    var start = combined.startIndex
                    var breaksContinuity = skipsPartialFirstLine
                    if skipsPartialFirstLine {
                        guard let newline = combined.firstIndex(of: 10) else { continue }
                        start = newline + 1
                    }
                    while start < combined.endIndex, let newline = combined[start...].firstIndex(of: 10) {
                        let length = newline - start
                        if length <= Self.maximumLineBytes {
                            let line = String(decoding: combined[start..<newline], as: UTF8.self)
                            let lineOffset = Int64(offset) - Int64(pendingCount) + Int64(start)
                            let explicit = Self.timestamp(in: line)
                            let sourceID = "\(identity):\(cursor.generation):\(lineOffset)"
                            let eventID = explicit.map { _ in Self.timestampedID(line) } ?? sourceID
                            records.append(AILogRecord(id: eventID,
                                text: line, date: explicit ?? (firstRead ? modified : now),
                                canChart: explicit != nil || !firstRead, sourceIdentity: identity,
                                continuityBreak: breaksContinuity))
                            breaksContinuity = false
                        }
                        start = newline + 1
                    }
                    cursor.pending = combined.count - start <= Self.maximumLineBytes ? Data(combined[start...]) : Data()
                    cursor.offset = offset + UInt64(data.count)
                }
                let checkpointSize = min(128, Int(cursor.offset))
                if checkpointSize > 0, result.bytesRead + checkpointSize <= Self.maximumBytesPerPoll {
                    try handle.seek(toOffset: cursor.offset - UInt64(checkpointSize))
                    cursor.checkpoint = try handle.read(upToCount: checkpointSize) ?? Data()
                    result.bytesRead += cursor.checkpoint.count
                } else { cursor.checkpoint.removeAll() }
                cursor.prefix = prefix
                cursor.modifiedAt = modified
                cursors[identity] = cursor
                batches.append((modified, records))
            } catch {
                hadUnreadableFile = true
            }
        }
        result.records = batches.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
        if !hadReadableFile || hadUnreadableFile { result.status = .unreadable }
        return result
    }

    private static func timestampedID(_ line: String) -> String {
        // A copytruncate rotation creates a new inode containing the same dated
        // events; a content identity prevents those events entering history twice.
        let hash = line.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return "dated:\(hash)"
    }

    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"(?:time=|^\[?)(\d{4}-\d{2}-\d{2}[T ][0-9:.]+(?:Z|[+-]\d{2}:?\d{2})?)"#)
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let formatter = ISO8601DateFormatter()
    static func timestamp(in line: String) -> Date? {
        guard let match = timestampExpression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let value = String(line[range]).replacingOccurrences(of: " ", with: "T")
        return fractionalFormatter.date(from: value) ?? formatter.date(from: value)
    }
}
