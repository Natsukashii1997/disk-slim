import Foundation
import Testing
@testable import DiskSlimCore

/// 独立测试员的对抗用例。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct ReviewAdversarialTests {
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

    // MARK: - SafetyGuard：符号链接 + ..

    /// Downloads/link -> outside/inner；路径 Downloads/link/../victim 字面上规整成 Downloads/victim，
    /// 但文件系统先跟随 link 再回到上一级，实际指向 outside/victim。
    @Test func 下载区_符号链接加点点_不能把下载区以外的文件移走() throws {
        let victim = t.file("outside/victim.txt")
        t.dir("outside/inner")
        t.dir("home/Downloads")
        try fm.createSymbolicLink(at: home.appendingPathComponent("Downloads/link"),
                                  withDestinationURL: t.url.appendingPathComponent("outside/inner"))
        let path = home.appendingPathComponent("Downloads").path + "/link/../victim.txt"
        let f = finding([path], .trash)
        _ = cleaner().clean([f], now: now)
        #expect(fm.fileExists(atPath: victim.path), "下载区以外的 outside/victim.txt 被移走了")
    }

    /// worktree 目录里放一个符号链接再用 .. 绕出去：直接删除（不可撤销）落到工作区以外。
    @Test func worktree_符号链接加点点_不能删工作区以外的目录() throws {
        let outsideTarget = t.file("outside/wt/target/keep.bin")
        t.dir("outside/x")
        t.dir("home/work/p/.claude/worktrees")
        try fm.createSymbolicLink(at: work.appendingPathComponent("p/.claude/worktrees/link"),
                                  withDestinationURL: t.url.appendingPathComponent("outside/x"))
        let path = work.path + "/p/.claude/worktrees/link/../wt/target"
        let f = finding([path], .remove)
        #expect(SafetyGuard(home: home, workRoot: work).refusal(for: f) != nil, "安全门放行了带 .. 的路径")
        _ = cleaner().clean([f], now: now)
        #expect(fm.fileExists(atPath: outsideTarget.path), "工作区以外的 outside/wt/target 被直接删除了")
    }

    /// worktree 目录本身是指向别处的符号链接：扫描会建议删，执行会删掉别处的 target/。
    @Test func worktree目录是符号链接时_不该建议删除别处的target() throws {
        let outsideTarget = t.file("outside/proj/target/keep.bin", modified: daysAgo(3))
        t.file("outside/proj/Cargo.toml") // 其余条件都满足，只有「是符号链接」这一条
        t.setModified(t.url.appendingPathComponent("outside/proj/target"), daysAgo(3))
        t.dir("home/work/p/.claude/worktrees")
        try fm.createSymbolicLink(at: work.appendingPathComponent("p/.claude/worktrees/wt"),
                                  withDestinationURL: t.url.appendingPathComponent("outside/proj"))
        let run = healthyRunner()
        let found = WorktreeScanner(workRoot: work, now: now, runner: run, sizeOf: { _ in 1 }).scan()
        let picked = found.filter(\.suggested)
        _ = cleaner(run).clean(picked, now: now)
        #expect(fm.fileExists(atPath: outsideTarget.path), "符号链接指向的 outside/proj/target 被删了")
    }

    /// `.codex/recovery` 是指向 `.codex/sessions`（只展示）的符号链接时，对话记录会被当成备份逐个移到废纸篓。
    @Test func Codex备份目录是符号链接时_只展示的对话记录不能被清() throws {
        let session = t.file("home/.codex/sessions/2026/rollout.jsonl")
        try fm.createSymbolicLink(at: home.appendingPathComponent(".codex/recovery"),
                                  withDestinationURL: home.appendingPathComponent(".codex/sessions"))
        let found = KnownPlacesScanner(home: home, minBytes: 0, sizeOf: { _ in 100 * 1_048_576 }).scan()
            .filter { $0.cleanup == .trash }
        _ = cleaner().clean(found, now: now)
        #expect(fm.fileExists(atPath: session.path), "只展示的 .codex/sessions 内容被移到废纸篓了")
    }

    @Test func 安全门_大小写_结尾斜杠_NFD() {
        let g = SafetyGuard(home: home, workRoot: work)
        let dl = home.appendingPathComponent("Downloads").path
        #expect(g.refusal(for: finding([dl + "/a.dmg/"], .trash)) == nil)
        #expect(g.refusal(for: finding([home.path + "/downloads/a.dmg"], .trash)) != nil) // 大小写不同 → 拒绝（偏保守）
        #expect(g.refusal(for: finding([dl + "/caf\u{0065}\u{0301}.dmg"], .trash)) == nil)
        #expect(g.refusal(for: finding([dl + "/a.dmg", home.path + "/Documents/b"], .trash)) != nil) // 混合路径整项拒绝
        #expect(g.refusal(for: finding([home.path + "/.codex/sessions/x"], .trash, risk: .confirm)) != nil)
        #expect(g.refusal(for: finding([dl + "/" + String(repeating: "长", count: 200)], .trash)) == nil)
    }

    // MARK: - 操作记录

    @Test func 操作记录损坏时_清理不该悄悄覆盖掉旧记录() throws {
        let log = OperationLog.standard(home: home)
        try fm.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: log.url)
        t.file("home/Downloads/a.dmg")
        _ = cleaner().clean([finding([home.appendingPathComponent("Downloads/a.dmg").path], .trash)], now: now)
        // 坏文件改名留底（history-damaged-<时间>.json.bak），内容原样保留
        let dir = log.url.deletingLastPathComponent()
        let kept = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("history-damaged-") }
            .map { try Data(contentsOf: dir.appendingPathComponent($0)) }
        #expect(kept.contains { String(decoding: $0, as: UTF8.self).contains("not json") },
                "损坏的 history.json 被直接覆盖，旧的撤销信息全丢")
    }

    @Test func 撤销时原位置有同名文件_放不回的项之后应能再撤销() throws {
        t.file("home/Downloads/a.dmg")
        let c = cleaner()
        _ = c.clean([finding([home.appendingPathComponent("Downloads/a.dmg").path], .trash)], now: now)
        let blocker = t.file("home/Downloads/a.dmg") // 原位置出现同名文件
        let first = c.undoLast()
        #expect(first.contains { $0.contains("原位置已有同名文件") })
        try fm.removeItem(at: blocker) // 用户把同名文件挪走后再撤销
        let second = c.undoLast()
        #expect(second.contains { $0.contains("已放回") }, "第一次撤销没放回的项被标记为已撤销，再也放不回：\(second)")
    }

    @Test func 连续两次清理_两次撤销按倒序放回() {
        t.file("home/Downloads/a.dmg")
        t.file("home/Downloads/b.dmg")
        let c = cleaner()
        _ = c.clean([finding([home.appendingPathComponent("Downloads/a.dmg").path], .trash)], now: now)
        _ = c.clean([finding([home.appendingPathComponent("Downloads/b.dmg").path], .trash)], now: now)
        #expect(c.undoLast() == ["已放回：b.dmg"])
        #expect(c.undoLast() == ["已放回：a.dmg"])
        #expect(c.undoLast() == ["没有可以撤销的操作（清理命令和直接删除的放不回去）"])
    }

    // MARK: - WorktreeScanner 24 小时

    /// cargo 增量编译改的是 target/debug/deps/ 里的文件，target/ 和 target/debug 的修改时间不变。
    @Test func worktree_深层文件刚编译过_应算24小时内编译过() {
        t.file("home/work/p/.claude/worktrees/wt/Cargo.toml") // 其余条件都满足，只有「刚编译过」这一条
        t.file("home/work/p/.claude/worktrees/wt/target/debug/deps/libx.rlib", modified: now.addingTimeInterval(-600))
        t.setModified(work.appendingPathComponent("p/.claude/worktrees/wt/target/debug/deps"), daysAgo(3))
        t.setModified(work.appendingPathComponent("p/.claude/worktrees/wt/target/debug"), daysAgo(3))
        t.setModified(work.appendingPathComponent("p/.claude/worktrees/wt/target"), daysAgo(3))
        let found = WorktreeScanner(workRoot: work, now: now, runner: healthyRunner(), sizeOf: { _ in 1 }).scan()
        #expect(found.first?.suggested == false, "10 分钟前刚编译过的 target 被建议删除")
        #expect(found.first?.detail == "2 小时内编译过")
    }

    // MARK: - 下载区边界

    @Test func 下载区边界() throws {
        let dl = home.appendingPathComponent("Downloads")
        t.file("home/Downloads/seven.dmg")
        t.file("home/Downloads/eight.dmg")
        t.file("home/Downloads/thirty.txt")
        t.file("home/Downloads/x.tar.gz")
        t.dir("home/Downloads/x")
        t.file("home/Downloads/kept.dmg")
        t.dir("home/Downloads/folder.zip")
        t.dir("home/Downloads/folder")
        var meta = FakeMetadata()
        meta.added = ["seven.dmg": daysAgo(7), "eight.dmg": daysAgo(7.01), "thirty.txt": daysAgo(30),
                      "x.tar.gz": daysAgo(1), "x": daysAgo(1), "kept.dmg": daysAgo(90),
                      "folder.zip": daysAgo(1), "folder": daysAgo(1)]
        meta.tagged = ["kept.dmg": ["保留"]]
        let found = DownloadsScanner(root: dl, now: now, meta: meta).scan()
        func cat(_ n: String) -> String? { found.first { $0.title == n }?.category }
        #expect(cat("seven.dmg") == nil)          // 恰好 7 天：不算「超过」
        #expect(cat("eight.dmg") == "安装包")
        #expect(cat("thirty.txt") == nil)         // 恰好 30 天：不算
        #expect(cat("x.tar.gz") == "已解压的压缩包")
        #expect(cat("kept.dmg") == nil)
        #expect(cat("folder.zip") == nil, "名字以 .zip 结尾的文件夹被当成已解压的压缩包建议清理")
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
