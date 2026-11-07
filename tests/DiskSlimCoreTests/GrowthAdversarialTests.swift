import Foundation
import Testing
@testable import DiskSlimCore

// 第 4 批「涨幅追踪」的对抗测试：每个用例只测一件事，注释写期望。
// 失败的用例表示找到的问题或有争议的期望，见提交说明 / 交接里的结论，不改被测源码。

private let GB: Int64 = 1_073_741_824
private let MB: Int64 = 1_048_576

/// 北京时间某天某点，如 "2026-11-05T10:00:00"
private func bjTime(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+08:00")! }
/// UTC 某天某点
private func utcTime(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "Z")! }

private func rec(_ at: Date, free: Double, total: Double = 460, _ parts: [String: Double] = [:]) -> UsageSample {
    UsageSample(at: at, totalBytes: Int64(total * Double(GB)), freeBytes: Int64(free * Double(GB)),
                parts: parts.mapValues { Int64($0 * Double(GB)) })
}

private func hidden(_ title: String, _ category: String, _ gbs: Double) -> Finding {
    Finding(area: .hidden, category: category, title: title, detail: "", paths: ["/\(title)"],
            bytes: Int64(gbs * Double(GB)), risk: .safe, suggested: false, cleanup: .none)
}

private func writeLog(_ url: URL, _ samples: [UsageSample]) throws {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    try e.encode(samples).write(to: url)
}

// MARK: - 北京时间与格式

@Suite struct GrowthTimeAndFormatTests {
    @Test func dayKey_UTC前一天16点半是北京时间第二天() {
        // 期望：2026-11-04 16:30 UTC = 北京 11-05 00:30，归到 11-05
        #expect(BeijingTime.dayKey(utcTime("2026-11-04T16:30:00")) == "2026-11-05")
    }

    @Test func dayKey_北京午夜前后一秒分属两天() {
        // 期望：23:59:59 是 11-04，再过 1 秒是 11-05
        let t = bjTime("2026-11-04T23:59:59")
        #expect(BeijingTime.dayKey(t) == "2026-11-04")
        #expect(BeijingTime.dayKey(t.addingTimeInterval(1)) == "2026-11-05")
    }

    @Test func shortDay_不补零() {
        // 期望：1 月 5 日写「1/5」，不是「01/05」
        #expect(BeijingTime.shortDay(bjTime("2026-01-05T00:00:00")) == "1/5")
    }

    @Test func formatDelta_负数用全角减号() {
        // 期望：−340 MB（U+2212），不是 "-340 MB" 或 "+340 MB"
        #expect(formatDelta(-340 * MB) == "−340 MB")
    }

    @Test func formatDelta_零不带负号() {
        // 期望：0 不显示成「−0 KB」
        #expect(!formatDelta(0).hasPrefix("−"))
    }

    @Test func formatDelta_负一字节显示为负1KB() {
        // 期望：−1 字节也要能看出是减少，「−1 KB」
        #expect(formatDelta(-1) == "−1 KB")
    }

    @Test(.disabled("范围外：formatBytes 的进位是第 4 批以前的代码，记进交接")) func formatDelta_接近1GB时进位成GB() {
        // 期望：1023.6 MB 四舍五入后已经是 1 GB，应显示「+1.0 GB」而不是「+1024 MB」
        let bytes = Int64(1023.6 * Double(MB))
        #expect(formatDelta(bytes) == "+1.0 GB")
    }

    @Test func formatDelta_Int64最小值不崩溃() async {
        // 期望：记录文件里出现极端值时，格式化不会让进程崩溃（abs(Int64.min) 会溢出）
        await #expect(processExitsWith: .success) {
            _ = formatDelta(Int64.min)
        }
    }
}

// MARK: - usage.json 读写

@Suite struct GrowthLogTests {
    @Test func 只读加载坏文件_不挪动也不留底() throws {
        // 期望：readOnly 时文件原样留着，目录里没有 usage-damaged-*.bak
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try Data("[{ broken".utf8).write(to: url)
        #expect(UsageLog(url: url).load(readOnly: true).isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(names == ["usage.json"])
        #expect(try Data(contentsOf: url) == Data("[{ broken".utf8))
    }

