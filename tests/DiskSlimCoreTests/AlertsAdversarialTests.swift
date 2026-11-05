import Foundation
import Testing
@testable import DiskSlimCore

// 第 5 批「提醒与每周卡片」的对抗性测试：每个用例只测一件事，注释写期望。
// 日期一律写北京时间（+08:00），2026-11-06、2027-01-01 都是周五。

private let gb: Int64 = 1_073_741_824

private func bj(_ s: String) -> Date { ISO8601DateFormatter().date(from: s + "+08:00")! }

private func usage(_ at: Date, free: Double, _ parts: [String: Double] = [:]) -> UsageSample {
    UsageSample(at: at, totalBytes: 460 * gb, freeBytes: Int64(free * Double(gb)), parts: parts.mapValues { Int64($0 * Double(gb)) })
}

private func item(_ area: Area, _ category: String, _ paths: [String], bytes: Int64 = gb, risk: Risk = .safe,
                  suggested: Bool = true, cleanup: Cleanup = .trash) -> Finding {
    Finding(area: area, category: category, title: paths.first.map { ($0 as NSString).lastPathComponent } ?? "无路径",
            detail: "说明", paths: paths, bytes: bytes, risk: risk, suggested: suggested, cleanup: cleanup)
}

private func card(_ fs: [Finding]) -> WeeklyCard {
    WeeklyCard(id: fs.map(\.id).joined(), tag: fs[0].category, title: "t", why: "w", findings: fs)
}

private func state(sent: [String: String] = [:], _ edit: (inout AlertSettings) -> Void = { _ in }) -> AlertState {
    var s = AlertState()
    s.sent = sent
    edit(&s.settings)
    return s
}

private func writeJSON(_ text: String, name: String, in dir: TempDir) -> URL {
    let u = dir.url.appendingPathComponent(name)
    try! Data(text.utf8).write(to: u)
    return u
}

// MARK: - 周报时间

@Suite struct 周报时间对抗 {
    @Test func 周五17点59分59秒_上一次周报是上周五() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T17:59:59")) == bj("2026-10-30T18:00:00"))
    }

    @Test func 周五18点整_上一次周报就是当下() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T18:00:00")) == bj("2026-11-06T18:00:00"))
    }

    @Test func 周五18点00分01秒_上一次周报是今天18点() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T18:00:01")) == bj("2026-11-06T18:00:00"))
    }

    @Test func 周五18点前差1毫秒_下一次是今天18点() {
        // 带小数秒时 Foundation 的 nextDate 不能把秒截掉后返回过去或当下
        #expect(Weekly.nextReport(after: bj("2026-11-06T18:00:00").addingTimeInterval(-0.001)) == bj("2026-11-06T18:00:00"))
    }

    @Test func 周五18点后1毫秒_下一次是下周五() {
        #expect(Weekly.nextReport(after: bj("2026-11-06T18:00:00").addingTimeInterval(0.001)) == bj("2026-11-13T18:00:00"))
    }

    @Test func 周五18点后1毫秒_上一次是今天18点() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-06T18:00:00").addingTimeInterval(0.001)) == bj("2026-11-06T18:00:00"))
    }

    @Test func 周日_上一次是前天周五() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-08T23:59:59")) == bj("2026-11-06T18:00:00"))
    }

    @Test func 北京周六凌晨_UTC还是周五_上一次是北京周五18点() {
        // 2026-11-07T01:00+08:00 = UTC 周五 17:00，不能被当成「周五 18:00 之前」
        #expect(Weekly.lastReport(atOrBefore: bj("2026-11-07T01:00:00")) == bj("2026-11-06T18:00:00"))
    }

    @Test func 跨年_除夕夜的上一次是12月25日() {
        #expect(Weekly.lastReport(atOrBefore: bj("2026-12-31T23:00:00")) == bj("2026-12-25T18:00:00"))
    }

    @Test func 跨年_除夕夜的下一次是元旦周五18点() {
        #expect(Weekly.nextReport(after: bj("2026-12-31T23:00:00")) == bj("2027-01-01T18:00:00"))
    }
}

