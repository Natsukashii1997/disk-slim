import Foundation
import Testing
@testable import DiskSlimCore

/// 第四批 ③ `diskslim doctor` 与 ⑨ 打包写入的版本信息：每一项在沙盒里各钉住「正常 / 要留意 / 有问题」
@Suite struct DoctorTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }
    var app: URL { t.url.appendingPathComponent("DiskSlim.app") }
    /// 2025-11-21 12:40 北京时间
    let at = Date(timeIntervalSince1970: 1_763_700_000)

    func doctor(_ runner: FakeRunner = FakeRunner(), login: String? = "/usr/bin") -> Doctor {
        Doctor(home: home, app: app, runner: runner, loginPath: { login })
    }

    func writeInfo(_ dict: [String: Any]) throws {
        let dir = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))
    }

    func record(_ name: String, _ text: String) throws {
        let dir = home.appendingPathComponent("Library/Application Support/disk-slim")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    @Test func 版本_有提交号_没提交号_没装() throws {
        #expect(doctor().version().level == .bad)
        try writeInfo(["CFBundleShortVersionString": "0.1.0"])
        #expect(doctor().version() == DoctorCheck("已装版本", .warn, "0.1.0，没写提交号（第四批之前打的包）"))
        try writeInfo(["CFBundleShortVersionString": "0.1.0", "DiskSlimCommit": "abc1234", "DiskSlimBuiltAt": "2025-11-21T04:40:00Z"])
        let v = doctor().version()
        #expect(v.level == .ok && v.detail.hasPrefix("0.1.0（提交 abc1234）") && v.detail.contains("12:40"), "\(v.detail)")
        #expect(AppBuild.label(["CFBundleShortVersionString": "0.1.0", "DiskSlimCommit": "abc1234"]) == "0.1.0 · 提交 abc1234")
        #expect(AppBuild.label(nil) == "调试版")
    }

    @Test func 应用在不在跑() {
        let r = FakeRunner()
        #expect(doctor(r).running().level == .bad)
        r.on(0, "733\n") { a, _ in a == ["pgrep", "-x", "DiskSlimApp"] }
        #expect(doctor(r).running().level == .ok)
    }

    @Test func 状态文件_新_旧_坏_没有() throws {
        #expect(doctor().status(now: at).level == .bad)
        let fresh = StatusFile(disk: DiskStatus(totalBytes: 10, availableBytes: 5), now: at.addingTimeInterval(-300))
        try record("status.json", String(decoding: try fresh.encoded(), as: UTF8.self))
        #expect(doctor().status(now: at).level == .ok)
        #expect(doctor().status(now: at.addingTimeInterval(15 * 60)).level == .warn, "超过 15 分钟没更新")
        try record("status.json", "{ broken")
        #expect(doctor().status(now: at).level == .bad)
    }

    @Test func 记录文件_没有算正常_坏了算有问题_坏文件不挪() throws {
        #expect(doctor().records().allSatisfy { $0.level == .ok })
        try record("usage.json", "[]")
        try record("history.json", "{ broken")
        let checks = doctor().records()
        #expect(checks.first { $0.name == "记录：操作记录" }?.level == .bad)
        #expect(checks.first { $0.name == "记录：每日空间" }?.level == .ok)
        let dir = home.appendingPathComponent("Library/Application Support/disk-slim")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["history.json", "usage.json"])
    }

    @Test func 提醒送达_只认系统收下的记录_不看sent() throws {
        #expect(doctor().alerts(now: at).level == .warn)
        // 首次运行预填、周报没卡片都会写 sent，和发没发出去无关：哪怕是今天也不算送达（审查必须修 1）
        try record("alerts.json", #"{"sent":{"weekly":"2025-11-21"},"settings":{"autoClean":false,"growth":true,"lowSpace":true,"weekly":true}}"#)
        #expect(doctor().alerts(now: at).level == .warn)
        try record("alerts.json", #"{"deliveredAt":"2025-11-05T04:40:00Z","sent":{"weekly":"2025-11-21"}}"#)
        let old = doctor().alerts(now: at)
        #expect(old.level == .warn && old.detail.contains("16 天"), "\(old.detail)")
        #expect(doctor().alerts(now: BeijingTime.date(dayKey: "2025-11-19")!).level == .ok)
        // 新字段写得进、读得回
        var s = AlertState()
        s.deliveredAt = at
        let store = AlertStore(url: t.url.appendingPathComponent("a.json"))
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func 清理命令按应用的PATH找_和登录shell() {
        let r = FakeRunner()
        // 查的是应用从访达启动时的 PATH（短 PATH + 登录 shell 的），不是终端自己的（审查必须修 2）
        r.on(0, "/opt/homebrew/bin/npm\n") { a, _ in a == ["/usr/bin/env", "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/u/.local/bin:/opt/homebrew/bin:/usr/local/bin", "which", "npm"] }
        let tools = doctor(r).tools("/u/.local/bin")
        // 已知位置表里的四个清理命令各查一次，不重复
        #expect(tools.map(\.name) == ["清理命令 npm", "清理命令 uv", "清理命令 pnpm", "清理命令 pip3"])
        #expect(tools[0] == DoctorCheck("清理命令 npm", .ok, "/opt/homebrew/bin/npm"))
        #expect(tools.dropFirst().allSatisfy { $0.level == .warn })
        #expect(doctor().loginShell(nil).level == .warn)
        #expect(doctor().loginShell("/usr/bin").level == .ok)
    }

    @Test func 只读_跑完一遍不多出任何文件() throws {
        try record("alerts.json", "{ broken")
        _ = doctor().run(now: at)
        let dir = home.appendingPathComponent("Library/Application Support/disk-slim")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["alerts.json"])
    }
}
