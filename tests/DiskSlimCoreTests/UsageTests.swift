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
}