// MARK: - 时区：系统默认时区改掉也不影响

@Suite(.serialized) struct 时区对抗 {
    func withZone<T>(_ id: String, _ body: () -> T) -> T {
        let old = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: id)!
        defer { NSTimeZone.default = old }
        return body()
    }

    @Test func 洛杉矶时区下_下一次周报仍是北京周五18点() {
        let next = withZone("America/Los_Angeles") { Weekly.nextReport(after: bj("2026-11-05T12:00:00")) }
        #expect(next == bj("2026-11-06T18:00:00"))
    }

    @Test func 基里巴斯加14时区下_上一次周报仍是北京周五18点() {
        let last = withZone("Pacific/Kiritimati") { Weekly.lastReport(atOrBefore: bj("2026-11-07T01:00:00")) }
        #expect(last == bj("2026-11-06T18:00:00"))
    }

    @Test func 洛杉矶时区下_周报记的日期是北京的周五() {
        let c = card([item(.downloads, "安装包", ["/d/a.dmg"])])
        let alerts = withZone("America/Los_Angeles") {
            Alerts.due(now: bj("2026-11-07T01:00:00"), free: nil, samples: [], cards: [c], state: AlertState())
        }
        #expect(alerts.map(\.day) == ["2026-11-06"])
    }

    @Test func 洛杉矶时区下_自动清理按北京日期判断今天跑过没有() {
        // 北京 11-06 01:00 已经是新的一天，记的是 11-05，应该能跑
        let s = state { $0.autoClean = true }
        var st = s
        st.autoCleanDay = "2026-11-05"
        let ok = withZone("America/Los_Angeles") { Alerts.shouldAutoClean(now: bj("2026-11-06T01:00:00"), free: 10 * gb, state: st) }
        #expect(ok)
    }
}

// MARK: - 周报提醒

@Suite struct 周报提醒对抗 {
    let c = card([item(.downloads, "安装包", ["/d/a.dmg"])])

    @Test func 周五17点59分59秒不发() {
        #expect(Alerts.due(now: bj("2026-11-06T17:59:59"), free: nil, samples: [], cards: [c],
                           state: state(sent: ["weekly": "2026-10-30"])).isEmpty)
    }

    @Test func 周五18点整发_记当天日期() {
        let a = Alerts.due(now: bj("2026-11-06T18:00:00"), free: nil, samples: [], cards: [c], state: state(sent: ["weekly": "2026-10-30"]))
        #expect(a.map(\.day) == ["2026-11-06"])
    }

    @Test func 周日补发_记的是周五() {
        let a = Alerts.due(now: bj("2026-11-08T20:00:00"), free: nil, samples: [], cards: [c], state: state(sent: ["weekly": "2026-10-30"]))
        #expect(a.map(\.day) == ["2026-11-06"])
    }

    @Test func 本周已发_下周五17点59分不发() {
        #expect(Alerts.due(now: bj("2026-11-13T17:59:00"), free: nil, samples: [], cards: [c],
                           state: state(sent: ["weekly": "2026-11-06"])).isEmpty)
    }

    @Test func 本周已发_刚好下周五18点再发() {
        let a = Alerts.due(now: bj("2026-11-13T18:00:00"), free: nil, samples: [], cards: [c], state: state(sent: ["weekly": "2026-11-06"]))
        #expect(a.map(\.day) == ["2026-11-13"])
    }

    @Test func 跨年_元旦周五18点发_记2027_01_01() {
        let a = Alerts.due(now: bj("2027-01-01T18:00:00"), free: nil, samples: [], cards: [c], state: state(sent: ["weekly": "2026-12-25"]))
        #expect(a.map(\.day) == ["2027-01-01"])
    }

    @Test func 从没发过_周三装好也补发上周五的() {
        // 「最近一个已到点的周五 18:00 之后还没发过」：没发过就补
        let a = Alerts.due(now: bj("2026-11-04T10:00:00"), free: nil, samples: [], cards: [c], state: AlertState())
        #expect(a.map(\.day) == ["2026-10-30"])
    }

    @Test func 卡片为空数组不发() {
        #expect(Alerts.due(now: bj("2026-11-06T18:00:00"), free: nil, samples: [], cards: [], state: AlertState()).isEmpty)
    }

    @Test func 卡片为nil不发() {
        #expect(Alerts.due(now: bj("2026-11-06T18:00:00"), free: nil, samples: [], cards: nil, state: AlertState()).isEmpty)
    }

    @Test func 周报开关关掉不发() {
        #expect(Alerts.due(now: bj("2026-11-06T18:00:00"), free: nil, samples: [], cards: [c],
                           state: state { $0.weekly = false }).isEmpty)
    }
}