    @Test func 空数组不是坏文件_不留底() throws {
        // 期望：内容是 [] 时正常读成 0 份，不生成 usage-damaged-*.bak
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try Data("[]".utf8).write(to: url)
        #expect(UsageLog(url: url).load().isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        #expect(names == ["usage.json"])
    }

    @Test func 空文件当坏文件留底后照常记录() throws {
        // 期望：0 字节的文件被留底，新记录写进新的 usage.json
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try Data().write(to: url)
        let all = try UsageLog(url: url).record(rec(bjTime("2026-11-05T10:00:00"), free: 70))
        #expect(all.count == 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.url.path).filter { $0.hasPrefix("usage-damaged-") }
        #expect(backups.count == 1)
    }

    @Test func usage路径是目录时记录报错且不删目录() throws {
        // 期望：record 抛错（不崩、不把目录删掉）
        let t = TempDir()
        let url = t.dir("usage.json")
        t.file("usage.json/keep.txt")
        #expect(throws: (any Error).self) { try UsageLog(url: url).record(rec(bjTime("2026-11-05T10:00:00"), free: 70)) }
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("keep.txt").path))
    }

    @Test func 目录不可写时记录报错() throws {
        // 期望：record 抛错，不崩
        let t = TempDir()
        let dir = t.dir("ro")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        #expect(throws: (any Error).self) {
            try UsageLog(url: dir.appendingPathComponent("usage.json")).record(rec(bjTime("2026-11-05T10:00:00"), free: 70))
        }
    }

    @Test func 读不了的记录文件不能被新记录悄悄覆盖() throws {
        // 期望：usage.json 读不了（权限 000）时，record 要么报错、要么先留底；
        // 不能把原来 3 天的历史直接换成只有 1 份
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        let old = [rec(bjTime("2026-11-02T10:00:00"), free: 90), rec(bjTime("2026-11-03T10:00:00"), free: 85),
                   rec(bjTime("2026-11-04T10:00:00"), free: 80)]
        try writeLog(url, old)
        let original = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let threw = (try? UsageLog(url: url).record(rec(bjTime("2026-11-05T10:00:00"), free: 75))) == nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        let preserved = names.contains { name in
            (try? Data(contentsOf: t.url.appendingPathComponent(name))) == original
        }
        #expect(threw || preserved)
    }

    @Test func 坏文件留底撞名时不能丢掉坏文件() throws {
        // 期望：同一秒已有同名留底文件时，坏的 usage.json 仍要留一份，不被新记录覆盖
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        let broken = Data("[{ broken-original".utf8)
        try broken.write(to: url)
        let stamp = Int(Date().timeIntervalSince1970)
        for s in (stamp - 2)...(stamp + 30) {
            try Data("older backup".utf8).write(to: t.url.appendingPathComponent("usage-damaged-\(s).json.bak"))
        }
        _ = try UsageLog(url: url).record(rec(bjTime("2026-11-05T10:00:00"), free: 70))
        let names = try FileManager.default.contentsOfDirectory(atPath: t.url.path)
        let kept = names.contains { (try? Data(contentsOf: t.url.appendingPathComponent($0))) == broken }
        #expect(kept)
    }

    @Test func 同一天乱序写入_仍只留时间最晚的一份() throws {
        // 期望：先记 23:00、后记同一天 09:00（比如系统时间被往回调），文档说「同一天只留最后一份」，应留 23:00
        let t = TempDir()
        let log = UsageLog(url: t.url.appendingPathComponent("usage.json"))
        try log.record(rec(bjTime("2026-11-05T23:00:00"), free: 60))
        let all = try log.record(rec(bjTime("2026-11-05T09:00:00"), free: 70))
        #expect(all.count == 1)
        #expect(all.first?.at == bjTime("2026-11-05T23:00:00"))
    }

    @Test(.disabled("有争议：只在系统时钟往回调时出现，宁可多留也不删数据")) func 补记一份很久以前的记录_不应超出保留期() throws {
        // 期望：已有 11-05 的记录，再写一份 07-01 的（比最新那份早 127 天，超过 90 天），它不该被留下
        let t = TempDir()
        let log = UsageLog(url: t.url.appendingPathComponent("usage.json"))
        try log.record(rec(bjTime("2026-11-05T10:00:00"), free: 60))
        let all = try log.record(rec(bjTime("2026-07-01T10:00:00"), free: 90))
        #expect(all.count == 1)
        #expect(all.first?.at == bjTime("2026-11-05T10:00:00"))
    }

    @Test(.disabled("有争议：daily 已把未来的记录挡在曲线外，宁可多留也不删数据")) func 未来时间的记录在时钟改正后不应一直留着() throws {
        // 期望（有争议）：系统时间曾被调到一年后、记了一份，改正后再记一份；
        // 一年后的那份既不会进曲线、也挡不住保留期，应该在记录时丢掉
        let t = TempDir()
        let log = UsageLog(url: t.url.appendingPathComponent("usage.json"))
        try log.record(rec(bjTime("2027-11-05T10:00:00"), free: 10))
        let all = try log.record(rec(bjTime("2026-11-05T10:00:00"), free: 60))
        #expect(all.count == 1)
    }

    @Test func 保留期边界_刚好90天的删掉_差一秒的留着() throws {
        // 期望：与最新那份相差 < 90×24 小时的留，正好 90×24 小时的删
        let t = TempDir()
        let latest = bjTime("2026-11-05T10:00:00")
        let url = t.url.appendingPathComponent("usage.json")
        try writeLog(url, [rec(latest.addingTimeInterval(-90 * 86_400), free: 90),
                           rec(latest.addingTimeInterval(-90 * 86_400 + 1), free: 89)])
        let all = try UsageLog(url: url).record(rec(latest, free: 60))
        #expect(all.count == 2)
        #expect(all.first?.freeBytes == 89 * GB)
    }

    @Test func 文件里乱序时加载后按时间排序() throws {
        // 期望：load 返回从早到晚
        let t = TempDir()
        let url = t.url.appendingPathComponent("usage.json")
        try writeLog(url, [rec(bjTime("2026-11-05T10:00:00"), free: 1), rec(bjTime("2026-11-03T10:00:00"), free: 3),
                           rec(bjTime("2026-11-04T10:00:00"), free: 2)])
        let all = UsageLog(url: url).load(readOnly: true)
        #expect(all.map(\.freeBytes) == [3 * GB, 2 * GB, 1 * GB])
    }
}

