import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct UsageTests {
    let gb: Int64 = 1_073_741_824

    func sample(_ at: Date, free: Double, _ parts: [String: Double]) -> UsageSample {
        UsageSample(at: at, totalBytes: 460 * gb, freeBytes: Int64(free * Double(gb)),
                    parts: parts.mapValues { Int64($0 * Double(gb)) })
    }

    /// 北京时间某天某点
    func bj(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+08:00")! }

    @Test func 同一天只留最后一份_超过保留天数的删掉() throws {
        let t = TempDir()
        let log = UsageLog(url: t.url.appendingPathComponent("usage.json"), keepDays: 10)
        try log.record(sample(bj("2026-10-20T10:00:00"), free: 90, [:]))
        try log.record(sample(bj("2026-11-04T10:00:00"), free: 80, [:]))
        try log.record(sample(bj("2026-11-05T09:00:00"), free: 70, [:]))
        let all = try log.record(sample(bj("2026-11-05T23:30:00"), free: 60, [:]))
        #expect(all.count == 2) // 10 月 20 日超过 10 天被删；11 月 5 日只留 23:30 那份
        #expect(all.last?.freeBytes == 60 * gb)
    }

    @Test func 按北京时间分天_不按UTC() throws {
        let t = TempDir()
        let log = UsageLog(url: t.url.appendingPathComponent("usage.json"))
        // 北京时间 11 月 5 日 07:00 = UTC 11 月 4 日 23:00，应该和 11 月 5 日 20:00 算同一天
        try log.record(sample(bj("2026-11-05T07:00:00"), free: 70, [:]))
        let all = try log.record(sample(bj("2026-11-05T20:00:00"), free: 65, [:]))
        #expect(all.count == 1)
    }

    @Test func 记录损坏时留底不覆盖() throws {
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try Data("[{ broken".utf8).write(to: url)
        let all = try UsageLog(url: url).record(sample(bj("2026-11-05T10:00:00"), free: 70, [:]))
        #expect(all.count == 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.url.path).filter { $0.hasPrefix("usage-damaged-") }
        #expect(backups.count == 1)
    }

    @Test func 谁涨的_含没跟踪的部分_小变化不列() {
        let old = sample(bj("2026-11-04T10:00:00"), free: 91,
                         ["下载文件夹": 2.8, "postpane · worktree 构建产物": 5.8, "npm 缓存": 0.14])
        let new = sample(bj("2026-11-05T10:00:00"), free: 60,
                         ["下载文件夹": 3.7, "postpane · worktree 构建产物": 29.5, "npm 缓存": 0.15])
        let c = Usage.changes(from: old, to: new)
        // 已用涨了 31 GB；被跟踪的位置涨了 0.9 + 23.7 = 24.6 GB；其余 6.4 GB 记到「其他」
        #expect(c.first?.name == "postpane · worktree 构建产物")
        #expect(abs(Double(c.first!.delta) / Double(gb) - 23.7) < 0.01)
        let other = c.first { $0.name == Usage.untracked }
        #expect(other != nil)
        #expect(abs(Double(other!.delta) / Double(gb) - 6.4) < 0.02)
        #expect(!c.contains { $0.name == "npm 缓存" }) // 只涨了 10 MB
    }

    @Test func 不够两天时没有对比_有两天时取前一天最后一份() {
        let a = sample(bj("2026-11-05T09:00:00"), free: 70, [:])
        let b = sample(bj("2026-11-05T12:00:00"), free: 69, [:])
        #expect(Usage.latestAndPrevious([a, b]) == nil)
        let y1 = sample(bj("2026-11-04T08:00:00"), free: 80, [:])
        let y2 = sample(bj("2026-11-04T22:00:00"), free: 78, [:])
        let pair = Usage.latestAndPrevious([y1, y2, a, b])
        #expect(pair?.0 == b)
        #expect(pair?.1 == y2)
    }

    @Test func 曲线取最近七天每天最后一份() {
        let now = bj("2026-11-05T12:00:00")
        var s: [UsageSample] = []
        for d in 0..<10 {
            let day = now.addingTimeInterval(-Double(d) * 86_400)
            s.append(sample(day.addingTimeInterval(-3600), free: Double(50 + d), [:]))
            s.append(sample(day.addingTimeInterval(-7200), free: 0, [:]))
        }
        let series = Usage.daily(s, days: 7, now: now)
        #expect(series.count == 7)
        #expect(series.allSatisfy { $0.freeBytes > 0 }) // 每天取最后一份（-1 小时那份），不是 -2 小时那份
        #expect(series.last?.freeBytes == 50 * gb)
    }

    @Test func 从扫描结果生成记录_同类合并() {
        func f(_ title: String, _ category: String, _ gbs: Double, area: Area = .hidden) -> Finding {
            Finding(area: area, category: category, title: title, detail: "", paths: ["/\(title)"],
                    bytes: Int64(gbs * Double(gb)), risk: .safe, suggested: false, cleanup: .none)
        }
        let r = ScanReport(scannedAt: now, seconds: 1, disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 70 * gb),
                           findings: [f("postpane · 48-a", "暂时不能清的构建产物", 8),
                                      f("postpane · 46-b", "已合并 worktree 的构建产物", 6),
                                      f("Codex 备份 · 0916", "备份快照", 4),
                                      f("Codex 备份 · 0907", "备份快照", 3),
                                      f("a.dmg", "安装包", 1, area: .downloads)],
                           downloadsBytes: 3 * gb)
        let s = Usage.sample(from: r)!
        #expect(s.parts["postpane · worktree 构建产物"] == 14 * gb)
        #expect(s.parts["Codex 备份"] == 7 * gb)
        #expect(s.parts["下载文件夹"] == 3 * gb) // 下载区用整体大小，不按单个文件
        #expect(s.parts["a.dmg"] == nil)
    }

    @Test func 首页一句话_说少了多少和主要是谁() {
        let a = sample(bj("2026-11-04T10:00:00"), free: 80, ["下载文件夹": 5, "postpane · worktree 构建产物": 10])
        let b = sample(bj("2026-11-05T10:00:00"), free: 76.5, ["下载文件夹": 5.5, "postpane · worktree 构建产物": 13])
        let nov5 = bj("2026-11-05T12:00:00")
        #expect(Usage.headline([a, b], now: nov5) == "比昨天少了 3.5 GB，主要是postpane · worktree 构建产物（+3.0 GB）")
        // 隔了几天：写日期；可用变多时说减得最多的
        let c = sample(bj("2026-11-07T10:00:00"), free: 85, ["下载文件夹": 1, "postpane · worktree 构建产物": 10])
        #expect(Usage.headline([a, c], now: bj("2026-11-07T12:00:00")) == "比 11/4 多了 5.0 GB，主要是下载文件夹（−4.0 GB）")
        // 变化很小、只有一天
        #expect(Usage.headline([a, sample(bj("2026-11-05T10:00:00"), free: 80.01, [:])], now: nov5)?.hasPrefix("可用空间和昨天差不多") == true)
        #expect(Usage.headline([a], now: nov5) == nil)
    }

    @Test func 最新记录不是今天时_写明是哪天比哪天() {
        let a = sample(bj("2026-11-01T10:00:00"), free: 80, [:])
        let b = sample(bj("2026-11-02T10:00:00"), free: 70, [:])
        #expect(Usage.headline([a, b], now: bj("2026-11-05T12:00:00")) == "11/2 比 11/1 少了 10.0 GB，主要是其他（没跟踪的地方）（+10.0 GB）")
    }

    @Test func 最近7天按北京日期算_不会多出第8天() {
        let now = bj("2026-11-05T12:34:00")
        let days = Usage.daily([
            sample(bj("2026-10-29T13:34:00"), free: 90, [:]), // 不到 7×24 小时前，但已是第 8 个日期
            sample(bj("2026-10-30T00:00:00"), free: 85, [:]), // 7 天里的第一天
            sample(now, free: 80, [:]),
        ], now: now)
        #expect(days.map { BeijingTime.shortDay($0.at) } == ["10/30", "11/5"])
    }

    @Test func 只在一天出现的位置_小的和下载文件夹归进其他_大的照列() {
        let old = sample(bj("2026-11-04T10:00:00"), free: 80, ["旧项目 · worktree 构建产物": 6]) // pip 那天不到 50 MB 没列出
        // 下载文件夹那天读不了（没记），pip 刚过 50 MB 门槛，新项目冒出 3 GB，旧项目被清掉
        let new = sample(bj("2026-11-05T10:00:00"), free: 81, ["下载文件夹": 10, "pip 缓存": 0.05, "新项目 · worktree 构建产物": 3])
        let list = Usage.changes(from: old, to: new)
        #expect(list.map(\.name) == ["新项目 · worktree 构建产物", Usage.untracked, "旧项目 · worktree 构建产物"])
        #expect(list.first { $0.name == Usage.untracked }?.delta == 2 * gb) // −1 GB 已用 − (3 − 6)
    }

    @Test func 记录文件读不出来时不覆盖() throws {
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) // 是个目录：存在但读不出来
        #expect(throws: (any Error).self) { try UsageLog(url: url).record(sample(bj("2026-11-05T10:00:00"), free: 70, [:])) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func 只读加载_坏文件不挪() throws {
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try Data("[{ broken".utf8).write(to: url)
        #expect(UsageLog(url: url).load(readOnly: true).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