// MARK: - 低空间

@Suite struct 低空间对抗 {
    let t = bj("2026-11-05T12:00:00")

    @Test func 刚好30GB不发() {
        #expect(Alerts.due(now: t, free: 30 * gb, samples: [], cards: nil, state: AlertState()).isEmpty)
    }

    @Test func 比30GB少1字节就发() {
        #expect(Alerts.due(now: t, free: 30 * gb - 1, samples: [], cards: nil, state: AlertState()).map(\.key) == ["lowSpace"])
    }

    @Test func free为nil不发() {
        #expect(Alerts.due(now: t, free: nil, samples: [], cards: nil, state: AlertState()).isEmpty)
    }

    @Test func free为0发() {
        #expect(Alerts.due(now: t, free: 0, samples: [], cards: nil, state: AlertState()).map(\.key) == ["lowSpace"])
    }

    @Test func 昨天发过_北京过了零点今天再发() {
        // UTC 还是 11-05，北京已经 11-06 00:30
        let a = Alerts.due(now: bj("2026-11-06T00:30:00"), free: 1 * gb, samples: [], cards: nil,
                           state: state(sent: ["lowSpace": "2026-11-05"]))
        #expect(a.map(\.day) == ["2026-11-06"])
    }
}

// MARK: - 涨幅提醒

@Suite struct 涨幅提醒对抗 {
    let t = bj("2026-11-05T12:00:00")
    let name = "postpane · worktree 构建产物"

    func due(_ samples: [UsageSample], state s: AlertState = AlertState(), at: Date? = nil) -> [String] {
        Alerts.due(now: at ?? t, free: 100 * gb, samples: samples, cards: nil, state: s).map(\.key)
    }

    @Test func 刚好涨10GB不算超过() {
        // 期望按 PRD「一天涨超过 10 GB」理解为严格大于
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 90, [name: 15])]
        #expect(due(s).isEmpty)
    }

    @Test func 涨10GB多1字节发() {
        let old = UsageSample(at: bj("2026-11-04T12:00:00"), totalBytes: 460 * gb, freeBytes: 100 * gb, parts: [name: 5 * gb])
        let new = UsageSample(at: bj("2026-11-05T11:00:00"), totalBytes: 460 * gb, freeBytes: 90 * gb - 1, parts: [name: 15 * gb + 1])
        #expect(due([old, new]) == ["growth|" + name])
    }

    @Test func 其他涨50GB也不发() {
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 50, [name: 5])]
        #expect(due(s).isEmpty)
    }

    @Test func 缺昨天_今天和前天比不发() {
        let s = [usage(bj("2026-11-03T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 80, [name: 25])]
        #expect(due(s).isEmpty)
    }

    @Test func 今天还没有记录_昨天和前天比不发() {
        let s = [usage(bj("2026-11-03T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-04T11:00:00"), free: 80, [name: 25])]
        #expect(due(s).isEmpty)
    }

    @Test func 跨北京零点的两份记录算相邻两天() {
        let s = [usage(bj("2026-11-04T23:59:59"), free: 100, [name: 5]), usage(bj("2026-11-05T00:00:01"), free: 80, [name: 25])]
        #expect(due(s, at: bj("2026-11-05T00:10:00")) == ["growth|" + name])
    }

    @Test func 同一天两份记录不算一天涨() {
        let s = [usage(bj("2026-11-05T01:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 80, [name: 25])]
        #expect(due(s).isEmpty)
    }

    @Test func 今天已发过同一位置不再发() {
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 80, [name: 25])]
        #expect(due(s, state: state(sent: ["growth|" + name: "2026-11-05"])).isEmpty)
    }

    @Test func 下载文件夹只在今天出现20GB不发() {
        // 只在一边出现的下载文件夹是「昨天读不了」，不能算涨
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [:]), usage(bj("2026-11-05T11:00:00"), free: 100, [Usage.downloads: 20])]
        #expect(due(s).isEmpty)
    }

    @Test func 涨幅开关关掉不发() {
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 80, [name: 25])]
        #expect(due(s, state: state { $0.growth = false }).isEmpty)
    }

    @Test func 未来时间的记录不当作今天() {
        // 时钟被往回调：有一份「明天」的记录，今天的照常和昨天比
        let s = [usage(bj("2026-11-04T12:00:00"), free: 100, [name: 5]), usage(bj("2026-11-05T11:00:00"), free: 80, [name: 25]),
                 usage(bj("2026-11-06T11:00:00"), free: 80, [name: 25])]
        #expect(due(s) == ["growth|" + name])
    }
}