// MARK: - 曲线与对比的取数

@Suite struct GrowthDailyTests {
    @Test func 七天曲线不应出现八个日历日() {
        // 期望：「最近 7 天」最多 7 个点。现在是 11-05 12:00，每天 13:00 记一份，今天 11:00 记一份；
        // 10-29 13:00 距现在 167 小时，按滚动 168 小时窗口会被算进来，变成 10-29…11-05 共 8 天
        let now = bjTime("2026-11-05T12:00:00")
        var s = [rec(bjTime("2026-11-05T11:00:00"), free: 50)]
        for d in 1...9 { s.append(rec(bjTime("2026-11-05T13:00:00").addingTimeInterval(-Double(d) * 86_400), free: 50 + Double(d))) }
        let series = Usage.daily(s, days: 7, now: now)
        #expect(series.count <= 7)
    }

    @Test func 刚好七乘二十四小时前的记录不进曲线() {
        // 期望：窗口是「不到 7×24 小时」，正好 7×24 小时的排除
        let now = bjTime("2026-11-05T12:00:00")
        let series = Usage.daily([rec(now.addingTimeInterval(-7 * 86_400), free: 1)], days: 7, now: now)
        #expect(series.isEmpty)
    }

    @Test func 未来时间的记录不进曲线() {
        // 期望：at > now 的记录被忽略，只剩今天那份
        let now = bjTime("2026-11-05T12:00:00")
        let series = Usage.daily([rec(now.addingTimeInterval(-60), free: 60), rec(now.addingTimeInterval(3600), free: 10)],
                                 days: 7, now: now)
        #expect(series.count == 1)
        #expect(series.first?.freeBytes == 60 * GB)
    }

    @Test func 同一天两份时间完全相同只出一个点() {
        // 期望：同一天同一时刻两份，曲线里只有 1 个点
        let at = bjTime("2026-11-05T10:00:00")
        let series = Usage.daily([rec(at, free: 60), rec(at, free: 61)], days: 7, now: bjTime("2026-11-05T12:00:00"))
        #expect(series.count == 1)
    }

