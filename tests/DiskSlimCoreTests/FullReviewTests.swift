import Foundation
import Testing
@testable import DiskSlimCore

// 第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题还在。

/// 下载区的一项，移到废纸篓
private func downloadsItem(_ url: URL, category: String = "安装包", suggested: Bool = true) -> Finding {
    Finding(area: .downloads, category: category, title: url.lastPathComponent, detail: "",
            paths: [url.path], bytes: 1, risk: .safe, suggested: suggested, cleanup: .trash)
}

@Suite struct FullReviewUndoTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }
    var trash: URL { t.url.appendingPathComponent("Trash") }

    func cleaner() -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: FakeRunner(),
                trasher: FakeTrasher(dir: trash), log: .standard(home: home))
    }

    /// 期望：用户已经在访达里对废纸篓里的文件点了「放回原处」，撤销应认出它已经回来了，把这一批算撤销完；
    /// 再撤销一次就轮到更早的那一批。
    /// 实际：原位置有同名文件就一直当「放不回」，这一批永远没撤销完，更早的批次再也撤不了，提示还让用户把文件挪开。
    @Test func 访达里已放回原处_撤销不该卡在这一批_再撤销能放回更早一批() {
        let a = t.file("home/Downloads/a.dmg")
        let b = t.file("home/Downloads/b.dmg")
        let c = cleaner()
        _ = c.clean([downloadsItem(a)])
        _ = c.clean([downloadsItem(b)])
        // 用户在访达里把 b.dmg 放回原处
        try! FileManager.default.moveItem(at: trash.appendingPathComponent("b.dmg"), to: b)

        _ = c.undoLast()
        _ = c.undoLast()
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    /// 期望：一次什么都没做成的清理（例如自动清理时各项都在用被跳过）不该挡在前面，
    /// 撤销一次就能放回上一次真正移到废纸篓的文件。
    /// 实际：撤销先撞上这一批，回答「这次操作没有可以放回的文件」，用户以为文件回不来了。
    @Test func 什么都没清掉的一批不该挡住撤销() {
        let a = t.file("home/Downloads/a.dmg")
        let c = cleaner()
        _ = c.clean([downloadsItem(a)])
        // 第二批：要删的目录已经不在了，整批都是「跳过」
        let gone = Finding(area: .hidden, category: "测试用浏览器", title: "Playwright 浏览器", detail: "",
                           paths: [home.appendingPathComponent("Library/Caches/ms-playwright").path], bytes: 1,
                           risk: .safe, suggested: true, cleanup: .remove)
        let skipped = c.clean([gone])
        #expect(skipped.items.allSatisfy { $0.outcome != .done })

        _ = c.undoLast()
        #expect(FileManager.default.fileExists(atPath: a.path))
    }

    /// 期望：history.json 在但读不了（权限、读错误）时，清理不能用新的一批把整份旧记录覆盖掉（同 UsageLog 的修法，L-07）。
    /// 实际：读不了被当成「没有记录」，保存时整份覆盖，之前那一批的撤销信息丢了。
    @Test func 操作记录读不了时_清理不该覆盖掉旧记录() {
        let a = t.file("home/Downloads/a.dmg")
        let b = t.file("home/Downloads/b.dmg")
        let c = cleaner()
        let first = c.clean([downloadsItem(a)])
        let log = OperationLog.standard(home: home)
        chmod(log.url.path, 0o000)
        _ = c.clean([downloadsItem(b)])
        chmod(log.url.path, 0o644)

        #expect(log.load().contains { $0.id == first.id })
    }
}

@Suite struct FullReviewDecisionTests {
    let t = TempDir()

    /// 期望：「保留」按项记（PRD 3.3）。用户在「久未打开」的卡片上保留了 x.zip，后来解压出同名文件夹，
    /// 它变成「已解压的压缩包」，也不该重新被默认勾选（否则「清理建议项」会把它移走）。
    /// 实际：决定按「分组 + 路径」记，分组一变就对不上，x.zip 又被默认勾选。
    @Test func 保留过的文件换了分组_仍不该被默认勾选() {
        let path = t.url.appendingPathComponent("Downloads/x.zip")
        let stale = downloadsItem(path, category: "久未打开", suggested: false)
        var d = Decisions()
        d.keep(WeeklyCard(id: "downloads|久未打开", tag: "久未打开", title: "t", why: "w", findings: [stale]), now: now)

        let extracted = downloadsItem(path, category: "已解压的压缩包", suggested: true)
        #expect(applyDecisions([extracted], d).first?.suggested == false)
    }

    /// 期望：decisions.json 在但读不了时，之后保存新的决定不能把原来所有「保留」覆盖掉。
    /// 实际：读不了当成「没有决定」，下一次保存整份覆盖，保留过的下载文件重新被默认勾选。
    @Test func 决定记录读不了时_保存新决定不该覆盖掉旧的保留() throws {
        let log = DecisionLog(url: t.url.appendingPathComponent("decisions.json"))
        let kept = downloadsItem(t.url.appendingPathComponent("Downloads/keep.dmg"))
        var old = Decisions()
        old.keep(WeeklyCard(id: "k", tag: "安装包", title: "t", why: "w", findings: [kept]), now: now)
        try log.save(old)

        chmod(log.url.path, 0o000)
        var d = log.load() // 应用启动时读
        let other = downloadsItem(t.url.appendingPathComponent("Downloads/other.dmg"))
        d.snooze(WeeklyCard(id: "o", tag: "安装包", title: "t", why: "w", findings: [other]), now: now)
        try? log.save(d) // 之后用户在卡片上点了「下周再问」
        chmod(log.url.path, 0o644)

        #expect(log.load().isKept(kept))
    }
}

/// 改进程环境变量，必须串行
@Suite(.serialized) struct FullReviewProcessTests {
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