// MARK: - 自动清理

@Suite struct 自动清理对抗 {
    let t = bj("2026-11-05T12:00:00")
    let on = state { $0.autoClean = true }

    @Test func 刚好60GB不跑() {
        #expect(!Alerts.shouldAutoClean(now: t, free: 60 * gb, state: on))
    }

    @Test func 比60GB少1字节就跑() {
        #expect(Alerts.shouldAutoClean(now: t, free: 60 * gb - 1, state: on))
    }

    @Test func 昨天跑过今天还能跑() {
        var s = on
        s.autoCleanDay = "2026-11-04"
        #expect(Alerts.shouldAutoClean(now: t, free: 10 * gb, state: s))
    }

    @Test func 默认状态下空间再少也不跑() {
        #expect(!Alerts.shouldAutoClean(now: t, free: 0, state: AlertState()))
    }

    @Test func 不挑下载文件夹里安全默认勾选的项() {
        #expect(Alerts.autoCleanPicks([item(.downloads, "安装包", ["/d/a.dmg"])]).isEmpty)
    }

    @Test func 不挑需确认的项_即使默认勾选() {
        #expect(Alerts.autoCleanPicks([item(.hidden, "备份", ["/h/b"], risk: .confirm, suggested: true)]).isEmpty)
    }

    @Test func 不挑只展示的项() {
        #expect(Alerts.autoCleanPicks([item(.hidden, "对话记录", ["/h/c"], risk: .readOnly, suggested: true, cleanup: .remove)]).isEmpty)
    }

    @Test func 不挑没有清理方式的项() {
        #expect(Alerts.autoCleanPicks([item(.hidden, "缓存", ["/h/c"], cleanup: .none)]).isEmpty)
    }

    @Test func 挑看不见的安全默认勾选的构建产物() {
        #expect(Alerts.autoCleanPicks([item(.hidden, "worktree 构建产物", ["/w/target"], cleanup: .remove)]).count == 1)
    }

    @Test func 保留过的缓存不再被自动清理挑中() {
        let f = item(.hidden, "缓存", ["/h/cache"], cleanup: .command(["x"]))
        let d = Decisions(kept: [f.id: Kept(at: bj("2026-11-01T00:00:00"), bytes: f.bytes)])
        #expect(Alerts.autoCleanPicks(applyDecisions([f], d)).isEmpty)
    }

    @Test func 空命令不算有清理方式() {
        // 期望有争议：command([]) 实际没法执行，不该被挑
        #expect(Alerts.autoCleanPicks([item(.hidden, "缓存", ["/h/c"], cleanup: .command([]))]).isEmpty)
    }
}

// MARK: - 卡片

@Suite struct 卡片对抗 {
    let t = bj("2026-11-06T18:00:00")

    @Test func 安全的看不见的缓存不进卡片() {
        #expect(Weekly.cards([item(.hidden, "缓存", ["/h/cache"], cleanup: .command(["x"]))], decisions: Decisions(), now: t).isEmpty)
    }