    @Test func 零天窗口返回空() {
        // 期望：days = 0 时什么都不返回
        let now = bjTime("2026-11-05T12:00:00")
        #expect(Usage.daily([rec(now, free: 60)], days: 0, now: now).isEmpty)
    }

    @Test func 没有记录时没有对比() {
        // 期望：0 份 → nil，不崩
        #expect(Usage.latestAndPrevious([]) == nil)
        #expect(Usage.headline([], now: Date()) == nil)
    }

    @Test func UTC前一天但北京同一天_不够两天() {
        // 期望：北京 11-05 07:00（UTC 11-04）和 11-05 20:00 是同一天，没有对比
        #expect(Usage.latestAndPrevious([rec(bjTime("2026-11-05T07:00:00"), free: 70),
                                         rec(bjTime("2026-11-05T20:00:00"), free: 60)]) == nil)
    }
}

// MARK: - 谁涨的

@Suite struct GrowthChangesTests {
    @Test func 只在新一天出现的位置按整个大小算涨() {
        // 期望：新出现的 postpane 构建产物 +3 GB，已用也涨 3 GB，「其他」为 0 不列
        let old = rec(bjTime("2026-11-04T10:00:00"), free: 80, ["下载文件夹": 5])
        let new = rec(bjTime("2026-11-05T10:00:00"), free: 77, ["下载文件夹": 5, "postpane · worktree 构建产物": 3])
        let c = Usage.changes(from: old, to: new)
        #expect(c == [UsageChange(name: "postpane · worktree 构建产物", delta: 3 * GB)])
    }

    @Test func 某天扫描缺了下载文件夹_不应报下载文件夹大跌() {
        // 期望：下载文件夹当天没量到（downloadsBytes 为 nil，比如没权限或扫描出错），可用空间没变；
        // 不该报「下载文件夹 −5 GB」、同时「其他 +5 GB」这种虚假变化，排行应为空
        let disk = DiskStatus(totalBytes: 460 * GB, availableBytes: 80 * GB)
        let day1 = ScanReport(scannedAt: bjTime("2026-11-04T10:00:00"), seconds: 1, disk: disk, findings: [], downloadsBytes: 5 * GB)
        let day2 = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1, disk: disk, findings: [], downloadsBytes: nil)
        let c = Usage.changes(from: Usage.sample(from: day1)!, to: Usage.sample(from: day2)!)
        #expect(c.isEmpty)
    }

    @Test func 磁盘总量变了_不应把容量变化算成其他涨了() {
        // 期望（有争议）：总量从 460 GB 变成 450 GB（换盘或 APFS 报的容量变了），可用和各位置都没变；
        // 实际没有任何东西涨，「其他」不应出现 +10 GB
        let old = rec(bjTime("2026-11-04T10:00:00"), free: 80, total: 460, ["下载文件夹": 5])
        let new = rec(bjTime("2026-11-05T10:00:00"), free: 80, total: 450, ["下载文件夹": 5])
        #expect(Usage.changes(from: old, to: new).isEmpty)
    }

    @Test func 阈值边界_刚好50MB列出_差1字节不列() {
        // 期望：|变化| >= 50 MB 才列
        let base = rec(bjTime("2026-11-04T10:00:00"), free: 80)
        func with(_ a: Int64, _ b: Int64) -> UsageSample {
            UsageSample(at: bjTime("2026-11-05T10:00:00"), totalBytes: base.totalBytes, freeBytes: base.freeBytes - a - b,
                        parts: ["A": a, "B": b])
        }
        let c = Usage.changes(from: UsageSample(at: base.at, totalBytes: base.totalBytes, freeBytes: base.freeBytes, parts: ["A": 0, "B": 0]),
                              to: with(50 * MB, 50 * MB - 1))
        #expect(c.map(\.name) == ["A"])
    }

    @Test func 不过滤时各项之和等于已用空间的变化() {
        // 期望：minBytes = 0 时，所有变化（含「其他」）加起来正好等于已用的变化
        let old = rec(bjTime("2026-11-04T10:00:00"), free: 80, ["下载文件夹": 5, "npm 缓存": 1])
        let new = rec(bjTime("2026-11-05T10:00:00"), free: 71.3, ["下载文件夹": 2, "Codex 备份": 4])
        let c = Usage.changes(from: old, to: new, minBytes: 0)
        #expect(c.reduce(Int64(0)) { $0 + $1.delta } == new.usedBytes - old.usedBytes)
    }

    @Test func 负数大小不崩_按差值算() {
        // 期望：记录里出现负数（文件被手改）也只是按差值算，不崩
        let old = UsageSample(at: bjTime("2026-11-04T10:00:00"), totalBytes: 460 * GB, freeBytes: 80 * GB, parts: ["X": -2 * GB])
        let new = UsageSample(at: bjTime("2026-11-05T10:00:00"), totalBytes: 460 * GB, freeBytes: 76 * GB, parts: ["X": 2 * GB])
        #expect(Usage.changes(from: old, to: new) == [UsageChange(name: "X", delta: 4 * GB)])
    }

    @Test func 极端大小不让进程崩溃() async {
        // 期望：记录文件里出现 Int64 极端值（文件损坏但还是合法 JSON）时，算变化不会溢出崩溃
        await #expect(processExitsWith: .success) {
            let at = Date(timeIntervalSince1970: 1_793_800_000)
            let old = UsageSample(at: at, totalBytes: 1 << 40, freeBytes: 1 << 39, parts: ["X": Int64.min])
            let new = UsageSample(at: at.addingTimeInterval(86_400), totalBytes: 1 << 40, freeBytes: 1 << 39, parts: ["X": Int64.max])
            _ = Usage.changes(from: old, to: new)
        }
    }
}

