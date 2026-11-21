import Foundation

// 用户在卡片上做的决定（保留、下周再问）和它的记录文件 decisions.json。

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

    var file: RecordFile<Decisions> { RecordFile(url: url) }

    /// 没有文件当没有决定；整份读不出来时先改名留底（`readOnly` 时不挪），免得下次保存把它覆盖掉
    public func load(readOnly: Bool = false) -> Decisions { file.load(readOnly: readOnly).value ?? Decisions() }

    /// 文件在但读不了（权限、读错误）时报错不写，免得把读不到的「保留」整份覆盖掉
    public func save(_ decisions: Decisions) throws { try file.save(decisions) }
}

/// 选过「保留」的项不再默认勾选（首页「清理建议项」不会把它清掉），说明里写明
public func applyDecisions(_ findings: [Finding], _ decisions: Decisions) -> [Finding] {
    findings.map { f in
        guard f.suggested, decisions.isKept(f) else { return f }
        return f.revised(detail: "你选过保留 · " + f.detail, suggested: false)
    }
}

extension Finding {
    /// 按路径认一项（「保留」「下周再问」用）
    public var pathKey: String { paths.joined(separator: "\n") }
}