    @Test func 没勾选的安全缓存也不进卡片() {
        #expect(Weekly.cards([item(.hidden, "缓存", ["/h/cache"], suggested: false, cleanup: .command(["x"]))],
                             decisions: Decisions(), now: t).isEmpty)
    }

    @Test func 需确认但没有清理方式的不进卡片() {
        #expect(Weekly.cards([item(.hidden, "备份", ["/h/b"], risk: .confirm, cleanup: .none)], decisions: Decisions(), now: t).isEmpty)
    }

    @Test func 只展示的下载项不进卡片() {
        #expect(Weekly.cards([item(.downloads, "安装包", ["/d/a.dmg"], risk: .readOnly)], decisions: Decisions(), now: t).isEmpty)
    }

    @Test func 下载里需确认的项也按分组进卡片() {
        let cards = Weekly.cards([item(.downloads, "久未打开", ["/d/x"], risk: .confirm, suggested: false)], decisions: Decisions(), now: t)
        #expect(cards.map(\.id) == ["downloads|久未打开"])
    }

    @Test func 需确认的看不见的每项一张() {
        let cards = Weekly.cards([item(.hidden, "备份", ["/h/b1"], risk: .confirm), item(.hidden, "备份", ["/h/b2"], risk: .confirm)],
                                 decisions: Decisions(), now: t)
        #expect(cards.count == 2)
    }

    @Test func 分组部分保留_新来的项单独成卡() {
        var d = Decisions()
        let a = item(.downloads, "安装包", ["/d/a.dmg"]), b = item(.downloads, "安装包", ["/d/b.dmg"])
        d.keep(Weekly.cards([a, b], decisions: d, now: t)[0], now: t)
        let c = item(.downloads, "安装包", ["/d/c.dmg"], bytes: 3 * gb)
        let cards = Weekly.cards([a, b, c], decisions: d, now: t)
        #expect(cards.map(\.paths) == [["/d/c.dmg"]])
    }

    @Test func 多路径的项_保留记录对不上这一项时仍然要问() {
        // 第 5 批审查后改为按项（分组 + 路径）记；只保留过其中一个路径的旧记录不算这一项
        let f = item(.hidden, "备份", ["/h/p1", "/h/p2"], risk: .confirm)
        let d = Decisions(kept: ["备份|/h/p1": Kept(at: t, bytes: f.bytes)])
        #expect(Weekly.cards([f], decisions: d, now: t).count == 1)
    }

    @Test func 同一路径在两张卡_按项记_另一张还会问() {
        // 第 5 批审查后改为按项（分组 + 路径）记：换了分组算另一件事。现有扫描器不会让同一路径出现在两个分组
        let x = item(.hidden, "备份", ["/h/x"], risk: .confirm)
        let y = item(.hidden, "虚拟机", ["/h/x"], risk: .confirm)
        var d = Decisions()
        d.keep(card([x]), now: t)
        #expect(Weekly.cards([x, y], decisions: d, now: t).map(\.tag) == ["虚拟机"])
    }

    @Test func 先下周再问再保留_保留生效() {
        let x = item(.hidden, "备份", ["/h/x"], risk: .confirm)
        var d = Decisions()
        d.snooze(card([x]), now: t)
        d.keep(card([x]), now: t)
        #expect(d.isKept(x) && d.snoozed[x.id] == nil)
    }

    @Test func 先保留再在另一张卡下周再问_仍是保留() {
        let x = item(.hidden, "备份", ["/h/x"], risk: .confirm)
        var d = Decisions()
        d.keep(card([x]), now: t)
        d.snooze(card([item(.hidden, "虚拟机", ["/h/x"], risk: .confirm)]), now: t)
        // 下周五过后也不再问
        #expect(Weekly.cards([x], decisions: d, now: bj("2026-11-20T18:00:00")).isEmpty)
    }

    @Test func 空路径的项点保留后不再出现() {
        // 保留=以后不问；空路径的项要么不进卡片，要么点了保留就消失，不能每周都问
        let f = item(.hidden, "备份", [], risk: .confirm)
        var d = Decisions()
        for c in Weekly.cards([f], decisions: d, now: t) { d.keep(c, now: t) }
        #expect(Weekly.cards([f], decisions: d, now: t).isEmpty)
    }

    @Test func 空路径的项点下周再问后本周不再出现() {
        let f = item(.hidden, "备份", [], risk: .confirm)
        var d = Decisions()
        for c in Weekly.cards([f], decisions: d, now: t) { d.snooze(c, now: t) }
        #expect(Weekly.cards([f], decisions: d, now: t.addingTimeInterval(60)).isEmpty)
    }

    @Test func 卡片按大小从大到小() {
        let cards = Weekly.cards([item(.downloads, "安装包", ["/d/a.dmg"], bytes: 1 * gb),
                                  item(.hidden, "备份", ["/h/b"], bytes: 5 * gb, risk: .confirm)], decisions: Decisions(), now: t)
        #expect(cards.map(\.bytes) == [5 * gb, 1 * gb])
    }
}

