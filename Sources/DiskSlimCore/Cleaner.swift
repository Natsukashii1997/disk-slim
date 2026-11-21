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
    /// 清完一项追加一项（逐项落盘）
    public internal(set) var items: [ItemResult]
    /// 这一批里能放回的都放回了
    public var undone: Bool
    /// 已经放回原处的原路径；没放回的下次撤销还能再试
    public var restored: [String]?
    /// 操作记录没写成功等需要告诉用户的事；有它时不提供撤销
    public var note: String?
    /// 还在清（每清完一项落一次盘）。清完后去掉；一直为 true 说明那次清理中途断了（崩溃、被强退、断电），
    /// 已经移走的照样记着、能撤销
    public var unfinished: Bool? = nil

    public var trashedBytes: Int64 { items.reduce(0) { $0 + $1.trashedBytes } }
    public var freedBytes: Int64 { items.reduce(0) { $0 + $1.freedBytes } }

    /// 还在废纸篓里、可以放回的：原路径 → 废纸篓路径
    public var pending: [(String, String)] {
        let done = Set(restored ?? [])
        return items.flatMap { $0.trashed.map { ($0.key, $0.value) } }.filter { !done.contains($0.0) }.sorted { $0.0 < $1.0 }
    }
}

/// 操作记录存成一个 JSON 文件，只留最近 200 次。
public struct OperationLog {
    public let url: URL
    var file: RecordFile<[Batch]> { RecordFile(url: url) }
    static let keep = 200

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> OperationLog {
        OperationLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/history.json"))
    }

    /// 读不出来（文件坏了）时，先把坏文件改名留底再当作没有记录，下一次写入就不会把它覆盖掉（L-06）。
    /// 返回值的 `backup` 是留底文件的位置，没坏时为 nil；`unreadable` 表示文件在但读不了（权限、读错误），这时不能写。
    /// `readOnly` 为 true 时（扫描、查能不能撤销）坏文件不挪，只当没有记录。
    public func loadChecked(readOnly: Bool = false) -> (batches: [Batch], backup: URL?, unreadable: Bool) {
        let l = file.load(readOnly: readOnly)
        return (l.value ?? [], l.backup, l.unreadable)
    }

    public func load(readOnly: Bool = false) -> [Batch] { loadChecked(readOnly: readOnly).batches }

    /// 不加锁的整份写：调用方要先拿着 `withFileLock(url)`（撤销）
    public func save(_ batches: [Batch]) throws { try file.write(Array(batches.suffix(Self.keep))) }

    /// 加锁后把这一批写进记录：锁里重读最新内容，已有同 id 的原地替换，没有就追加到最后。
    /// 替换时保留记录里已经放回的（清理还没结束时，命令行可能已经撤销过这一批的一部分），不拿内存里的旧状态盖掉
    public func put(_ batch: Batch) throws {
        try file.update { latest in
            var all = latest.value ?? []
            if let i = all.firstIndex(where: { $0.id == batch.id }) {
                var merged = batch
                merged.restored = all[i].restored
                merged.undone = all[i].undone && merged.pending.isEmpty
                all[i] = merged
            } else {
                all.append(batch)
            }
            return Array(all.suffix(Self.keep))
        }
    }
}

// MARK: - 执行

public struct Cleaner {
    let safety: SafetyGuard
    let runner: CommandRunner
    let trasher: Trasher
    let log: OperationLog
    let sizeOf: (URL) -> Int64
    /// 执行前按规则再判一次（扫描和清理之间可能过了很久）；返回不清的原因，nil 表示照常清
    let recheck: (Finding) -> String?
    /// 沙盒自测时关掉：清理命令作用在真实电脑上，不受 --home 影响
    let allowCommands: Bool

    public init(safety: SafetyGuard, runner: CommandRunner = ProcessRunner(), trasher: Trasher = SystemTrasher(),
                log: OperationLog, sizeOf: @escaping (URL) -> Int64 = allocatedSize,
                recheck: @escaping (Finding) -> String? = { _ in nil }, allowCommands: Bool = true) {
        self.safety = safety
        self.runner = runner
        self.trasher = trasher
        self.log = log
        self.sizeOf = sizeOf
        self.recheck = recheck
        self.allowCommands = allowCommands
    }

