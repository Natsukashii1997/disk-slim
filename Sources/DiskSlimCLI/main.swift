import DiskSlimCore
import Foundation

let usage = """
用法：
  diskslim scan [--json]        只扫描，按区域和分组列出可清理项
  diskslim clean                预览：默认勾选的项会怎么处理（不执行）
  diskslim clean --yes          执行：移到废纸篓 / 删除可再生目录 / 运行清理命令，并记操作记录
  diskslim undo                 撤销最近一次：把移到废纸篓的东西放回原处
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

let home = option("--home") ?? FileManager.default.homeDirectoryForCurrentUser
let scan = Scan(home: home, workRoot: option("--work"))
let cleaner = Cleaner(safety: SafetyGuard(home: scan.home, workRoot: scan.workRoot), log: .standard(home: home))
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
    print("后悔了可以运行 diskslim undo，把这次移到废纸篓的东西放回原处。")

case "undo":
    for line in cleaner.undoLast() { print(line) }

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
