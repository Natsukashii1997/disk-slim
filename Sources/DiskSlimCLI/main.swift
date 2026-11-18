import DiskSlimCore
import Foundation

let usage = """
用法：
  diskslim scan [--json]        只扫描，按区域和分组列出可清理项
  diskslim clean                预览：默认勾选的项会怎么处理（不执行）
  diskslim clean --yes          执行：移到废纸篓 / 删除可再生目录 / 运行清理命令，并记操作记录
  diskslim undo                 撤销最近一次：把移到废纸篓的东西放回原处
  diskslim growth               最近 7 天可用空间和谁涨了多少（只读每日记录，不扫描）
  diskslim memory               内存压力、谁占着、替你判断的三段（只读，不退出任何程序）
通用选项：
  --home <目录>  --work <目录>   换一个主目录 / 项目目录（自测用的沙盒）
"""

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> URL? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
}

let sandboxHome = option("--home")
let workRoot = option("--work")
// 只换项目目录、不换主目录时，下载文件夹和清理命令还是真实电脑上的：不允许这样半个沙盒
if workRoot != nil && sandboxHome == nil {
    FileHandle.standardError.write(Data("--work 要和 --home 一起用（只给 --work 时，下载文件夹和清理命令仍然作用在真实电脑上）\n".utf8))
    exit(2)
}
let home = sandboxHome ?? FileManager.default.homeDirectoryForCurrentUser
let scan = Scan(home: home, workRoot: workRoot)
// 指定了 --home 就是沙盒自测：不运行清理命令，它们会作用在真实电脑上
let cleaner = scan.cleaner(sandbox: sandboxHome != nil)
let riskLabel: [Risk: String] = [.safe: "安全", .confirm: "需确认", .readOnly: "只展示"]

func total(_ items: [Finding]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }

func method(_ c: Cleanup) -> String {
    switch c {
    case .trash: return "移到废纸篓（可撤销）"
    case .remove: return "直接删除（可再生，不能撤销）"
    case .command: return "运行清理命令（不能撤销）"
    case .none: return "不能清"
    }
}

