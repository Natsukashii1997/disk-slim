import Foundation

/// 每天记一份：可用空间 + 各个被跟踪位置的大小（docs/PRD.md 3.2「涨幅」）。
public struct UsageSample: Codable, Equatable {
    public let at: Date
    public let totalBytes: Int64
    public let freeBytes: Int64
    /// 位置名 → 大小，如「下载文件夹」「postpane · worktree 构建产物」「Codex 对话记录」
    public let parts: [String: Int64]

    public init(at: Date, totalBytes: Int64, freeBytes: Int64, parts: [String: Int64]) {
        self.at = at
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.parts = parts
    }

    public var usedBytes: Int64 { totalBytes - freeBytes }
}

/// 记录存在 usage.json：同一天（北京时间）只留最后一份，保留最近 90 天。
public struct UsageLog {
    public let url: URL
    public let keepDays: Double

    public init(url: URL, keepDays: Double = 90) {
        self.url = url
        self.keepDays = keepDays
    }

    public static func standard(home: URL) -> UsageLog {
        UsageLog(url: home.appendingPathComponent("Library/Application Support/disk-slim/usage.json"))
    }

    public func load() -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let samples = try? d.decode([UsageSample].self, from: data) else {
            // 坏了就留底，免得下一次记录把它覆盖掉
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("usage-damaged-\(stamp).json.bak"))
            return []
        }
        return samples.sorted { $0.at < $1.at }
    }

    @discardableResult
    public func record(_ s: UsageSample) throws -> [UsageSample] {
        let day = BeijingTime.dayKey(s.at)
        var all = load().filter { BeijingTime.dayKey($0.at) != day }
        all.append(s)
        all = all.filter { s.at.timeIntervalSince($0.at) < keepDays * 86_400 }.sorted { $0.at < $1.at }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(all).write(to: url, options: .atomic)
        return all
    }
}

/// 某个位置在两份记录之间变了多少（正数是涨）。
public struct UsageChange: Equatable {
    public let name: String
    public let delta: Int64
}

public enum Usage {
    /// 没跟踪到的部分：已用空间的变化减去所有被跟踪位置的变化
    public static let untracked = "其他（没跟踪的地方）"

    /// 从一次扫描结果得到一份记录。没有磁盘信息时返回 nil。
    public static func sample(from r: ScanReport) -> UsageSample? {
        guard let disk = r.disk else { return nil }
        var parts: [String: Int64] = [:]
        if let dl = r.downloadsBytes { parts["下载文件夹"] = dl }
        for f in r.findings where f.area == .hidden {
            parts[partName(f), default: 0] += f.bytes
        }
        return UsageSample(at: r.scannedAt, totalBytes: disk.totalBytes, freeBytes: disk.availableBytes, parts: parts)
    }

    /// 同类的合成一个位置：同一项目的 worktree 构建产物合起来，多份 Codex 备份合起来
    static func partName(_ f: Finding) -> String {
        if f.category.contains("构建产物") {
            let project = f.title.components(separatedBy: " · ").first ?? f.title
            return "\(project) · worktree 构建产物"
        }
        if f.title.hasPrefix("Codex 备份") { return "Codex 备份" }
        return f.title
    }

    /// 最近 `days` 天里每天最后一份记录，按日期从早到晚
    public static func daily(_ samples: [UsageSample], days: Int = 7, now: Date) -> [UsageSample] {
        var byDay: [String: UsageSample] = [:]
        for s in samples where now.timeIntervalSince(s.at) < Double(days) * 86_400 && s.at <= now {
            let k = BeijingTime.dayKey(s.at)
            if let old = byDay[k], old.at > s.at { continue }
            byDay[k] = s
        }
        return byDay.values.sorted { $0.at < $1.at }
    }

    /// 最新一份，以及它之前最近的、属于更早一天的那一份；不够两天时返回 nil
    public static func latestAndPrevious(_ samples: [UsageSample]) -> (UsageSample, UsageSample)? {
        guard let latest = samples.max(by: { $0.at < $1.at }) else { return nil }
        let day = BeijingTime.dayKey(latest.at)
        guard let prev = samples.filter({ BeijingTime.dayKey($0.at) < day }).max(by: { $0.at < $1.at }) else { return nil }
        return (latest, prev)
    }

    /// 两份记录之间各位置的变化，涨得多的在前；变化不到 `minBytes` 的不列。
    /// 「其他」= 已用空间的变化 − 各位置变化之和，用来发现涨在没跟踪的地方。
    public static func changes(from old: UsageSample, to new: UsageSample, minBytes: Int64 = 50 * 1_048_576) -> [UsageChange] {
        let names = Set(old.parts.keys).union(new.parts.keys)
        var list = names.map { UsageChange(name: $0, delta: (new.parts[$0] ?? 0) - (old.parts[$0] ?? 0)) }
        let tracked = list.reduce(Int64(0)) { $0 + $1.delta }
        list.append(UsageChange(name: untracked, delta: (new.usedBytes - old.usedBytes) - tracked))
        return list.filter { abs($0.delta) >= minBytes }.sorted { $0.delta > $1.delta }
    }
}
