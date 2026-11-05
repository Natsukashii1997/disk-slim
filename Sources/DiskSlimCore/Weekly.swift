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

/// 选「保留」时这一项多大：以后涨了超过 1 GB 就再问
public struct Kept: Codable, Equatable {
    public let at: Date
    public let bytes: Int64

    public init(at: Date, bytes: Int64) {
        self.at = at
        self.bytes = bytes
    }
}

/// 用户在卡片上做的决定，存在 decisions.json。按路径记（`Finding.pathKey`），同一个文件换了分组也认得；
/// 旧版按「分组 + 路径」（`Finding.id`）记的照样认。
public struct Decisions: Codable, Equatable {
    /// 「保留」：以后不再问，也不再默认勾选；涨了超过 `regrowBytes` 就作废、重新问
    public var kept: [String: Kept] = [:]
    /// 「下周再问」：到这个时间之前不问
    public var snoozed: [String: Date] = [:]

    public static let regrowBytes: Int64 = 1_073_741_824

    public init(kept: [String: Kept] = [:], snoozed: [String: Date] = [:]) {
        self.kept = kept
        self.snoozed = snoozed
    }

    /// 宽松地读：缺字段、某一条坏了只丢那一条，不把所有「保留」一起丢掉（丢了会被重新默认勾选）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kept = ((try? c.decodeIfPresent([String: Lenient<Kept>].self, forKey: .kept)) ?? nil)?.compactMapValues(\.value) ?? [:]
        snoozed = ((try? c.decodeIfPresent([String: Lenient<Date>].self, forKey: .snoozed)) ?? nil)?.compactMapValues(\.value) ?? [:]
    }

    public mutating func keep(_ card: WeeklyCard, now: Date) {
        for f in card.findings { kept[f.pathKey] = Kept(at: now, bytes: f.bytes); snoozed[f.pathKey] = nil; snoozed[f.id] = nil }
    }

    /// 到下一次周报再问；周五 18:00 前点的跳过当天这次，到下周五
    public mutating func snooze(_ card: WeeklyCard, now: Date) {
        var until = Weekly.nextReport(after: now)
        if BeijingTime.dayNumber(until) == BeijingTime.dayNumber(now) { until = Weekly.nextReport(after: until) }
        for f in card.findings { snoozed[f.pathKey] = until }
    }

    public func isKept(_ f: Finding) -> Bool {
        guard let k = kept[f.pathKey] ?? kept[f.id] else { return false }
        return f.bytes - k.bytes <= Self.regrowBytes
    }

    func isSnoozed(_ f: Finding, now: Date) -> Bool { (snoozed[f.pathKey] ?? snoozed[f.id] ?? .distantPast) > now }
}

public struct DecisionLog {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> DecisionLog {
        DecisionLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/decisions.json"))
    }

    /// 没有文件当没有决定；整份读不出来时先改名留底（`readOnly` 时不挪），免得下次保存把它覆盖掉
    public func load(readOnly: Bool = false) -> Decisions {
        guard let data = try? Data(contentsOf: url) else { return Decisions() }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        if let decisions = try? d.decode(Decisions.self, from: data) { return decisions }
        if !readOnly {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("decisions-damaged-\(stamp)-\(UUID().uuidString.prefix(8)).json.bak"))
        }
        return Decisions()
    }

    /// 文件在但读不了（权限、读错误）时报错不写，免得把读不到的「保留」整份覆盖掉
    public func save(_ decisions: Decisions) throws {
        try refuseIfUnreadable(url)
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
            f.risk != .readOnly && f.cleanup.runnable && !decisions.isKept(f) && !decisions.isSnoozed(f, now: now)
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

/// 解码失败时得到 nil，不让一条坏数据拖垮整份
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
}

extension Cleanup {
    /// 真能执行：不是「不能清」，也不是空命令
    public var runnable: Bool {
        switch self {
        case .none: return false
        case .command(let args): return !args.isEmpty
        default: return true
        }
    }
}

extension Finding {
    /// 按路径认一项（「保留」「下周再问」用）
    public var pathKey: String { paths.joined(separator: "\n") }
}

/// 文件在但读不了时抛错：用户数据文件写之前调用，免得把读不到的旧内容覆盖掉
func refuseIfUnreadable(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path), (try? Data(contentsOf: url)) == nil {
        throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.path])
    }
}
