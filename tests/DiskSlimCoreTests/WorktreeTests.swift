import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct WorktreeTests {
    /// 一个项目、五个 worktree：ok 全部满足；open PR 没合并；dirty 有改动；hot 刚编译过；busy 正在编译。
    func setup() -> (TempDir, FakeRunner) {
        let t = TempDir()
        let old = daysAgo(3)
        for name in ["ok", "open", "dirty", "hot", "busy"] {
            t.file("proj/.claude/worktrees/\(name)/Cargo.toml")
            t.file("proj/.claude/worktrees/\(name)/target/debug/app", bytes: 100, modified: old)
            t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/\(name)/target/debug"), old)
            t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/\(name)/target"), old)
        }
        t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/hot/target/debug"), now.addingTimeInterval(-3600))
        // 主仓库自己的 target，不该出现在结果里
        t.file("proj/target/debug/app", bytes: 100)

        let run = FakeRunner()
        run.on(0, "claude/ok h-ok\nclaude/dirty h-dirty\nclaude/hot h-hot\nclaude/busy h-busy\n") { a, _ in a.starts(with: ["gh", "pr", "list"]) }
        for name in ["ok", "open", "dirty", "hot", "busy"] {
            run.on(0, "claude/\(name)\n") { a, _ in a.contains("branch") && a[2].hasSuffix("/\(name)") }
            run.on(0, "h-\(name)\n") { a, _ in a.contains("rev-parse") && a[2].hasSuffix("/\(name)") }
        }
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        run.on(0, " M src/main.rs\n?? notes.txt\n") { a, _ in a.contains("status") && a[2].hasSuffix("/dirty") }
        run.on(0, "?? scratch.txt\n") { a, _ in a.contains("status") }
        let busyPath = t.url.appendingPathComponent("proj/.claude/worktrees/busy").path
        run.on(0, "/usr/bin/login\ncargo build --manifest-path \(busyPath)/Cargo.toml\n") { a, _ in a.first == "ps" }
        return (t, run)
    }

    @Test func 四个条件全满足才建议删() {
        let (t, run) = setup()
        let found = WorktreeScanner(workRoot: t.url, now: now, runner: run).scan()
        let r = Dictionary(uniqueKeysWithValues: found.map { ($0.title, $0) })

        #expect(found.count == 5)
        #expect(r["proj · ok"]?.suggested == true)
        #expect(r["proj · ok"]?.cleanup == .remove)
        #expect(r["proj · ok"]?.category == "已合并 worktree 的构建产物")

        #expect(r["proj · open"]?.detail == "PR 还没合并")
        #expect(r["proj · dirty"]?.detail == "有未提交的改动")
        #expect(r["proj · hot"]?.detail == "24 小时内编译过")
        #expect(r["proj · busy"]?.detail == "正在编译")
        for name in ["open", "dirty", "hot", "busy"] {
            #expect(r["proj · \(name)"]?.suggested == false)
            #expect(r["proj · \(name)"]?.cleanup == Cleanup.none)
        }
        #expect(!found.contains { $0.paths.contains(t.url.appendingPathComponent("proj/target").path) })
    }

    @Test func 查不到PR状态时一律不建议删() {
        let (t, run) = setup()
        run.replies.removeFirst() // 去掉 gh 的回复，模拟 gh 出错
        let found = WorktreeScanner(workRoot: t.url, now: now, runner: run).scan()
        #expect(found.allSatisfy { !$0.suggested })
        #expect(found.first { $0.title == "proj · ok" }?.detail == "查不到 PR 状态")
    }

    @Test func 不是Rust构建目录_没被git忽略_分支复用都不建议删() {
        let t = TempDir()
        for name in ["norust", "tracked", "reused"] {
            t.file("p/.claude/worktrees/\(name)/target/a", modified: daysAgo(3))
            t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/\(name)/target"), daysAgo(3))
        }
        t.file("p/.claude/worktrees/tracked/Cargo.toml")
        t.file("p/.claude/worktrees/reused/Cargo.toml")
        let run = FakeRunner()
        run.on(1, "") { a, _ in a.contains("check-ignore") && a[2].hasSuffix("/tracked") }
        // reused 的分支名在已合并 PR 里，但 worktree 现在停在另一个提交上
        run.on(0, "other\n") { a, _ in a.contains("rev-parse") && a[2].hasSuffix("/reused") }
        healthyRunner(run)
        let r = Dictionary(uniqueKeysWithValues: WorktreeScanner(workRoot: t.url, now: now, runner: run, sizeOf: { _ in 1 }).scan().map { ($0.title, $0) })
        #expect(r["p · norust"]?.detail == "不是 Rust 项目")
        #expect(r["p · tracked"]?.detail == "target 没被 git 忽略")
        #expect(r["p · reused"]?.detail == "PR 还没合并")
        #expect(r.values.allSatisfy { !$0.suggested })
    }
}
