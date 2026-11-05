import Foundation

// MARK: - 废纸篓

/// 移到废纸篓，返回它在废纸篓里的位置（撤销时用）。测试里换成假的，免得弄脏真实的废纸篓。
public protocol Trasher {
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrasher: Trasher {
    public init() {}
    public func trash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return (result as URL?) ?? url
    }
}

// MARK: - 操作记录

public enum Outcome: String, Codable {
    case done
    case skipped
    case failed
}

public struct ItemResult: Codable {
    public let title: String
    public let paths: [String]
    public let cleanup: Cleanup
    public let outcome: Outcome
    public let message: String
    /// 移到废纸篓的大小（清空废纸篓后才释放）
    public let trashedBytes: Int64
    /// 已经真正释放的大小（直接删除、清理命令）
    public let freedBytes: Int64
    /// 原路径 → 废纸篓里的路径
    public let trashed: [String: String]
}

public struct Batch: Codable {
    public let id: String
    public let at: Date
    public let items: [ItemResult]
    public var undone: Bool

    public var trashedBytes: Int64 { items.reduce(0) { $0 + $1.trashedBytes } }
    public var freedBytes: Int64 { items.reduce(0) { $0 + $1.freedBytes } }
}

/// 操作记录存成一个 JSON 文件，只留最近 200 次。
public struct OperationLog {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> OperationLog {
        OperationLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/history.json"))
    }

    public func load() -> [Batch] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([Batch].self, from: data)) ?? []
    }

    public func save(_ batches: [Batch]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(Array(batches.suffix(200))).write(to: url, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - 执行

public struct Cleaner {
    let safety: SafetyGuard
    let runner: CommandRunner
    let trasher: Trasher
    let log: OperationLog
    let sizeOf: (URL) -> Int64

    public init(safety: SafetyGuard, runner: CommandRunner = ProcessRunner(), trasher: Trasher = SystemTrasher(),
                log: OperationLog, sizeOf: @escaping (URL) -> Int64 = allocatedSize) {
        self.safety = safety
        self.runner = runner
        self.trasher = trasher
        self.log = log
        self.sizeOf = sizeOf
    }

    /// 逐项执行并记一次操作记录。不允许的、已经不在的、正在使用的都跳过，不会中断其他项。
    public func clean(_ findings: [Finding], now: Date = Date()) -> Batch {
        let processes = runner.run(["ps", "-axo", "command"], cwd: nil).output
        let items = findings.map { clean($0, processes: processes) }
        let batch = Batch(id: UUID().uuidString, at: now, items: items, undone: false)
        var all = log.load()
        all.append(batch)
        try? log.save(all)
        return batch
    }

    private func clean(_ f: Finding, processes: String) -> ItemResult {
        func result(_ outcome: Outcome, _ message: String, trashedBytes: Int64 = 0, freedBytes: Int64 = 0,
                    trashed: [String: String] = [:]) -> ItemResult {
            ItemResult(title: f.title, paths: f.paths, cleanup: f.cleanup, outcome: outcome, message: message,
                       trashedBytes: trashedBytes, freedBytes: freedBytes, trashed: trashed)
        }

        if let reason = safety.refusal(for: f) { return result(.failed, "拒绝执行：\(reason)") }
        let fm = FileManager.default
        let urls = f.paths.map { URL(fileURLWithPath: $0) }

        switch f.cleanup {
        case .trash:
            var moved: [String: String] = [:], bytes: Int64 = 0, errors: [String] = []
            for u in urls where fm.fileExists(atPath: u.path) {
                let size = sizeOf(u)
                do {
                    moved[u.path] = try trasher.trash(u).path
                    bytes += size
                } catch {
                    errors.append(u.lastPathComponent)
                }
            }
            if moved.isEmpty && errors.isEmpty { return result(.skipped, "已经不在了") }
            if !errors.isEmpty { return result(.failed, "有 \(errors.count) 个没能移到废纸篓：\(errors.joined(separator: "、"))", trashedBytes: bytes, trashed: moved) }
            return result(.done, "已移到废纸篓", trashedBytes: bytes, trashed: moved)

        case .remove:
            let existing = urls.filter { fm.fileExists(atPath: $0.path) }
            if existing.isEmpty { return result(.skipped, "已经不在了") }
            let busy = existing.contains { u in
                let paths = [u.path, u.resolvingSymlinksInPath().path]
                return processes.split(separator: "\n").contains { line in paths.contains { line.contains($0) } }
            }
            if busy { return result(.skipped, "有程序正在使用，这次先不删") }
            var bytes: Int64 = 0
            for u in existing {
                let size = sizeOf(u)
                do {
                    try fm.removeItem(at: u)
                    bytes += size
                } catch {
                    return result(.failed, "删除失败：\(u.lastPathComponent)", freedBytes: bytes)
                }
            }
            return result(.done, "已删除（可再生，不能撤销）", freedBytes: bytes)

        case .command(let args):
            let before = urls.reduce(Int64(0)) { $0 + sizeOf($1) }
            let r = runner.run(args, cwd: nil)
            let after = urls.reduce(Int64(0)) { $0 + (fm.fileExists(atPath: $1.path) ? sizeOf($1) : 0) }
            if r.status == 127 { return result(.skipped, "没装 \(args[0])，跳过") }
            if r.status != 0 { return result(.failed, "`\(args.joined(separator: " "))` 退出码 \(r.status)", freedBytes: max(0, before - after)) }
            return result(.done, "已运行 `\(args.joined(separator: " "))`", freedBytes: max(0, before - after))

        case .none:
            return result(.failed, "这一项没有清理方式")
        }
    }

    /// 撤销最近一次还没撤销过的操作：把移到废纸篓的放回原处。直接删除和清理命令无法撤销，会在结果里说明。
    public func undoLast() -> [String] {
        var all = log.load()
        guard let i = all.lastIndex(where: { !$0.undone }) else { return ["没有可以撤销的操作"] }
        let fm = FileManager.default
        var lines: [String] = []
        for item in all[i].items where item.outcome != .skipped {
            if item.trashed.isEmpty {
                if item.outcome == .done { lines.append("不能撤销：\(item.title)，直接删除和清理命令放不回去") }
                continue
            }
            for (orig, inTrash) in item.trashed.sorted(by: { $0.key < $1.key }) {
                let name = URL(fileURLWithPath: orig).lastPathComponent
                if fm.fileExists(atPath: orig) {
                    lines.append("没有放回：\(name)（原位置已有同名文件）")
                } else if !fm.fileExists(atPath: inTrash) {
                    lines.append("没有放回：\(name)（废纸篓里找不到了，可能已清空）")
                } else {
                    do {
                        try fm.createDirectory(at: URL(fileURLWithPath: orig).deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.moveItem(atPath: inTrash, toPath: orig)
                        lines.append("已放回：\(name)")
                    } catch {
                        lines.append("没有放回：\(name)（\(error.localizedDescription)）")
                    }
                }
            }
        }
        all[i].undone = true
        try? log.save(all)
        return lines.isEmpty ? ["这次操作没有可以放回的文件"] : lines
    }
}
