import DiskSlimCore
import Foundation

// 用法：
//   diskslim scan          按区域、分组列出可清理项（只读，不删任何东西）
//   diskslim scan --json   输出 JSON，给测试和对账用

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "scan" else {
    print("用法：diskslim scan [--json]\n只扫描并列出可清理项，不删除任何东西。")
    exit(args.isEmpty ? 0 : 2)
}

let report = Scan().run()

if args.contains("--json") {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try enc.encode(report))
    print()
    exit(0)
}

let riskLabel: [Risk: String] = [.safe: "安全", .confirm: "需确认", .readOnly: "只展示"]

if let d = report.disk {
    print("磁盘可用 \(formatBytes(d.availableBytes)) / 共 \(formatBytes(d.totalBytes))    扫描用时 \(String(format: "%.1f", report.seconds)) 秒")
}

for (area, name) in [(Area.downloads, "下载"), (Area.hidden, "看不见的")] {
    let items = report.findings.filter { $0.area == area }
    print("\n【\(name)】\(items.count) 项，共 \(formatBytes(items.reduce(0) { $0 + $1.bytes }))")
    var seen: [String] = []
    for f in items where !seen.contains(f.category) { seen.append(f.category) }
    for category in seen {
        let group = items.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
        print("  \(category) · \(formatBytes(group.reduce(0) { $0 + $1.bytes }))")
        for f in group {
            let mark = f.suggested ? "✓" : " "
            let size = formatBytes(f.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)
            print("    \(mark) \(size) [\(riskLabel[f.risk]!)] \(f.title) — \(f.detail)")
        }
    }
}

let picked = report.findings.filter(\.suggested)
print("\n默认勾选 \(picked.count) 项，可腾出 \(formatBytes(report.suggestedBytes))。本命令只扫描，没有删除任何东西。")
