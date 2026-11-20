import Foundation
import Testing
@testable import DiskSlimCore

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct SizeAdversarialTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }
    var work: URL { t.url.appendingPathComponent("home/work") }
    var trash: URL { t.url.appendingPathComponent("Trash") }
    let fm = FileManager.default

    func cleaner(_ run: FakeRunner = FakeRunner()) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: work), runner: run, trasher: FakeTrasher(dir: trash),
                log: .standard(home: home))
    }

    func finding(_ paths: [String], _ cleanup: Cleanup, risk: Risk = .safe) -> Finding {
        Finding(area: .hidden, category: "测试", title: "x", detail: "", paths: paths, bytes: 1,
                risk: risk, suggested: true, cleanup: cleanup)
    }

    // MARK: - 大小

    @Test func 指向目录的符号链接_大小不该算目标目录() throws {
        t.file("outside/big.bin", bytes: 1_000_000)
        t.dir("home/Downloads")
        let link = home.appendingPathComponent("Downloads/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: t.url.appendingPathComponent("outside"))
        #expect(allocatedSize(link) < 100_000, "符号链接被算成了目标目录的大小：\(allocatedSize(link))")
    }
}

// 以下来自第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题当时还在。
/// 改进程环境变量，必须串行
@Suite(.serialized) struct ProcessRunnerLocaleTests {
    /// 期望：从访达或登录项启动的应用没有 LANG / LC_*（实测已装的 /Applications/DiskSlim.app 进程就没有），
    /// 这时也要认出命令行里带着 target 路径的进程，正在用的构建产物不删（PRD 4.2「无编译进程在用」）。
    /// 实际：`ps` 在 C 区域设置下把路径里的「个人」转义成 `M-dM-8…`（同 L-09），字符串永远对不上，照删不误。
    @Test func 没有区域设置时_正在使用的构建产物不该被删() throws {
        let t = TempDir()
        let home = t.url.appendingPathComponent("个人/home")
        let target = t.dir("个人/home/work/proj/.claude/worktrees/wt/target")
        let server = t.file("个人/home/work/proj/.claude/worktrees/wt/target/debug/server", bytes: 4096)

        let names = ["LC_ALL", "LANG", "LC_CTYPE"]
        let saved = names.map { name in (name, getenv(name).map { String(cString: $0) }) }
        names.forEach { unsetenv($0) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } } }

        // 相当于 target/debug/server 正在运行
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "sleep 30", server.path]
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)

        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: ProcessRunner(),
                        trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "proj · wt", detail: "",
                        paths: [target.path], bytes: 1, risk: .safe, suggested: true, cleanup: .remove)
        _ = c.clean([f])
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}

@Suite struct FormatTests {
    @Test func 日期按北京时间显示() {
        // 2026-10-05 17:00 UTC 是北京时间 10 月 6 日凌晨 1 点
        let d = ISO8601DateFormatter().date(from: "2026-10-05T17:00:00Z")!
        #expect(BeijingTime.monthDay(d) == "10 月 6 日")
    }

    @Test func 大小按1024进位() {
        #expect(formatBytes(43 * 1_048_576) == "43 MB")
        #expect(formatBytes(Int64(6.2 * 1_073_741_824)) == "6.2 GB")
        #expect(formatBytes(500) == "1 KB")
    }
}