    /// 逐项执行，每清完一项写一次操作记录。不允许的、已经不在的、正在使用的、复核不通过的都跳过，不会中断其他项。
    public func clean(_ findings: [Finding], now: Date = Date()) -> Batch {
        let (_, backup, unreadable) = log.loadChecked()
        // 操作记录在但读不了：清了也记不下来、会覆盖旧记录、也没法撤销，干脆一项都不清
        if unreadable {
            let items = findings.map { f in
                ItemResult(title: f.title, paths: f.paths, cleanup: f.cleanup, outcome: .skipped,
                           message: "操作记录读不了，为了能撤销这次没有清理", trashedBytes: 0, freedBytes: 0, trashed: [:])
            }
            return Batch(id: UUID().uuidString, at: now, items: items, undone: false, restored: [],
                         note: "操作记录 \(log.url.lastPathComponent) 在但读不了（权限或读错误），这次没有清理任何东西")
        }
        clearStaging()
        let processes = runner.run(["ps", "-axo", "command"], cwd: nil).output
        let openPaths = findings.contains { $0.cleanup == .remove } ? WorktreeScanner.openPaths(runner) : []
        // 逐项落盘：先记一条「进行中」，每清完一项写一次，最后去掉「进行中」。
        // 中途崩溃、被强退、断电时，已经移到废纸篓的也记着、能撤销。每次都在锁里重读再替换，不覆盖别的进程同时写的记录。
        var batch = Batch(id: UUID().uuidString, at: now, items: [], undone: false, restored: [], note: nil, unfinished: true)
        var saveError: Error?
        /// 最近一次成功落盘时记下了几项（nil：一次都没写成）
        var savedItems: Int?
        func persist() {
            do { try log.put(batch); saveError = nil; savedItems = batch.items.count } catch { saveError = error }
        }
        persist()
        for f in findings {
            batch.items.append(clean(f, processes: processes, openPaths: openPaths))
            persist()
        }
        batch.unfinished = nil
        persist()
        var notes: [String] = []
        if let backup { notes.append("原来的操作记录读不出来，已另存为 \(backup.lastPathComponent)") }
        if let saveError {
            if let n = savedItems, n > 0 {
                notes.append("操作记录只记下了前 \(n) 项（\(saveError.localizedDescription)），撤销只能放回这几项里移走的，其余请到废纸篓里找")
            } else {
                notes.append("操作记录没保存成功（\(saveError.localizedDescription)），这次不能用撤销，移走的文件请到废纸篓里找")
            }
        }
        batch.note = notes.isEmpty ? nil : notes.joined(separator: "；")
        return batch
    }

    /// 直接删除前先改名挪到这里（同一个卷，改名是瞬间的），再慢慢删；上次没删完的下次清理时补删
    var staging: URL { log.url.deletingLastPathComponent().appendingPathComponent("deleting") }

    /// 暂存目录和它的上一层都不是符号链接、确实是目录（或还不存在）才用；否则不暂存、原地删，也不补删
    var stagingUsable: Bool {
        [staging, staging.deletingLastPathComponent()].allSatisfy { u in
            var st = stat()
            if lstat(u.path, &st) != 0 { return errno == ENOENT }
            return (st.st_mode & S_IFMT) == S_IFDIR
        }
    }