// MARK: - 首页那一句

@Suite struct GrowthHeadlineTests {
    @Test func 跨UTC日界仍算昨天() {
        // 期望：北京 11-04 07:59（UTC 11-03）对北京 11-05 08:01，是「昨天」
        let a = rec(bjTime("2026-11-04T07:59:00"), free: 80, ["下载文件夹": 5])
        let b = rec(bjTime("2026-11-05T08:01:00"), free: 78, ["下载文件夹": 7])
        #expect(Usage.headline([a, b], now: b.at) == "比昨天少了 2.0 GB，主要是下载文件夹（+2.0 GB）")
    }

    @Test func 跨年隔几天写日期() {
        // 期望：12/30 对 1/2，写「比 12/30 …」
        let a = rec(bjTime("2026-12-30T10:00:00"), free: 80)
        let b = rec(bjTime("2027-01-02T10:00:00"), free: 79)
        #expect(Usage.headline([a, b], now: b.at)?.hasPrefix("比 12/30 少了 1.0 GB") == true)
    }

    @Test func 差不多阈值_刚好50MB不算差不多() {
        // 期望：可用变化 = 50 MB 时说「少了 50 MB」；49.99… MB 时说「差不多」
        let a = UsageSample(at: bjTime("2026-11-04T10:00:00"), totalBytes: 460 * GB, freeBytes: 80 * GB, parts: [:])
        let b = UsageSample(at: bjTime("2026-11-05T10:00:00"), totalBytes: 460 * GB, freeBytes: 80 * GB - 50 * MB, parts: [:])
        let c = UsageSample(at: bjTime("2026-11-05T10:00:00"), totalBytes: 460 * GB, freeBytes: 80 * GB - 50 * MB + 1, parts: [:])
        #expect(Usage.headline([a, b], now: b.at)?.hasPrefix("比昨天少了 50 MB") == true)
        #expect(Usage.headline([a, c], now: c.at) == "可用空间和昨天差不多")
    }

    @Test func 隔几天差不多时日期两边有空格() {
        // 期望：「可用空间和 11/3 差不多」
        let a = rec(bjTime("2026-11-03T10:00:00"), free: 80)
        let b = rec(bjTime("2026-11-05T10:00:00"), free: 80)
        #expect(Usage.headline([a, b], now: b.at) == "可用空间和 11/3 差不多")
    }