// MARK: - 保留 / 下周再问

@Suite struct 决定对抗 {
    let x = item(.hidden, "备份", ["/h/x"], risk: .confirm)

    func cards(after snoozeAt: Date, at: Date) -> Int {
        var d = Decisions()
        d.snooze(card([x]), now: snoozeAt)
        return Weekly.cards([x], decisions: d, now: at).count
    }

    @Test func 周五18点整点下周再问_下周五18点前不问() {
        #expect(cards(after: bj("2026-11-06T18:00:00"), at: bj("2026-11-13T17:59:59")) == 0)
    }

    @Test func 周五18点整点下周再问_下周五18点整回来() {
        #expect(cards(after: bj("2026-11-06T18:00:00"), at: bj("2026-11-13T18:00:00")) == 1)
    }

    @Test func 周日点下周再问_下周五18点回来() {
        #expect(cards(after: bj("2026-11-08T10:00:00"), at: bj("2026-11-13T18:00:00")) == 1)
    }

    @Test func 周日点下周再问_下周五17点59分还不问() {
        #expect(cards(after: bj("2026-11-08T10:00:00"), at: bj("2026-11-13T17:59:59")) == 0)
    }

    @Test func 跨年_除夕点下周再问_元旦18点回来() {
        #expect(cards(after: bj("2026-12-31T20:00:00"), at: bj("2027-01-01T18:00:00")) == 1)
    }

    @Test func 周五下午点下周再问_当天18点的周报不再问() {
        // 期望有争议：「下周再问」在周五 17:59 点，按字面是「到下一个周五 18:00」= 一分钟后；按用户意图应该是下周
        #expect(cards(after: bj("2026-11-06T17:59:00"), at: bj("2026-11-06T18:00:00")) == 0)
    }

    @Test func 保留的项扫描时不默认勾选且说明写明() {
        let f = item(.downloads, "安装包", ["/d/a.dmg"])
        let out = applyDecisions([f], Decisions(kept: [f.id: Kept(at: bj("2026-11-01T00:00:00"), bytes: f.bytes)]))[0]
        #expect(!out.suggested && out.detail.hasPrefix("你选过保留"))
    }

    @Test func 保留决定应用两次说明不重复加前缀() {
        let f = item(.downloads, "安装包", ["/d/a.dmg"])
        let d = Decisions(kept: [f.id: Kept(at: bj("2026-11-01T00:00:00"), bytes: f.bytes)])
        #expect(applyDecisions(applyDecisions([f], d), d)[0].detail == "你选过保留 · 说明")
    }

    @Test func 下周再问的项扫描时仍保持默认勾选() {
        // 下周再问只影响卡片，不影响勾选
        let f = item(.downloads, "安装包", ["/d/a.dmg"])
        #expect(applyDecisions([f], Decisions(snoozed: [f.id: bj("2026-11-13T18:00:00")]))[0].suggested)
    }

    @Test func 保留后id不变() {
        let f = item(.downloads, "安装包", ["/d/a.dmg"])
        #expect(applyDecisions([f], Decisions(kept: [f.id: Kept(at: bj("2026-11-01T00:00:00"), bytes: f.bytes)]))[0].id == f.id)
    }
}

// MARK: - alerts.json 读写

