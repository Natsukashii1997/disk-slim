import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct WorktreeTests {
    /// 一个项目、五个 worktree：ok 全部满足；open PR 没合并；dirty 有改动；hot 刚编译过；busy 正在编译。
    func setup() -> (TempDir, FakeRunner) {
        let t = TempDir()
        let old = daysAgo(3)
        for name in ["ok", "open", "dirty", "hot", "busy"] {
            t.file("proj/.claude/worktrees/\(name)/target/debug/app", bytes: 100, modified: old)
            t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/\(name)/target/debug"), old)
            t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/\(name)/target"), old)
        }
        t.setModified(t.url.appendingPathComponent("proj/.claude/worktrees/hot/target/debug"), now.addingTimeInterval(-3600))
        // 主仓库自己的 target，不该出现在结果里
        t.file("proj/target/debug/app", bytes: 100)

        let run = FakeRunner()
        run.on(0, "claude/ok\nclaude/dirty\nclaude/hot\nclaude/busy\n") { a, _ in a.starts(with: ["gh", "pr", "list"]) }
        for name in ["ok", "open", "dirty", "hot", "busy"] {
            run.on(0, "claude/\(name)\n") { a, _ in a.contains("branch") && a[2].hasSuffix("/\(name)") }
        }
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
}
