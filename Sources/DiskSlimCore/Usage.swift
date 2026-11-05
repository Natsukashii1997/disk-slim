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

    public var usedBytes: Int64 { Usage.minus(totalBytes, freeBytes) }

    /// 各个数都在 0 到 1 PB 之间，且可用不超过总量
    var plausible: Bool {
        let limit: Int64 = 1 << 50
        return (0...limit).contains(totalBytes) && (0...totalBytes).contains(freeBytes) && parts.values.allSatisfy { (0...limit).contains($0) }
    }
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

    /// 读记录。`readOnly` 为 true 时（命令行查看、离屏截图）文件坏了也不挪动，只返回空
    public func load(readOnly: Bool = false) -> [UsageSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let samples = Self.decode(data) { return samples }
        if !readOnly { try? setAside() }
        return []
    }

    @discardableResult
    public func record(_ s: UsageSample) throws -> [UsageSample] {
        // 写之前读旧记录：没有文件从头开始；文件在但读不出来就报错不写，免得覆盖掉历史；内容坏了先留底再写
        var all: [UsageSample] = []
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let old = Self.decode(data) { all = old } else { try setAside() }
        }
        // 同一天只留时间最晚的一份（时钟被往回调过时，后写的不一定更晚）
        let day = BeijingTime.dayKey(s.at)
        if let kept = all.first(where: { BeijingTime.dayKey($0.at) == day && $0.at > s.at }) {
            all = all.filter { BeijingTime.dayKey($0.at) != day } + [kept]
        } else {
            all = all.filter { BeijingTime.dayKey($0.at) != day } + [s]
        }
        all = all.filter { s.at.timeIntervalSince($0.at) < keepDays * 86_400 }.sorted { $0.at < $1.at }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(all).write(to: url, options: .atomic)
        return all
    }

    private static func decode(_ data: Data) -> [UsageSample]? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        // 数值离谱（负数、超过 1 PB）的记录扔掉，免得后面相减溢出把应用弄崩
        return (try? d.decode([UsageSample].self, from: data))?.filter(\.plausible).sorted { $0.at < $1.at }
    }

    /// 坏了就改名留底
    private func setAside() throws {
        let stamp = Int(Date().timeIntervalSince1970)
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
            .appendingPathComponent("usage-damaged-\(stamp)-\(UUID().uuidString.prefix(8)).json.bak"))
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
    public static let downloads = "下载文件夹"
    public static let trash = "废纸篓"

    /// 从一次扫描结果得到一份记录。没有磁盘信息时返回 nil。
    public static func sample(from r: ScanReport) -> UsageSample? {
        guard let disk = r.disk else { return nil }
        var parts: [String: Int64] = [:]
        if let dl = r.downloadsBytes { parts[downloads] = dl }
        if let trash = r.trashBytes { parts[Usage.trash] = trash }
        for f in r.findings where f.area == .hidden {
            parts[partName(f), default: 0] += f.bytes
        }
        return UsageSample(at: r.scannedAt, totalBytes: disk.totalBytes, freeBytes: disk.availableBytes, parts: parts)
    }

    /// 同类的合成一个位置：同一项目的 worktree 构建产物合起来，多份 Codex 备份合起来
    public static func partName(_ f: Finding) -> String {
        if f.category.contains("构建产物") {
            // 标题是「项目 · worktree」，项目名里也可能带「 · 」，所以按最后一个切
            let project = f.title.range(of: " · ", options: .backwards).map { String(f.title[..<$0.lowerBound]) } ?? f.title
            return "\(project) · worktree 构建产物"
        }
        if f.title.hasPrefix("Codex 备份") { return "Codex 备份" }
        return f.title
    }

    /// 最近 `days` 个北京日期（含今天）里每天最后一份记录，按日期从早到晚
    public static func daily(_ samples: [UsageSample], days: Int = 7, now: Date) -> [UsageSample] {
        let first = BeijingTime.dayNumber(now) - (days - 1)
        var byDay: [Int: UsageSample] = [:]
        for s in samples where BeijingTime.dayNumber(s.at) >= first && s.at <= now {
            let k = BeijingTime.dayNumber(s.at)
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
    /// 只在一边出现的位置（没量到、或刚跨过列出门槛）说不准变了多少：不到 `oneSidedMin` 的、以及下载文件夹（只会是读不了），
    /// 都不单列，归进「其他」；够大的照列（新冒出来或被清掉的大目录，误差不超过列出门槛）。
    /// 「其他」= 已用空间的变化 − 单列各位置变化之和，用来发现涨在没跟踪的地方。
    public static func changes(from old: UsageSample, to new: UsageSample, minBytes: Int64 = 50 * 1_048_576,
                               oneSidedMin: Int64 = 1_073_741_824) -> [UsageChange] {
        var list: [UsageChange] = []
        for name in Set(old.parts.keys).union(new.parts.keys) {
            switch (old.parts[name], new.parts[name]) {
            case let (a?, b?): list.append(UsageChange(name: name, delta: minus(b, a)))
            case let (a?, nil) where a >= oneSidedMin && name != downloads: list.append(UsageChange(name: name, delta: minus(0, a)))
            case let (nil, b?) where b >= oneSidedMin && name != downloads: list.append(UsageChange(name: name, delta: b))
            default: break
            }
        }
        // 磁盘总量变了（换盘、分区调整）时没法算「其他」
        if new.totalBytes == old.totalBytes {
            let tracked = list.reduce(Int64(0)) { plus($0, $1.delta) }
            list.append(UsageChange(name: untracked, delta: minus(minus(new.usedBytes, old.usedBytes), tracked)))
        }
        return list.filter { $0.delta.magnitude >= minBytes.magnitude }.sorted { $0.delta > $1.delta }
    }

    // 记录文件被手改成离谱的数时也不能溢出崩溃：到头就停在最大 / 最小值
    static func minus(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.subtractingReportingOverflow(b)
        return o ? (b < 0 ? .max : .min) : r
    }

    static func plus(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? (b > 0 ? .max : .min) : r
    }

    /// 两份记录之间可用空间的变化，如「可用空间少了 8.0 GB」；不到 50 MB 写「差不多」
    public static func freeChange(from old: UsageSample, to new: UsageSample) -> String {
        let d = minus(new.freeBytes, old.freeBytes)
        if d.magnitude < 50 * 1_048_576 { return "可用空间差不多" }
        return "可用空间\(d < 0 ? "少了" : "多了") \(formatBytes(d == .min ? .max : abs(d)))"
    }

    /// 首页那一句，如「比昨天少了 3.2 GB，主要是 postpane · worktree 构建产物（+2.8 GB）」。不够两天返回 nil。
    /// 最新一份不是今天（`now`）的时候，前面写上它的日期，如「11/2 比 11/1 少了…」。
    public static func headline(_ samples: [UsageSample], now: Date) -> String? {
        guard let (new, old) = latestAndPrevious(samples) else { return nil }
        let isToday = BeijingTime.dayNumber(new.at) == BeijingTime.dayNumber(now)
        let isYesterday = isToday && BeijingTime.dayNumber(new.at) - BeijingTime.dayNumber(old.at) == 1
        let when = isYesterday ? "昨天" : " \(BeijingTime.shortDay(old.at)) "
        let lead = isToday ? "" : "\(BeijingTime.shortDay(new.at)) "
        let d = minus(new.freeBytes, old.freeBytes)
        if d.magnitude < 50 * 1_048_576 { return "\(lead)可用空间和\(when)差不多" }
        let list = changes(from: old, to: new)
        var text = "\(lead)比\(when)\(d < 0 ? "少了" : "多了") \(formatBytes(d == .min ? .max : abs(d)))"
        // 可用变少时找涨得最多的，变多时找减得最多的
        let main = d < 0 ? list.first(where: { $0.delta > 0 }) : list.last(where: { $0.delta < 0 })
        if let m = main { text += "，主要是\(m.name)（\(formatDelta(m.delta))）" }
        return text
    }
}
