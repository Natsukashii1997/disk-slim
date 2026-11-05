import Foundation

/// 每周卡片（docs/PRD.md 3.3）：一张卡是一件要用户决定的事。
/// 下载文件夹里能清的每个分组一张；「要你决定的」（备份、虚拟机等需确认、能清的项）每项一张。
/// 对话记录（只展示）、缓存（首页一键清）不进卡片。
public struct WeeklyCard: Identifiable {
    public let id: String
    public let tag: String
    public let title: String
    public let why: String
    public let findings: [Finding]

    public var bytes: Int64 { findings.reduce(0) { $0 + $1.bytes } }
    public var paths: [String] { findings.flatMap(\.paths) }
    /// 全是移到废纸篓的写「移到废纸篓」，否则写「清理」
    public var actionLabel: String { findings.allSatisfy { $0.cleanup == .trash } ? "移到废纸篓" : "清理" }
}

/// 用户在卡片上做的决定，存在 decisions.json。
public struct Decisions: Codable, Equatable {
    /// 「保留」：路径 → 什么时候决定的。以后不再问，也不再默认勾选
    public var kept: [String: Date] = [:]
    /// 「下周再问」：路径 → 到这个时间之前不问
    public var snoozed: [String: Date] = [:]

    public init(kept: [String: Date] = [:], snoozed: [String: Date] = [:]) {
        self.kept = kept
        self.snoozed = snoozed
    }

    public mutating func keep(_ card: WeeklyCard, now: Date) {
        for p in card.paths { kept[p] = now; snoozed[p] = nil }
    }

    public mutating func snooze(_ card: WeeklyCard, now: Date) {
        let until = Weekly.nextReport(after: now)
        for p in card.paths { snoozed[p] = until }
    }

    public func isKept(_ f: Finding) -> Bool { !f.paths.isEmpty && f.paths.allSatisfy { kept[$0] != nil } }
    func isSnoozed(_ f: Finding, now: Date) -> Bool { !f.paths.isEmpty && f.paths.allSatisfy { (snoozed[$0] ?? .distantPast) > now } }
}

public struct DecisionLog {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> DecisionLog {
        DecisionLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/decisions.json"))
    }

    /// 没有文件或读不出来都当没有决定（最坏是多问一次，不会多删）
    public func load() -> Decisions {
        guard let data = try? Data(contentsOf: url) else { return Decisions() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? d.decode(Decisions.self, from: data)) ?? Decisions()
    }

    public func save(_ decisions: Decisions) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(decisions).write(to: url, options: .atomic)
    }
}

/// 选过「保留」的项不再默认勾选（首页「清理建议项」不会把它清掉），说明里写明
public func applyDecisions(_ findings: [Finding], _ decisions: Decisions) -> [Finding] {
    findings.map { f in
        guard f.suggested, decisions.isKept(f) else { return f }
        return Finding(area: f.area, category: f.category, title: f.title, detail: "你选过保留 · " + f.detail,
                       paths: f.paths, bytes: f.bytes, risk: f.risk, suggested: false, cleanup: f.cleanup)
    }
}

public enum Weekly {
    static let beijing: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// 每张卡为什么能删（下载分组）
    static let downloadsWhy: [String: String] = [
        "安装包": "装好之后安装包就没用了，要重装再去官网下。",
        "已解压的压缩包": "旁边已经有解压好的文件夹，压缩包留着是重复占空间。",
        "久未打开": "很久没打开过了。确认用不上再移走，移到废纸篓后还能放回。",
    ]

    /// 这次扫描里还要问的卡片，大的在前
    public static func cards(_ findings: [Finding], decisions: Decisions, now: Date) -> [WeeklyCard] {
        let open = findings.filter { f in
            f.risk != .readOnly && f.cleanup != .none && !decisions.isKept(f) && !decisions.isSnoozed(f, now: now)
        }
        var cards: [WeeklyCard] = []
        let downloads = open.filter { $0.area == .downloads }
        for category in Set(downloads.map(\.category)) {
            let items = downloads.filter { $0.category == category }.sorted { $0.bytes > $1.bytes }
            cards.append(WeeklyCard(id: "downloads|" + category, tag: category,
                                    title: "下载文件夹里 \(items.count) 个\(category == "久未打开" ? "很久没打开的文件" : category)",
                                    why: downloadsWhy[category] ?? items[0].detail, findings: items))
        }
        for f in open where f.area == .hidden && f.risk == .confirm {
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
