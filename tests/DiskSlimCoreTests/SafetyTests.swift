import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct SafetyTests {
    let home = URL(fileURLWithPath: "/Users/someone")
    let work = URL(fileURLWithPath: "/Users/someone/Documents/work")
    var guardian: SafetyGuard { SafetyGuard(home: home, workRoot: work) }

    func f(_ paths: [String], _ cleanup: Cleanup, risk: Risk = .safe) -> Finding {
        Finding(area: .hidden, category: "测试", title: "x", detail: "", paths: paths, bytes: 1,
                risk: risk, suggested: true, cleanup: cleanup)
    }

    @Test func 下载第一层可以进废纸篓_更深或别处不行() {
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/a.dmg"], .trash)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/sub/a.dmg"], .trash)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads"], .trash)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Documents/a.pdf"], .trash)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/.hidden"], .trash)) != nil)
        // 用 .. 绕出下载文件夹也不行
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/../Documents/a.pdf"], .trash)) != nil)
    }

    @Test func Codex备份可以逐个进废纸篓_整个目录不行() {
        #expect(guardian.refusal(for: f(["/Users/someone/.codex/recovery/guard-0901"], .trash)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.codex/recovery"], .trash)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.codex/sessions/2026"], .trash)) != nil)
    }

    @Test func 只能直接删除worktree的target和已知的可再生目录() {
        #expect(guardian.refusal(for: f(["/Users/someone/Documents/work/postpane/.claude/worktrees/48-a/target"], .remove)) == nil)
        // 主仓库自己的 target、worktree 本身、别的子目录都不行
        #expect(guardian.refusal(for: f(["/Users/someone/Documents/work/postpane/target"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Documents/work/postpane/.claude/worktrees/48-a"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Documents/work/postpane/.claude/worktrees/48-a/src"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/ms-playwright"], .remove)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_npx"], .remove)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches"], .remove)) != nil)
        // 一项里只要有一条路径不合规，整项拒绝
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/ms-playwright", "/Users/someone/Documents"], .remove)) != nil)
    }

    @Test func 只认写死的清理命令() {
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["npm", "cache", "clean", "--force"]))) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["rm", "-rf", "/Users/someone"]))) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["npm", "cache", "clean"]))) != nil)
    }

    @Test func 只展示和没有清理方式的一律拒绝() {
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/a.dmg"], .trash, risk: .readOnly)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/a.dmg"], .none)) != nil)
        #expect(guardian.refusal(for: f([], .trash)) != nil)
    }
}