@Suite struct 提醒设置文件对抗 {
    let full = #"{"settings":{"lowSpace":false,"growth":true,"weekly":true,"autoClean":false},"sent":{"lowSpace":"2026-11-05"}}"#

    @Test func 完整文件里的未知字段忽略_其他照读() {
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":false,"growth":true,"weekly":true,"autoClean":true,"x":1},"sent":{},"新字段":[1]}"#,
                          name: "alerts.json", in: d)
        let s = AlertStore(url: u).load()
        #expect(s.settings.autoClean && !s.settings.lowSpace)
    }

    @Test func 空文件按默认_自动清理关() {
        let d = TempDir()
        #expect(AlertStore(url: writeJSON("", name: "alerts.json", in: d)).load() == AlertState())
    }

    @Test func 内容是null按默认() {
        let d = TempDir()
        #expect(AlertStore(url: writeJSON("null", name: "alerts.json", in: d)).load() == AlertState())
    }

    @Test func autoClean是字符串true也不打开() {
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":true,"growth":true,"weekly":true,"autoClean":"true"},"sent":{}}"#, name: "alerts.json", in: d)
        #expect(AlertStore(url: u).load().settings.autoClean == false)
    }

    @Test func autoClean是null也不打开() {
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":true,"growth":true,"weekly":true,"autoClean":null},"sent":{}}"#, name: "alerts.json", in: d)
        #expect(AlertStore(url: u).load().settings.autoClean == false)
    }

    @Test func autoClean字段缺失_自动清理关() {
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":false,"growth":true,"weekly":true},"sent":{}}"#, name: "alerts.json", in: d)
        #expect(AlertStore(url: u).load().settings.autoClean == false)
    }

    @Test func autoClean字段缺失_用户关掉的低空间提醒不被重新打开() {
        // 旧版本写的文件少一个开关时，其余开关应照读，不能整份重置成默认
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":false,"growth":true,"weekly":true},"sent":{}}"#, name: "alerts.json", in: d)
        #expect(AlertStore(url: u).load().settings.lowSpace == false)
    }

    @Test func sent字段缺失_开关照读() {
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":false,"growth":true,"weekly":true,"autoClean":false}}"#, name: "alerts.json", in: d)
        #expect(AlertStore(url: u).load().settings.lowSpace == false)
    }

    @Test func 某个开关缺失_今天已发过的低空间提醒不重发() {
        // 缺一个开关导致整份重置时，sent 也丢了，同一天会重复发通知
        let d = TempDir()
        let u = writeJSON(#"{"settings":{"lowSpace":true,"growth":true,"weekly":true},"sent":{"lowSpace":"2026-11-05"}}"#, name: "alerts.json", in: d)
        let s = AlertStore(url: u).load()
        #expect(Alerts.due(now: bj("2026-11-05T15:00:00"), free: 10 * gb, samples: [], cards: nil, state: s).isEmpty)
    }

    @Test func 完整文件存取一致() throws {
        let d = TempDir()
        let store = AlertStore(url: writeJSON(full, name: "alerts.json", in: d))
        var s = store.load()
        #expect(s.sent["lowSpace"] == "2026-11-05" && !s.settings.lowSpace)
        s.autoCleanDay = "2026-11-05"
        try store.save(s)
        #expect(store.load() == s)
    }
}

// MARK: - decisions.json 读写

@Suite struct 决定文件对抗 {
    @Test func 坏文件读出来当没有决定() {
        let d = TempDir()
        #expect(DecisionLog(url: writeJSON("{ broken", name: "decisions.json", in: d)).load() == Decisions())
    }

