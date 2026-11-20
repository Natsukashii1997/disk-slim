import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct SafetyGuardTests {
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
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/Homebrew/downloads"], .remove)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/Homebrew"], .remove)) != nil)
        // npx 是「需确认」，只能进废纸篓，不能直接删
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_npx"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_npx"], .trash, risk: .confirm)) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm"], .remove)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches"], .remove)) != nil)
        // 一项里只要有一条路径不合规，整项拒绝
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/ms-playwright", "/Users/someone/Documents"], .remove)) != nil)
    }

    @Test func 只认写死的清理命令() {
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["npm", "cache", "clean", "--force"]))) == nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["rm", "-rf", "/Users/someone"]))) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/.npm/_cacache"], .command(["npm", "cache", "clean"]))) != nil)
        // 命令要配它自己的位置：拿 npm 的命令去「清」下载文件夹不行
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads"], .command(["npm", "cache", "clean", "--force"]))) != nil)
        // brew cleanup 已从表里拿掉（会卸载软件，L-06）
        #expect(guardian.refusal(for: f(["/Users/someone/Library/Caches/Homebrew"], .command(["brew", "cleanup", "-s"]))) != nil)
    }

    @Test func 只展示和没有清理方式的一律拒绝() {
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/a.dmg"], .trash, risk: .readOnly)) != nil)
        #expect(guardian.refusal(for: f(["/Users/someone/Downloads/a.dmg"], .none)) != nil)
        #expect(guardian.refusal(for: f([], .trash)) != nil)
    }
}

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct SafetyGuardAdversarialTests {
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
}
