import Foundation

/// 每周卡片（docs/PRD.md 3.3）：一张卡是一件要用户决定的事，只问首页「要你说一句」里能执行的那些
/// （2026-11-18 起，issue #4）：下载文件夹里每个分组一张，其余每项一张。
/// 替你挑好的（首页一键清）、先不动的、对话记录都不进卡片。
public struct WeeklyCard: Identifiable {
    public let id: String
    public let tag: String
    public let title: String
    public let why: String
    public let findings: [Finding]

    public init(id: String, tag: String, title: String, why: String, findings: [Finding]) {
        self.id = id
        self.tag = tag
        self.title = title
        self.why = why
        self.findings = findings
    }

    public var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
    public var paths: [String] { findings.flatMap(\.paths) }
    /// 全是移到废纸篓的写「移到废纸篓」，否则写「清理」
    public var actionLabel: String { findings.allSatisfy { $0.cleanup == .trash } ? "移到废纸篓" : "清理" }
}

public enum Weekly {
    static let beijing: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 每张卡为什么能删（下载分组）
    static let downloadsWhy: [String: String] = [
        Category.installer: "装好之后安装包就没用了，要重装再去官网下。",
        Category.extractedArchive: "旁边已经有解压好的文件夹，压缩包留着是重复占空间。",
        Category.staleDownload: "很久没打开过了。确认用不上再移走，移到废纸篓后还能放回。",
    ]

    /// 这次扫描里还要问的卡片，大的在前
    /// `includeSnoozed` 为 true 时连「下周再问」的也算（首页「要你说一句」一直列着，只是周报不催）
    public static func cards(_ findings: [Finding], decisions: Decisions, now: Date, includeSnoozed: Bool = false) -> [WeeklyCard] {
        let open = findings.filter { f in
            f.cleanup.runnable && f.bucket(now: now, kept: decisions.isKept(f)) == .ask && (includeSnoozed || !decisions.isSnoozed(f, now: now))
        }
        var cards: [WeeklyCard] = []
        let downloads = open.filter { $0.area == .downloads }
        for category in Set(downloads.map(\.category)) {
            let items = downloads.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
            cards.append(WeeklyCard(id: "downloads|" + category, tag: category,
                                    title: "下载文件夹里 \(items.count) 个\(category == Category.staleDownload ? "很久没打开的文件" : category)",
                                    why: downloadsWhy[category] ?? items[0].detail, findings: items))
        }
        for f in open where f.area == .hidden {
            cards.append(WeeklyCard(id: f.id, tag: f.category, title: f.title, why: f.detail, findings: [f]))
        }
        return cards.sorted { $0.bytes > $1.bytes }
    }

    /// 最近一次已经到点的周报时间（北京时间周五 18:00，可以是 now 本身）
    public static func lastReport(atOrBefore now: Date) -> Date {
        let next = nextReport(after: now)
        return beijing.date(byAdding: .day, value: -7, to: next)!
    }

    /// now 之后的下一次周报时间（严格晚于 now）
    public static func nextReport(after now: Date) -> Date {
        beijing.nextDate(after: now, matching: DateComponents(hour: 18, minute: 0, second: 0, weekday: 6),
                         matchingPolicy: .nextTime)!
    }
}