    /// 补删上次没删完的：只删名字是 UUID、而且放了一小时以上的（别的进程可能正在删刚放进来的）
    func clearStaging(now: Date = Date()) {
        guard stagingUsable else { return }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: staging.path)) ?? [] where UUID(uuidString: name) != nil {
            let u = staging.appendingPathComponent(name)
            let mtime = (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? now
            if now.timeIntervalSince(mtime) >= 3600 { try? fm.removeItem(at: u) }
        }
    }

    private func clean(_ f: Finding, processes: String, openPaths: [String]) -> ItemResult {
        func result(_ outcome: Outcome, _ message: String, trashedBytes: Int64 = 0, freedBytes: Int64 = 0,
                    trashed: [String: String] = [:]) -> ItemResult {
            ItemResult(title: f.title, paths: f.paths, cleanup: f.cleanup, outcome: outcome, message: message,
                       trashedBytes: trashedBytes, freedBytes: freedBytes, trashed: trashed)
        }

        if let reason = safety.refusal(for: f) { return result(.failed, "拒绝执行：\(reason)") }
        if let reason = recheck(f) { return result(.skipped, reason) }
        let lines = processes.split(separator: "\n")
        let markers = safety.busyMarkers(for: f)
        if !markers.isEmpty, lines.contains(where: { line in markers.contains { $0.running(in: line) } }) {
            return result(.skipped, "相关程序正在运行，这次先不清")
        }
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
                return lines.contains { line in paths.contains { line.contains($0) } }
                    || openPaths.contains { p in paths.contains { p == $0 || p.hasPrefix($0 + "/") } }
            }
            if busy { return result(.skipped, "有程序正在使用，这次先不删") }
            var bytes: Int64 = 0
            for u in existing {
                let size = sizeOf(u)
                // 拿住 cargo 的锁再挪走：这期间开始的编译会等一下，不会往里写；拿不到就是正在编译
                guard let locks = WorktreeScanner.holdCargoLocks(u) else {
                    return result(.skipped, "正在编译，这次先不删", freedBytes: bytes)
                }
                // 只用 rename(2)：同卷瞬间完成；跨卷（EXDEV）或暂存目录不可用时不复制，改为持锁原地删
                let staged = staging.appendingPathComponent(UUID().uuidString)
                let moved = stagingUsable
                    && (try? fm.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
                    && stagingUsable
                    && rename(u.path, staged.path) == 0
                if moved { WorktreeScanner.release(locks) }
                defer { if !moved { WorktreeScanner.release(locks) } }
                do {
                    try fm.removeItem(at: moved ? staged : u)
                    bytes += size
                } catch {
                    let left = moved ? "（已挪进 \(staging.path)，下次清理时再补删）" : ""
                    return result(.failed, "删除失败：\(u.lastPathComponent)\(left)", freedBytes: bytes)
                }
            }
            return result(.done, "已删除（可再生，不能撤销）", freedBytes: bytes)

        case .command(let args):
            if !allowCommands { return result(.skipped, "沙盒模式不运行清理命令（它会作用在真实电脑上）") }
            let before = urls.reduce(Int64(0)) { $0 + sizeOf($1) }
            let r = runner.run(args, cwd: nil)
            let after = urls.reduce(Int64(0)) { $0 + (fm.fileExists(atPath: $1.path) ? sizeOf($1) : 0) }
            if r.status == 127 { return result(.skipped, "没装 \(args[0])，跳过") }
            if r.status == 124 { return result(.failed, "`\(args.joined(separator: " "))` 超时，已停止", freedBytes: max(0, before - after)) }
            if r.status != 0 { return result(.failed, "`\(args.joined(separator: " "))` 退出码 \(r.status)", freedBytes: max(0, before - after)) }
            return result(.done, "已运行 `\(args.joined(separator: " "))`", freedBytes: max(0, before - after))

        case .none:
            return result(.failed, "这一项没有清理方式")
        }
    }

    /// 撤销结果里「放回成功」那几行的开头；应用靠它数放回了几项
    public static let restoredPrefix = "已放回"

    /// 还有没有能放回的（应用里常驻「撤销上一次」用）
    public func canUndo() -> Bool { log.load(readOnly: true).contains { !$0.undone && !$0.pending.isEmpty } }

    /// 撤销：从最近一次往前，找第一批还没撤销完、而且有文件可放回的，把还在废纸篓里的放回原处（可以一次次往前撤）。
    /// 放不回的（原位置有同名文件）下次还能再试；全部放回后这一批才算撤销完。
    /// 直接删除和清理命令无法撤销，会在结果里说明。
    public func undoLast() -> [String] { withFileLock(log.url) { undoLastLocked() } }

    private func undoLastLocked() -> [String] {
        var all = log.load()
        // 跳过没有可放回文件的批次（什么都没清掉、或只有清理命令和直接删除的）
        guard let i = all.lastIndex(where: { !$0.undone && !$0.pending.isEmpty }) else {
            return ["没有可以撤销的操作（清理命令和直接删除的放不回去）"]
        }
        let fm = FileManager.default
        var lines: [String] = []
        for item in all[i].items where item.outcome == .done && item.trashed.isEmpty {
            lines.append("不能撤销：\(item.title)，直接删除和清理命令放不回去")
        }
        var restored = all[i].restored ?? []
        for (orig, inTrash) in all[i].pending {
            let name = URL(fileURLWithPath: orig).lastPathComponent
            if fm.fileExists(atPath: orig) && !fm.fileExists(atPath: inTrash) {
                // 用户已经在访达里放回原处了
                lines.append("已在原处：\(name)")
                restored.append(orig)
            } else if fm.fileExists(atPath: orig) {
                lines.append("没有放回：\(name)（原位置已有同名文件，挪开后可以再撤销）")
            } else if !fm.fileExists(atPath: inTrash) {
                lines.append("没有放回：\(name)（废纸篓里找不到了，可能已清空）")
                restored.append(orig) // 再试也没用
            } else {
                do {
                    try fm.createDirectory(at: URL(fileURLWithPath: orig).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(atPath: inTrash, toPath: orig)
                    lines.append("\(Self.restoredPrefix)：\(name)")
                    restored.append(orig)
                } catch {
                    lines.append("没有放回：\(name)（\(error.localizedDescription)）")
                }
            }
        }
        all[i].restored = restored
        all[i].undone = all[i].pending.isEmpty
        do {
            try log.save(all)
        } catch {
            lines.append("撤销结果没写进操作记录（\(error.localizedDescription)）")
        }
        return lines.isEmpty ? ["这次操作没有可以放回的文件"] : lines
    }
}