    @Test func 缺snoozed字段_保留照读() {
        // 只有 kept 的文件（手改或旧版本）不能把所有保留丢掉
        let d = TempDir()
        let u = writeJSON(#"{"kept":{"安装包|/d/a.dmg":{"at":"2026-11-01T00:00:00Z","bytes":5}}}"#, name: "decisions.json", in: d)
        #expect(DecisionLog(url: u).load().kept["安装包|/d/a.dmg"] != nil)
    }

    @Test func 某个下周再问的日期坏了_保留的项不会重新被默认勾选() {
        // 代码注释说「读不出来最坏是多问一次，不会多删」；但整份丢弃会让保留的下载项重新默认勾选，首页「清理建议项」会把它移走
        let d = TempDir()
        let u = writeJSON(#"{"kept":{"安装包|/d/a.dmg":{"at":"2026-11-01T00:00:00Z","bytes":5}},"snoozed":{"备份|/h/x":"下周五"}}"#, name: "decisions.json", in: d)
        let f = item(.downloads, "安装包", ["/d/a.dmg"])
        #expect(applyDecisions([f], DecisionLog(url: u).load())[0].suggested == false)
    }

    @Test func 带小数秒的日期也能读() {
        let d = TempDir()
        let u = writeJSON(#"{"kept":{"安装包|/d/a.dmg":{"at":"2026-11-01T00:00:00.123Z","bytes":5}},"snoozed":{}}"#, name: "decisions.json", in: d)
        #expect(DecisionLog(url: u).load().kept["安装包|/d/a.dmg"] != nil)
    }

    @Test func 坏文件被下一次保存覆盖前先留底() throws {
        // 期望有争议：PRD 第 5 节「日志损坏时先留底不覆盖」写的是操作日志；决定记录同样是用户数据
        let d = TempDir()
        let u = writeJSON("{ broken", name: "decisions.json", in: d)
        let log = DecisionLog(url: u)
        var dec = log.load()
        dec.kept["安装包|/d/b.dmg"] = Kept(at: bj("2026-11-06T18:00:00"), bytes: 5)
        try log.save(dec)
        let names = try FileManager.default.contentsOfDirectory(atPath: d.url.path)
        #expect(names.count > 1)
    }

    @Test func 保存后路径里的斜杠和中文原样读回() throws {
        let d = TempDir()
        let log = DecisionLog(url: d.url.appendingPathComponent("decisions.json"))
        let dec = Decisions(kept: ["安装包|/Users/n/下载/安 装.dmg": Kept(at: bj("2026-11-06T18:00:00"), bytes: 5)],
                            snoozed: ["备份|/h/x": bj("2026-11-13T18:00:00")])
        try log.save(dec)
        #expect(log.load() == dec)
    }
}

// MARK: - 接进扫描

@Suite struct 扫描接入决定对抗 {
    @Test func 卡片上点保留后_下次扫描该安装包不再默认勾选() throws {
        let box = TempDir()
        let home = box.dir("home")
        box.file("home/Downloads/old.dmg", bytes: 4096)
        let t = bj("2026-11-06T18:00:00")
        let meta = FakeMetadata(added: ["old.dmg": t.addingTimeInterval(-30 * 86_400)])
        let scan = Scan(home: home, workRoot: home.appendingPathComponent("work"), meta: meta, runner: FakeRunner())
        let first = scan.run(now: t)
        #expect(first.findings.first { $0.category == "安装包" }?.suggested == true)
        var d = DecisionLog.standard(home: home).load()
        for c in Weekly.cards(first.findings, decisions: d, now: t) { d.keep(c, now: t) }
        try DecisionLog.standard(home: home).save(d)
        let second = scan.run(now: t)
        #expect(second.findings.first { $0.category == "安装包" }?.suggested == false)
    }

    @Test func 卡片上点保留后_下次扫描的卡片里没有它() throws {
        let box = TempDir()
        let home = box.dir("home")
        box.file("home/Downloads/old.dmg", bytes: 4096)
        let t = bj("2026-11-06T18:00:00")
        let meta = FakeMetadata(added: ["old.dmg": t.addingTimeInterval(-30 * 86_400)])
        let scan = Scan(home: home, workRoot: home.appendingPathComponent("work"), meta: meta, runner: FakeRunner())
        var d = Decisions()
        for c in Weekly.cards(scan.run(now: t).findings, decisions: d, now: t) { d.keep(c, now: t) }
        try DecisionLog.standard(home: home).save(d)
        let again = scan.run(now: t)
        #expect(Weekly.cards(again.findings, decisions: DecisionLog.standard(home: home).load(), now: t).isEmpty)
    }
}
