import Foundation

/// 提醒规则的开关（docs/PRD.md 4.3）。
public struct AlertSettings: Codable, Equatable {
    /// 可用低于 30 GB 时发通知
    public var lowSpace = true
    /// 某个被跟踪的位置一天涨超过 10 GB（不含正好 10 GB）时发通知
    public var growth = true
    /// 每周五 18:00 发周报（本周待决定）
    public var weekly = true
    /// 自动清理「安全」的缓存和构建产物：默认关闭；打开后只在可用低于 60 GB 时执行，每天最多一次
    public var autoClean = false

    public init() {}

    /// 宽松地读：缺哪个开关就用默认值，其他照读；autoClean 读不出来一律当关
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowSpace = (try? c.decodeIfPresent(Bool.self, forKey: .lowSpace)) ?? nil ?? true
        growth = (try? c.decodeIfPresent(Bool.self, forKey: .growth)) ?? nil ?? true
        weekly = (try? c.decodeIfPresent(Bool.self, forKey: .weekly)) ?? nil ?? true
        autoClean = (try? c.decodeIfPresent(Bool.self, forKey: .autoClean)) ?? nil ?? false
    }
}

/// alerts.json：开关 + 各条提醒上次发在哪天，免得重复发。
public struct AlertState: Codable, Equatable {
    public var settings = AlertSettings()
    /// 提醒的键 → 发过的北京日期（周报记的是那个周五的日期）
    public var sent: [String: String] = [:]
    /// 自动清理上次执行的北京日期
    public var autoCleanDay: String?

    public init() {}

    /// 宽松地读：缺字段或某个字段坏了只用那个字段的默认值，不把开关和「发过」记录一起丢掉
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try? c.decodeIfPresent(AlertSettings.self, forKey: .settings)) ?? nil ?? AlertSettings()
        sent = (try? c.decodeIfPresent([String: String].self, forKey: .sent)) ?? nil ?? [:]
        autoCleanDay = (try? c.decodeIfPresent(String.self, forKey: .autoCleanDay)) ?? nil
    }
}

public struct AlertStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard(home: URL) -> AlertStore {
        AlertStore(url: home.appendingPathComponent("Library/Application Support/disk-slim/alerts.json"))
    }

    /// 读不出来按默认值（自动清理默认关，读坏了也不会被打开）；内容坏了先改名留底（`readOnly` 时不挪）
    public func load(readOnly: Bool = false) -> AlertState {
        guard let data = try? Data(contentsOf: url) else { return AlertState() }
        if let state = try? JSONDecoder().decode(AlertState.self, from: data) { return state }
        if !readOnly {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("alerts-damaged-\(stamp)-\(UUID().uuidString.prefix(8)).json.bak"))
        }
        return AlertState()
    }

    public func save(_ state: AlertState) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(state).write(to: url, options: .atomic)
    }
}

/// 一条要发的系统通知
public struct Alert: Equatable {
    /// 去重用：同一个键一天（周报是一周）只发一次
    public let key: String
    /// 记进 `sent` 的日期
    public let day: String
    public let title: String
    public let body: String
}

public enum Alerts {
    public static let lowSpaceBytes: Int64 = 30 * 1_073_741_824
    public static let growthBytes: Int64 = 10 * 1_073_741_824
    public static let autoCleanBelow: Int64 = 60 * 1_073_741_824

    /// 现在该发哪些提醒。`free` 为 nil（读不到磁盘）时不判断空间；`cards` 为 nil（还没扫描）时不发周报。
    public static func due(now: Date, free: Int64?, samples: [UsageSample], cards: [WeeklyCard]?, state: AlertState) -> [Alert] {
        let today = BeijingTime.dayKey(now)
        let s = state.settings
        var list: [Alert] = []

        if s.lowSpace, let free, free < lowSpaceBytes, state.sent["lowSpace"] != today {
            list.append(Alert(key: "lowSpace", day: today, title: "磁盘只剩 \(formatBytes(free))",
                              body: "低于 30 GB 了。点菜单栏的磁盘瘦身看看能清什么。"))
        }

        // 今天的记录和昨天的比；位置变化超过 10 GB 才提醒。「其他」不是被跟踪的位置；
        // 废纸篓涨是因为刚把东西移进去，空间没变多少，也不报
        if s.growth, let (new, old) = Usage.latestAndPrevious(Usage.daily(samples, days: 2, now: now)),
           BeijingTime.dayNumber(new.at) == BeijingTime.dayNumber(now),
           BeijingTime.dayNumber(new.at) - BeijingTime.dayNumber(old.at) == 1 {
            for c in Usage.changes(from: old, to: new) where c.delta > growthBytes && c.name != Usage.untracked && c.name != Usage.trash {
                let key = "growth|" + c.name
                if state.sent[key] == today { continue }
                list.append(Alert(key: key, day: today, title: "\(c.name) 一天涨了 \(formatBytes(c.delta))",
                                  body: "点菜单栏的磁盘瘦身 › 涨幅，看看是谁。"))
            }
        }

        // 最近一个周五 18:00 之后还没发过就发（周六才打开应用也能补上），没有要决定的就不打扰
        if s.weekly, let cards, !cards.isEmpty {
            let friday = BeijingTime.dayKey(Weekly.lastReport(atOrBefore: now))
            if state.sent["weekly"] != friday {
                let total = cards.reduce(Int64(0)) { $0 + $1.bytes }
                list.append(Alert(key: "weekly", day: friday, title: "本周瘦身：\(cards.count) 件待决定",
                                  body: "一共能腾出 \(formatBytes(total))。点菜单栏的磁盘瘦身，逐件决定。"))
            }
        }
        return list
    }

    /// 自动清理现在该不该跑：开关打开、可用低于 60 GB、今天还没跑过
    public static func shouldAutoClean(now: Date, free: Int64?, state: AlertState) -> Bool {
        guard state.settings.autoClean, let free, free < autoCleanBelow else { return false }
        return state.autoCleanDay != BeijingTime.dayKey(now)
    }

    /// 自动清理只动「看不见的」里安全、默认勾选的项（缓存、可再生的构建产物）；下载文件夹里的用户文件一律不动
    public static func autoCleanPicks(_ findings: [Finding]) -> [Finding] {
        findings.filter { $0.area == .hidden && $0.risk == .safe && $0.suggested && $0.cleanup.runnable }
    }
}
