import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct AlertsTests {
    let gb: Int64 = 1_073_741_824

    func bj(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+08:00")! }

    func sample(_ at: Date, free: Double, _ parts: [String: Double] = [:]) -> UsageSample {
        UsageSample(at: at, totalBytes: 460 * gb, freeBytes: Int64(free * Double(gb)), parts: parts.mapValues { Int64($0 * Double(gb)) })
    }

    func finding(_ area: Area, _ category: String, _ path: String, gb size: Double, risk: Risk = .safe,
                 suggested: Bool = true, cleanup: Cleanup = .trash, lastUsed: Date? = nil) -> Finding {
        Finding(area: area, category: category, title: (path as NSString).lastPathComponent, detail: "说明",
                paths: [path], bytes: Int64(size * Double(gb)), risk: risk, suggested: suggested, cleanup: cleanup, lastUsed: lastUsed)
    }

    // MARK: 周报时间

    @Test func 周报是北京时间周五18点() {
        // 2026-11-06 是周五
        #expect(Weekly.nextReport(after: bj("2026-11-05T12:00:00")) == bj("2026-11-06T18:00:00"))
        #expect(Weekly.nextReport(after: bj("2026-11-06T18:00:00")) == bj("2026-11-13T18:00:00"))
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T18:00:00")) == bj("2026-11-06T18:00:00"))
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T17:59:59")) == bj("2026-10-30T18:00:00"))
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-08T09:00:00")) == bj("2026-11-06T18:00:00"))
    }

    // MARK: 卡片

    /// 2026-11-18 起（issue #4）：周报只问首页「要你说一句」里能执行的；替你挑好的、先不动的、只展示的都不进
    @Test func 卡片只问要你说一句的_下载按分组一张_其余每项一张() {
        let now = bj("2026-11-06T18:00:00")
        let fs = [
            finding(.downloads, "安装包", "/d/a.dmg", gb: 1),
            finding(.downloads, "久未打开", "/d/old1.pdf", gb: 1, suggested: false),
            finding(.downloads, "久未打开", "/d/old2.pdf", gb: 2, suggested: false),
            finding(.downloads, "最近下载的大文件", "/d/big.mov", gb: 5, suggested: false, cleanup: .none),
            finding(.hidden, "备份", "/h/backup", gb: 20, risk: .confirm, suggested: false),
            finding(.hidden, "虚拟机", "/h/vm-old", gb: 9, risk: .confirm, suggested: false, lastUsed: now.addingTimeInterval(-40 * 86_400)),
            finding(.hidden, "虚拟机", "/h/vm-new", gb: 9, risk: .confirm, suggested: false, lastUsed: now.addingTimeInterval(-3 * 86_400)),
            finding(.hidden, "缓存", "/h/cache", gb: 9, cleanup: .command(["x"])),
            finding(.hidden, "对话记录", "/h/codex", gb: 30, risk: .readOnly),
        ]
        let cards = Weekly.cards(fs, decisions: Decisions(), now: now)
        #expect(cards.map(\.tag) == ["虚拟机", "久未打开"])
        #expect(cards[1].title == "下载文件夹里 2 个很久没打开的文件")
        #expect(cards[1].bytes == 3 * gb)
        #expect(cards[1].actionLabel == "移到废纸篓")
        #expect(fs.map { $0.bucket(now: now) } == [.picked, .ask, .ask, .keep, .keep, .ask, .keep, .picked, .records])
    }

    @Test func 选过保留的一律先不动() {
        let now = bj("2026-11-06T18:00:00")
        #expect(finding(.downloads, "久未打开", "/d/x", gb: 1, suggested: false).bucket(now: now, kept: true) == .keep)
        #expect(finding(.downloads, "安装包", "/d/a.dmg", gb: 1).bucket(now: now, kept: true) == .keep)
    }

    @Test func 保留的不再问也不再默认勾选_下周再问的到下周五才回来() {
        let now = bj("2026-11-06T18:30:00")
        let a = finding(.downloads, "久未打开", "/d/old.pdf", gb: 1, suggested: false)
        let b = finding(.hidden, "虚拟机", "/h/vm", gb: 20, risk: .confirm, suggested: false, lastUsed: now.addingTimeInterval(-40 * 86_400))
        var d = Decisions()
        let cards = Weekly.cards([a, b], decisions: d, now: now)
        d.keep(cards.first { $0.tag == "久未打开" }!, now: now)
        d.snooze(cards.first { $0.tag == "虚拟机" }!, now: now)
        #expect(Weekly.cards([a, b], decisions: d, now: now).isEmpty)
        #expect(Weekly.cards([a, b], decisions: d, now: bj("2026-11-13T18:00:01")).map(\.tag) == ["虚拟机"])
        // 保留的项扫描时不再默认勾选，也保住最近使用时间
        let c = finding(.downloads, "安装包", "/d/a.dmg", gb: 1, lastUsed: now)
        var k = Decisions()
        k.keep(WeeklyCard(id: "c", tag: "安装包", title: "t", why: "w", findings: [c]), now: now)
        #expect(applyDecisions([c], k).first?.suggested == false)
        #expect(applyDecisions([c], k).first?.lastUsed == now)
        #expect(applyDecisions([c], Decisions()).first?.suggested == true)
    }

    @Test func 决定记录存取() throws {
        let t = TempDir()
        let log = DecisionLog(url: t.url.appendingPathComponent("decisions.json"))
        #expect(log.load() == Decisions())
        var d = Decisions()
        d.kept["安装包|/d/a.dmg"] = Kept(at: bj("2026-11-06T18:00:00"), bytes: 5)
        try log.save(d)
        #expect(log.load() == d)
    }

    // MARK: 提醒

    @Test func 低于30GB发一次_同一天不再发() {
        let now = bj("2026-11-05T12:00:00")
        var state = AlertState()
        let first = Alerts.due(now: now, free: 29 * gb, samples: [], cards: nil, state: state)
        #expect(first.map(\.key) == ["lowSpace"])
        state.sent["lowSpace"] = first[0].day
        #expect(Alerts.due(now: now, free: 20 * gb, samples: [], cards: nil, state: state).isEmpty)
        #expect(Alerts.due(now: bj("2026-11-06T08:00:00"), free: 20 * gb, samples: [], cards: nil, state: state).map(\.key) == ["lowSpace"])
        #expect(Alerts.due(now: now, free: 31 * gb, samples: [], cards: nil, state: AlertState()).isEmpty)
        // 关掉就不发
        var off = AlertState()
        off.settings.lowSpace = false
        #expect(Alerts.due(now: now, free: 20 * gb, samples: [], cards: nil, state: off).isEmpty)
    }

    @Test func 某个位置一天涨超过10GB单独提醒_其他不算() {
        let now = bj("2026-11-05T12:00:00")
        let samples = [
            sample(bj("2026-11-04T12:00:00"), free: 80, ["postpane · worktree 构建产物": 5, "下载文件夹": 2]),
            sample(bj("2026-11-05T11:00:00"), free: 50, ["postpane · worktree 构建产物": 16, "下载文件夹": 11]),
        ]
        let alerts = Alerts.due(now: now, free: 50 * gb, samples: samples, cards: nil, state: AlertState())
        #expect(alerts.map(\.key) == ["growth|postpane · worktree 构建产物"]) // 下载 +9 GB 不到；其他 +10 GB 不算
        #expect(alerts[0].title == "postpane · worktree 构建产物 一天涨了 11.0 GB")
        // 最新记录不是今天（昨天的旧数据）不提醒
        #expect(Alerts.due(now: bj("2026-11-06T12:00:00"), free: 50 * gb, samples: samples, cards: nil, state: AlertState()).isEmpty)
    }

    @Test func 周报_周五18点后发一次_周六打开也补上_没有卡片不发() {
        let card = WeeklyCard(id: "x", tag: "安装包", title: "t", why: "w",
                              findings: [finding(.downloads, "安装包", "/d/a.dmg", gb: 1)])
        #expect(Alerts.due(now: bj("2026-11-06T17:59:00"), free: nil, samples: [], cards: [card],
                           state: { var s = AlertState(); s.sent["weekly"] = "2026-10-30"; return s }()).isEmpty)
        let fri = Alerts.due(now: bj("2026-11-06T18:05:00"), free: nil, samples: [], cards: [card], state: AlertState())
        #expect(fri.map(\.key) == ["weekly"] && fri[0].day == "2026-11-06")
        var state = AlertState()
        state.sent["weekly"] = "2026-11-06"
        #expect(Alerts.due(now: bj("2026-11-07T10:00:00"), free: nil, samples: [], cards: [card], state: state).isEmpty)
        #expect(Alerts.due(now: bj("2026-11-07T10:00:00"), free: nil, samples: [], cards: [card], state: AlertState()).count == 1)
        #expect(Alerts.due(now: bj("2026-11-06T18:05:00"), free: nil, samples: [], cards: [], state: AlertState()).isEmpty)
    }

    @Test func 自动清理_默认关_低于60GB每天一次_只挑看不见的安全项() {
        let now = bj("2026-11-05T12:00:00")
        var state = AlertState()
        #expect(!Alerts.shouldAutoClean(now: now, free: 10 * gb, state: state)) // 默认关
        state.settings.autoClean = true
        #expect(Alerts.shouldAutoClean(now: now, free: 59 * gb, state: state))
        #expect(!Alerts.shouldAutoClean(now: now, free: 61 * gb, state: state))
        #expect(!Alerts.shouldAutoClean(now: now, free: nil, state: state))
        state.autoCleanAt = now.addingTimeInterval(-3600) // 1 小时前跑过：不到 2 小时不再跑
        #expect(!Alerts.shouldAutoClean(now: now, free: 10 * gb, state: state))
        state.autoCleanAt = now.addingTimeInterval(-2 * 3600)
        #expect(Alerts.shouldAutoClean(now: now, free: 10 * gb, state: state))

        let picks = Alerts.autoCleanPicks([
            finding(.downloads, "安装包", "/d/a.dmg", gb: 1),
            finding(.hidden, "缓存", "/h/cache", gb: 1, cleanup: .command(["x"])),
            finding(.hidden, "缓存", "/h/unpicked", gb: 1, suggested: false, cleanup: .command(["x"])),
            finding(.hidden, "备份", "/h/backup", gb: 1, risk: .confirm, suggested: true),
            finding(.hidden, "对话记录", "/h/codex", gb: 1, risk: .readOnly),
        ])
        #expect(picks.map(\.paths) == [["/h/cache"]])
    }

    @Test func 提醒设置读坏了按默认_自动清理不会被打开() throws {
        let t = TempDir()
        let store = AlertStore(url: t.url.appendingPathComponent("alerts.json"))
        try Data("{ broken".utf8).write(to: store.url)
        #expect(store.load().settings.autoClean == false)
        var s = AlertState()
        s.settings.weekly = false
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func 周五18点前点下周再问_跳过当天这次() {
        let card = WeeklyCard(id: "x", tag: "虚拟机", title: "t", why: "w",
                              findings: [finding(.hidden, "虚拟机", "/h/vm", gb: 20, risk: .confirm, suggested: false, lastUsed: bj("2026-09-01T00:00:00"))])
        var d = Decisions()
        d.snooze(card, now: bj("2026-11-06T17:00:00"))
        #expect(Weekly.cards(card.findings, decisions: d, now: bj("2026-11-06T18:00:01")).isEmpty)
        #expect(Weekly.cards(card.findings, decisions: d, now: bj("2026-11-13T18:00:01")).count == 1)
        // 周六点的，到下周五再问，不会拖到下下周
        var e = Decisions()
        e.snooze(card, now: bj("2026-11-07T10:00:00"))
        #expect(Weekly.cards(card.findings, decisions: e, now: bj("2026-11-13T18:00:01")).count == 1)
    }

    @Test func 保留后涨了超过1GB再问() {
        let old = bj("2026-09-01T00:00:00")
        let small = finding(.downloads, "久未打开", "/d/old.pdf", gb: 2, suggested: false, lastUsed: old)
        let card = WeeklyCard(id: "x", tag: "久未打开", title: "t", why: "w", findings: [small])
        var d = Decisions()
        d.keep(card, now: bj("2026-11-06T18:00:00"))
        let now = bj("2026-11-20T18:00:00")
        #expect(Weekly.cards([finding(.downloads, "久未打开", "/d/old.pdf", gb: 2.9, suggested: false)], decisions: d, now: now).isEmpty)
        #expect(Weekly.cards([finding(.downloads, "久未打开", "/d/old.pdf", gb: 3.5, suggested: false)], decisions: d, now: now).count == 1)
    }

    @Test func 废纸篓涨了不报() {
        let samples = [
            sample(bj("2026-11-04T12:00:00"), free: 50, ["下载文件夹": 20, "废纸篓": 0]),
            sample(bj("2026-11-05T11:00:00"), free: 50, ["下载文件夹": 8, "废纸篓": 12]),
        ]
        #expect(Alerts.due(now: bj("2026-11-05T12:00:00"), free: 50 * gb, samples: samples, cards: nil, state: AlertState()).isEmpty)
    }

    @Test func 只有隐私保护拦住才提示授权_不存在和普通权限位都不算() throws {
        let t = TempDir()
        #expect(!blockedByPrivacy(t.url.appendingPathComponent("没有这个目录")))
        let locked = t.dir("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(!blockedByPrivacy(locked)) // EACCES，给完全磁盘访问也没用
        #expect(!blockedByPrivacy(t.url))
        // 沙盒里没有 Downloads 和 .Trash：扫描结果不该要求授权
        #expect(Scan(home: t.url, workRoot: t.url).run().needsAccess == [])
    }

    @Test func 掉得快就马上扫描_离上次扫描不到30分钟不扫() {
        let t0 = bj("2026-11-05T12:00:00")
        #expect(Alerts.shouldRescanForDrop(free: 50 * gb, freeAtScan: 58 * gb, scannedAt: t0, now: t0.addingTimeInterval(1800)))
        #expect(!Alerts.shouldRescanForDrop(free: 51 * gb, freeAtScan: 58 * gb, scannedAt: t0, now: t0.addingTimeInterval(1800)))
        #expect(!Alerts.shouldRescanForDrop(free: 40 * gb, freeAtScan: 58 * gb, scannedAt: t0, now: t0.addingTimeInterval(1700)))
        #expect(!Alerts.shouldRescanForDrop(free: 40 * gb, freeAtScan: nil, scannedAt: nil, now: t0))
    }
}

