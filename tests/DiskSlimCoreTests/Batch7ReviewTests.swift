import Foundation
import Testing
@testable import DiskSlimCore

/// 第 7 批（worktree 构建产物直接删除 + 自动清理）的独立审查对抗用例。每个用例只测一件事，注释写期望。
@Suite struct Batch7ReviewTests {
    /// 一个已合并、静置一天的 worktree：p/.claude/worktrees/<name>/target
    func worktree(_ t: TempDir, _ name: String = "w") -> URL {
        let built = daysAgo(1)
        t.file("p/.claude/worktrees/\(name)/Cargo.toml")
        t.file("p/.claude/worktrees/\(name)/target/debug/app", bytes: 10, modified: built)
        t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/\(name)/target/debug"), built)
        t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/\(name)/target"), built)
        return t.url.appendingPathComponent("p/.claude/worktrees/\(name)")
    }

    func scan(_ t: TempDir, _ run: FakeRunner) -> [Finding] {
        WorktreeScanner(workRoot: t.url, now: now, runner: run, sizeOf: { _ in 1 }).scan()
    }

    // MARK: 暂存目录

    /// 期望：暂存目录 `deleting` 被换成指向别处的符号链接时，清理开头的「补删残留」不能顺着链接删掉别处的文件。
    /// （沙盒演练 evidence/review-batch7-20261105/clean-symlink-staging.txt 里，金丝雀目录被整个清空）
    @Test func 暂存目录是符号链接时_不能删掉链接指向的目录里的东西() throws {
        let t = TempDir()
        let canary = t.file("elsewhere/notes.txt")
        let c = Cleaner(safety: SafetyGuard(home: t.url, workRoot: t.url), runner: FakeRunner(),
                        trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: t.url))
        try FileManager.default.createDirectory(at: c.staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: c.staging, withDestinationURL: canary.deletingLastPathComponent())
        _ = c.clean([])
        #expect(FileManager.default.fileExists(atPath: canary.path))
    }

    // MARK: 「没在用」的判断

    /// 期望：另一个 worktree 名字以这个为前缀（wt 与 wt-building）时，它的编译进程不算这个 worktree 在用。
    /// 沙盒演练里 wt-building 在编译，wt 被误标「有程序在里面运行」（ps 的命令行按子串比较）。
    @Test func 名字是前缀的另一个worktree在编译_不算这个在用() {
        let t = TempDir()
        let wt = worktree(t, "wt")
        _ = worktree(t, "wt-building")
        let run = FakeRunner()
        let other = wt.deletingLastPathComponent().appendingPathComponent("wt-building").path
        run.on(0, "/usr/bin/login\ncargo build --manifest-path \(other)/Cargo.toml\n") { a, _ in a.first == "ps" }
        healthyRunner(run)
        let f = scan(t, run).first { $0.title == "p · wt" }
        #expect(f?.detail.contains("有程序在里面运行") == false)
        #expect(f?.suggested == true)
    }

    /// 期望：锁的原因里有中文时，git 会输出带引号的八进制转义（"\346\265\213..."），界面上应显示解码后的中文。
    /// 沙盒演练实际显示为：worktree 被锁住了（"\346\265\213\350\257\225 \351\224\201"）
    @Test func 锁的原因带中文时_显示解码后的文字() {
        let t = TempDir()
        let wt = worktree(t)
        let run = FakeRunner()
        run.on(0, "worktree \(wt.path)\nHEAD abc\nlocked \"\\346\\265\\213\\350\\257\\225\"\n\n") { a, _ in a.contains("worktree") && a.contains("list") }
        healthyRunner(run)
        #expect(scan(t, run).first?.detail.contains("worktree 被锁住了（测试）") == true)
    }
}