    @Test func 被跟踪的位置都在减_主因是其他() {
        // 期望：可用少了 4 GB，下载文件夹减了 1 GB，那 5 GB 涨在没跟踪的地方
        let a = rec(bjTime("2026-11-04T10:00:00"), free: 80, ["下载文件夹": 5])
        let b = rec(bjTime("2026-11-05T10:00:00"), free: 76, ["下载文件夹": 4])
        #expect(Usage.headline([a, b], now: b.at) == "比昨天少了 4.0 GB，主要是\(Usage.untracked)（+5.0 GB）")
    }

    @Test func 可用变多但没有哪项在减_不写主要是() {
        // 期望：可用多了 2 GB 但排行里没有减少项（比如容量变了），只说多了多少
        let a = rec(bjTime("2026-11-04T10:00:00"), free: 80, total: 460)
        let b = rec(bjTime("2026-11-05T10:00:00"), free: 82, total: 462)
        #expect(Usage.headline([a, b], now: b.at) == "比昨天多了 2.0 GB")
    }

    @Test func 最新记录是很久以前时不应说比昨天() {
        // 期望（有争议）：最新记录是 2020-01-02、前一份 2020-01-01，今天早已不是 1/2；
        // 「比昨天少了…」会让人以为是今天对昨天，应写日期
        let a = rec(bjTime("2020-01-01T10:00:00"), free: 80)
        let b = rec(bjTime("2020-01-02T10:00:00"), free: 77)
        #expect(Usage.headline([a, b], now: bjTime("2026-11-05T12:00:00"))?.hasPrefix("比昨天") == false)
    }
}

// MARK: - 从扫描结果生成记录

@Suite struct GrowthSampleTests {
    @Test func 同项目多个worktree合并_不同项目分开() {
        // 期望：postpane 两个 worktree 合计 14 GB；disk-slim 单独 2 GB
        let r = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1,
                           disk: DiskStatus(totalBytes: 460 * GB, availableBytes: 70 * GB),
                           findings: [hidden("postpane · 48-a", "暂时不能清的构建产物", 8),
                                      hidden("postpane · 46-b", "已合并 worktree 的构建产物", 6),
                                      hidden("disk-slim · x", "已合并 worktree 的构建产物", 2)])
        let s = Usage.sample(from: r)!
        #expect(s.parts == ["postpane · worktree 构建产物": 14 * GB, "disk-slim · worktree 构建产物": 2 * GB])
    }

    @Test func 项目名里带中点时不应和别的项目合并() {
        // 期望：项目目录叫「app · v2」和另一个叫「app」的项目，各算各的，不能都并进「app · worktree 构建产物」
        let r = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1,
                           disk: DiskStatus(totalBytes: 460 * GB, availableBytes: 70 * GB),
                           findings: [hidden("app · v2 · wt1", "已合并 worktree 的构建产物", 3),
                                      hidden("app · wt9", "已合并 worktree 的构建产物", 1)])
        let s = Usage.sample(from: r)!
        #expect(s.parts.count == 2)
    }

    @Test func 多份Codex备份合并_对话记录不并进去() {
        // 期望：Codex 备份 4 + 3 = 7 GB；「Codex 对话记录」单列
        let r = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1,
                           disk: DiskStatus(totalBytes: 460 * GB, availableBytes: 70 * GB),
                           findings: [hidden("Codex 备份 · 0916", "备份快照", 4),
                                      hidden("Codex 备份 · 0907", "备份快照", 3),
                                      hidden("Codex 对话记录", "对话记录", 2)])
        let s = Usage.sample(from: r)!
        #expect(s.parts == ["Codex 备份": 7 * GB, "Codex 对话记录": 2 * GB])
    }

    @Test func 没有磁盘信息不记() {
        // 期望：disk 为 nil 时返回 nil
        let r = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1, disk: nil, findings: [], downloadsBytes: GB)
        #expect(Usage.sample(from: r) == nil)
    }

    @Test func 下载文件夹为空也记0() {
        // 期望：downloadsBytes = 0 时 parts 里有「下载文件夹」= 0
        let r = ScanReport(scannedAt: bjTime("2026-11-05T10:00:00"), seconds: 1,
                           disk: DiskStatus(totalBytes: 460 * GB, availableBytes: 70 * GB), findings: [], downloadsBytes: 0)
        #expect(Usage.sample(from: r)?.parts["下载文件夹"] == 0)
    }
}
