import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct WorktreeTests {
    /// 一个项目、五个 worktree：ok 全部满足；open PR 没合并；dirty 有改动；hot 刚编译过；busy 正在编译。
    func setup() -> (TempDir, FakeRunner) {
        let t = TempDir()
        let old = daysAgo(1) // 过了 2 小时静置窗口、又不到「闲置 3 天」
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
            run.on(0, "claude/\(name)\n") { a, _ in a.contains("branch") && a.contains { $0.hasSuffix("/\(name)") } }
            run.on(0, "h-\(name)\n") { a, _ in a.contains("rev-parse") && a.contains { $0.hasSuffix("/\(name)") } }
        }
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        run.on(0, " M src/main.rs\n?? notes.txt\n") { a, _ in a.contains("status") && a.contains { $0.hasSuffix("/dirty") } }
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
        #expect(r["proj · hot"]?.detail == "2 小时内编译过")
        #expect(r["proj · busy"]?.detail == "有程序在里面运行")
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
            t.file("p/.claude/worktrees/\(name)/target/a", modified: daysAgo(1))
            t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/\(name)/target"), daysAgo(1))
        }
        t.file("p/.claude/worktrees/tracked/Cargo.toml")
        t.file("p/.claude/worktrees/reused/Cargo.toml")
        let run = FakeRunner()
        run.on(1, "") { a, _ in a.contains("check-ignore") && a.contains { $0.hasSuffix("/tracked") } }
        // reused 的分支名在已合并 PR 里，但 worktree 现在停在另一个提交上
        run.on(0, "other\n") { a, _ in a.contains("rev-parse") && a.contains { $0.hasSuffix("/reused") } }
        healthyRunner(run)
        let r = Dictionary(uniqueKeysWithValues: WorktreeScanner(workRoot: t.url, now: now, runner: run, sizeOf: { _ in 1 }).scan().map { ($0.title, $0) })
        #expect(r["p · norust"]?.detail == "不是 Rust 项目")
        #expect(r["p · tracked"]?.detail == "target 没被 git 忽略")
        #expect(r["p · reused"]?.detail == "PR 还没合并")
        #expect(r.values.allSatisfy { !$0.suggested })
    }

    // MARK: 第 7 批

    /// 一个 worktree：Rust、target 被忽略、没改动，构建时间可调
    func single(_ t: TempDir, built: Date) -> URL {
        t.file("p/.claude/worktrees/w/Cargo.toml")
        t.file("p/.claude/worktrees/w/target/debug/app", bytes: 10, modified: built)
        t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/w/target/debug"), built)
        t.setModified(t.url.appendingPathComponent("p/.claude/worktrees/w/target"), built)
        return t.url.appendingPathComponent("p/.claude/worktrees/w")
    }

    func scan(_ t: TempDir, _ run: FakeRunner) -> Finding? {
        WorktreeScanner(workRoot: t.url, now: now, runner: run, sizeOf: { _ in 1 }).scan().first
    }

    @Test func squash合并后停在main上的分离HEAD_认作已落地() {
        let t = TempDir()
        _ = single(t, built: now.addingTimeInterval(-3 * 3600))
        let run = FakeRunner()
        run.on(1, "") { a, _ in a.first == "gh" } // gh 不可用，只靠「已在主分支里」
        run.on(0, "") { a, _ in a.contains("--show-current") } // 分离 HEAD 没有分支名
        run.on(0, "origin/HEAD\n") { a, _ in a.contains("--verify") }
        run.on(0, "") { a, _ in a.contains("--is-ancestor") }
        healthyRunner(run, branch: "", head: "cdcb999")
        let f = scan(t, run)
        #expect(f?.suggested == true && f?.cleanup == .remove)
        #expect(f?.detail.hasPrefix("当前提交已在主分支里") == true)
    }

    @Test func 静置不满2小时不清_满了才清() {
        for (hours, expected) in [(1.9, false), (2.1, true)] {
            let t = TempDir()
            _ = single(t, built: now.addingTimeInterval(-hours * 3600))
            #expect(scan(t, healthyRunner())?.suggested == expected, "静置 \(hours) 小时")
        }
    }

    @Test func 没合并但闲置3天_列成要你决定_不默认勾选() {
        let t = TempDir()
        _ = single(t, built: daysAgo(4))
        let run = FakeRunner()
        run.on(0, "") { a, _ in a.first == "gh" } // 有 gh，但没有这个分支的已合并 PR
        healthyRunner(run)
        let f = scan(t, run)
        #expect(f?.category == "闲置的 worktree 构建产物")
        #expect(f?.risk == .confirm && f?.suggested == false && f?.cleanup == .remove)
        #expect(Alerts.autoCleanPicks([f!]).isEmpty) // 不进自动清理
    }

    @Test func worktree被锁住_不清() {
        let t = TempDir()
        let wt = single(t, built: daysAgo(1))
        let run = FakeRunner()
        run.on(0, "worktree \(wt.path)\nHEAD abc\nlocked claude session (pid 1)\n\n") { a, _ in a.contains("worktree") && a.contains("list") }
        healthyRunner(run)
        let f = scan(t, run)
        #expect(f?.cleanup == Cleanup.none)
        #expect(f?.detail.contains("worktree 被锁住了") == true)
    }

    @Test func 有进程的工作目录在里面_不清() {
        let t = TempDir()
        let wt = single(t, built: daysAgo(1))
        let run = FakeRunner()
        run.on(0, "p123\nn/usr/bin\np456\nn\(wt.path)/src-tauri\n") { a, _ in a.first == "/usr/sbin/lsof" }
        healthyRunner(run)
        let f = scan(t, run)
        #expect(f?.cleanup == Cleanup.none)
        #expect(f?.detail.contains("有程序在里面运行") == true)
    }

    @Test func cargo锁被占着_算正在编译_删除时也跳过() throws {
        let t = TempDir()
        let wt = single(t, built: daysAgo(1))
        let lock = t.file("p/.claude/worktrees/w/target/debug/.cargo-lock")
        let fd = open(lock.path, O_RDONLY)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(scan(t, healthyRunner())?.detail.contains("正在编译") == true)

        let target = wt.appendingPathComponent("target")
        let home = t.url
        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: t.url), runner: FakeRunner(),
                        trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "p · w", detail: "",
                        paths: [target.path], bytes: 1, risk: .safe, suggested: true, cleanup: .remove)
        let b = c.clean([f])
        #expect(b.items.first?.outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func 删除先挪进暂存目录_上次没删完的残留下次清理时补删() throws {
        let t = TempDir()
        let wt = single(t, built: daysAgo(1))
        let home = t.url
        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: t.url), runner: FakeRunner(),
                        trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
        let leftover = c.staging.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let target = wt.appendingPathComponent("target")
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "p · w", detail: "",
                        paths: [target.path], bytes: 1, risk: .safe, suggested: true, cleanup: .remove)
        #expect(c.clean([f]).items.first?.outcome == .done)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: c.staging.path)) ?? []).isEmpty)
    }

    @Test func 扫描用的git命令都不改写index() {
        let t = TempDir()
        _ = single(t, built: daysAgo(1))
        let run = healthyRunner()
        var gitCalls: [[String]] = []
        let spy = SpyRunner(inner: run) { gitCalls.append($0) }
        _ = WorktreeScanner(workRoot: t.url, now: now, runner: spy, sizeOf: { _ in 1 }).scan()
        let git = gitCalls.filter { $0.first == "git" }
        #expect(!git.isEmpty && git.allSatisfy { $0.contains("--no-optional-locks") })
    }
}

final class SpyRunner: CommandRunner {
    let inner: CommandRunner
    let record: ([String]) -> Void
    init(inner: CommandRunner, record: @escaping ([String]) -> Void) { self.inner = inner; self.record = record }
    func run(_ args: [String], cwd: URL?) -> (status: Int32, output: String) { record(args); return inner.run(args, cwd: cwd) }
}