switch args.first {
case "scan":
    let report = scan.run()
    if args.contains("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try enc.encode(report))
        print()
        break
    }
    if let d = report.disk {
        print("磁盘可用 \(formatBytes(d.availableBytes)) / 共 \(formatBytes(d.totalBytes))    扫描用时 \(String(format: "%.1f", report.seconds)) 秒")
    }
    for (area, name) in [(Area.downloads, "下载"), (Area.hidden, "看不见的")] {
        let items = report.findings.filter { $0.area == area }
        print("\n【\(name)】\(items.count) 项，共 \(formatBytes(total(items)))")
        var seen: [String] = []
        for f in items where !seen.contains(f.category) { seen.append(f.category) }
        for category in seen {
            let group = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
            print("  \(category) · \(formatBytes(total(group)))")
            for f in group {
                let size = formatBytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
                print("    \(f.suggested ? "✓" : " ") \(size) [\(riskLabel[f.risk]!)] \(f.title) — \(f.detail)")
            }
        }
    }
    print("\n默认勾选 \(report.findings.filter(\.suggested).count) 项，可腾出 \(formatBytes(report.suggestedBytes))。本命令只扫描，没有删除任何东西。")

case "clean":
    let picked = scan.run().findings.filter(\.suggested)
    if picked.isEmpty { print("没有默认勾选的项，不需要清理。"); break }
    let execute = args.contains("--yes")
    print(execute ? "执行：\(picked.count) 项" : "预览：默认勾选 \(picked.count) 项，共 \(formatBytes(total(picked)))")
    // 按清理方式分三组：废纸篓、直接删除、清理命令
    let groups: [(Cleanup, [Finding])] = [
        (.trash, picked.filter { $0.cleanup == .trash }),
        (.remove, picked.filter { $0.cleanup == .remove }),
        (.command([]), picked.filter { if case .command = $0.cleanup { return true } else { return false } }),
    ]
    for (c, group) in groups where !group.isEmpty {
        print("  \(method(c)) · \(group.count) 项 · \(formatBytes(total(group)))")
        for f in group.sorted(by: { $0.bytes > $1.bytes }) { print("    \(formatBytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(f.title)") }
    }
    if !execute { print("\n这是预览，没有执行。确认后加 --yes。"); break }
    let batch = cleaner.clean(picked)
    print("")
    for r in batch.items { print("  [\(r.outcome == .done ? "完成" : r.outcome == .skipped ? "跳过" : "失败")] \(r.title) — \(r.message)") }
    print("\n移到废纸篓 \(formatBytes(batch.trashedBytes))（清空废纸篓后才真正释放），已释放 \(formatBytes(batch.freedBytes))。")
    if let note = batch.note { print("注意：\(note)") }
    else { print("后悔了可以运行 diskslim undo，把这次移到废纸篓的东西放回原处。") }

case "undo":
    for line in cleaner.undoLast() { print(line) }

case "growth":
    let log = UsageLog.standard(home: home)
    let days = Usage.daily(log.load(readOnly: true), now: Date())
    if days.isEmpty {
        let exists = FileManager.default.fileExists(atPath: log.url.path)
        print(exists ? "记录文件读不出来或最近 7 天没有记录：\(log.url.path)" : "还没有记录。菜单栏应用每次扫描完会记一次，每天至少一次。")
        break
    }
    print("最近 7 天可用空间（每天最后一份记录，北京时间）：")
    for s in days { print("  \(BeijingTime.shortDay(s.at).padding(toLength: 6, withPad: " ", startingAt: 0)) \(formatBytes(s.freeBytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(BeijingTime.hourMinute(s.at)) 记录") }
    func ranking(_ list: [UsageChange]) {
        if list.isEmpty { print("  没有超过 50 MB 的变化") }
        for c in list { print("  \(formatDelta(c.delta).padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.name)") }
    }
    if let (new, old) = Usage.latestAndPrevious(days) {
        print("\n\(Usage.headline(days, now: Date()) ?? "")")
        print("谁涨了多少（\(BeijingTime.shortDay(old.at)) → \(BeijingTime.shortDay(new.at))）：")
        ranking(Usage.changes(from: old, to: new))
    } else {
        print("\n只有 1 天的记录，攒够两天才能比。")
    }
    if days.count > 2, let first = days.first, let last = days.last {
        print("\n近 7 天合计（\(BeijingTime.shortDay(first.at)) → \(BeijingTime.shortDay(last.at))）：\(Usage.freeChange(from: first, to: last))")
        ranking(Usage.changes(from: first, to: last))
    }
    print("\n本命令只读记录，不扫描、不删除。")

case "memory":
    // 「最后使用」只有菜单栏应用常驻时才记得到；这里只读 memory.json，不写
    let record = MemoryLog.standard(home: home).load(now: Date(), readOnly: true)
    let status = readMemoryStatus()
    let usage = MemoryAttribution.usage(listProcesses(), apps: RunningApps.current())
    let plan = MemoryPlan.make(usage: usage, status: status, record: record, now: Date())
    if let s = status {
        print("内存压力：\(s.level.label)（已用约 \(s.usedPercent)%），共 \(formatBytes(s.totalBytes))，交换文件 \(formatBytes(s.swapUsedBytes)) / \(formatBytes(s.swapTotalBytes))")
    }
    print("\n谁占着：")
    for t in plan.top { print("  \(formatBytes(t.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(t.name)") }
    print("\n替你挑好的（一键退出）：\(plan.picked.isEmpty ? "没有" : "")")
    for a in plan.picked {
        let h = Int(Date().timeIntervalSince(record.lastUsed(a.app)) / 3600)
        print("  \(formatBytes(a.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(a.app.name)（\(h) 小时没用）")
    }
    print("\n要你说一句：\(plan.asks.isEmpty ? "没有" : "")")
    for a in plan.asks {
        switch a {
        case .sessions(let keys, let bytes): print("  \(keys.count) 个 Claude 会话半天以上没动 · \(formatBytes(bytes))")
        case .browser(let b): print("  \(b.app.name) · \(formatBytes(b.bytes))")
        case .restart(let days, let swap): print("  \(days) 天没重启，交换文件 \(formatBytes(swap))")
        }
    }
    print("\n先不动：\(plan.keep.isEmpty ? "没有" : "")")
    for k in plan.keep { print("  \(formatBytes(k.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(k.name) · \(k.reason.rawValue)") }
    print("\n本命令只读，不退出任何程序。记录从 \(BeijingTime.monthDay(record.trackingSince)) \(BeijingTime.hourMinute(record.trackingSince)) 开始。")

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
