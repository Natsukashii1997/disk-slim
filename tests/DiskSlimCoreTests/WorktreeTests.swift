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

    @Test func 已落地且干净的进自动清理_没合并或有改动的也勾上但不进自动清理_在用的不清() {
        let (t, run) = setup()
        let found = WorktreeScanner(workRoot: t.url, now: now, runner: run).scan()
        let r = Dictionary(uniqueKeysWithValues: found.map { ($0.title, $0) })

        #expect(found.count == 5)
        #expect(r["proj · ok"]?.suggested == true)
        #expect(r["proj · ok"]?.cleanup == .remove)
        #expect(r["proj · ok"]?.category == "已合并 worktree 的构建产物")

        // 2026-11-18 起（issue #4）：没合并、有没提交的改动的，只要没在用也默认勾选（只删 target/），但标成需确认、不进自动清理
        #expect(r["proj · open"]?.detail.hasPrefix("PR 还没合并；最后编译") == true)
        #expect(r["proj · dirty"]?.detail.hasPrefix("有没提交的改动（只删编译文件，代码不动）") == true)
        for name in ["open", "dirty"] {
            #expect(r["proj · \(name)"]?.category == "还在做的 worktree 构建产物")
            #expect(r["proj · \(name)"]?.suggested == true && r["proj · \(name)"]?.risk == .confirm)
            #expect(r["proj · \(name)"]?.cleanup == .remove)
        }
        #expect(Alerts.autoCleanPicks(found).map(\.title) == ["proj · ok"])
        #expect(r["proj · hot"]?.detail == "2 小时内编译过")
        #expect(r["proj · busy"]?.detail == "有程序在里面运行")
        for name in ["hot", "busy"] {
            #expect(r["proj · \(name)"]?.suggested == false)
            #expect(r["proj · \(name)"]?.cleanup == Cleanup.none)
        }
        #expect(!found.contains { $0.paths.contains(t.url.appendingPathComponent("proj/target").path) })
    }

    @Test func 查不到PR状态时_没在用的照样勾上_但都不进自动清理() {
        let (t, run) = setup()
        run.replies.removeFirst() // 去掉 gh 的回复，模拟 gh 出错
        let found = WorktreeScanner(workRoot: t.url, now: now, runner: run).scan()
        #expect(Alerts.autoCleanPicks(found).isEmpty)
        let ok = found.first { $0.title == "proj · ok" }
        #expect(ok?.detail.hasPrefix("查不到 PR 状态") == true)
        #expect(ok?.suggested == true && ok?.risk == .confirm)
    }

    @Test func 不是Rust构建目录_没被git忽略的不碰_分支复用的当没合并() {
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
        #expect(r["p · reused"]?.detail.hasPrefix("PR 还没合并") == true)
        #expect(r["p · reused"]?.risk == .confirm)
        #expect(r["p · norust"]?.suggested == false && r["p · norust"]?.cleanup == Cleanup.none)
        #expect(r["p · tracked"]?.suggested == false && r["p · tracked"]?.cleanup == Cleanup.none)
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
        _ = single(t, built: now.addingTimeInterval(-25 * 3600)) // 只靠「已在主分支里」认的，要静置 24 小时
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

    @Test func 没合并也没在用_默认勾选但不进自动清理() {
        let t = TempDir()
        _ = single(t, built: daysAgo(4))
        let run = FakeRunner()
        run.on(0, "") { a, _ in a.first == "gh" } // 有 gh，但没有这个分支的已合并 PR
        healthyRunner(run)
        let f = scan(t, run)
        #expect(f?.category == "还在做的 worktree 构建产物")
        #expect(f?.risk == .confirm && f?.suggested == true && f?.cleanup == .remove)
        #expect(f?.bucket(now: now) == .picked)
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
        let leftover = c.staging.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        t.setModified(leftover, now) // 测试的 now 是固定的过去时间：相对真实现在早于一小时
        let mine = c.staging.appendingPathComponent("不是我放的")
        try Data().write(to: mine)
        let target = wt.appendingPathComponent("target")
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "p · w", detail: "",
                        paths: [target.path], bytes: 1, risk: .safe, suggested: true, cleanup: .remove)
        #expect(c.clean([f]).items.first?.outcome == .done)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: c.staging.path)) == ["不是我放的"]) // 只补删 UUID 名字的
    }

    @Test func 只靠已在主分支里认出的_24小时内编译过不清() {
        let t = TempDir()
        _ = single(t, built: now.addingTimeInterval(-3 * 3600))
        let run = FakeRunner()
        run.on(1, "") { a, _ in a.first == "gh" }
        run.on(0, "origin/HEAD\n") { a, _ in a.contains("--verify") }
        run.on(0, "") { a, _ in a.contains("--is-ancestor") }
        healthyRunner(run, branch: "", head: "abc")
        let f = scan(t, run)
        #expect(f?.cleanup == Cleanup.none)
        #expect(f?.detail.contains("24 小时内编译过") == true)
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

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct WorktreeBuildTimeAdversarialTests {
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
}

/// 第 7 批（worktree 构建产物直接删除 + 自动清理）的独立审查对抗用例。每个用例只测一件事，注释写期望。
@Suite struct WorktreeInUseAdversarialTests {
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

/// worktree 构建产物执行前复核：扫描之后 worktree 可能已经不是当初那个 Rust 项目（issue #18）。
@Suite struct WorktreeRecheckTests {
    let t = TempDir()

    func fixture(cargo: Bool = true) -> (Scan, Finding, FakeRunner) {
        let home = t.dir("home"), work = t.dir("home/work")
        let old = daysAgo(1)
        if cargo { t.file("home/work/proj/.claude/worktrees/wt/Cargo.toml") }
        t.file("home/work/proj/.claude/worktrees/wt/target/debug/app", bytes: 100, modified: old)
        for sub in ["target/debug", "target"] {
            t.setModified(work.appendingPathComponent("proj/.claude/worktrees/wt/\(sub)"), old)
        }
        let run = FakeRunner()
        let target = work.appendingPathComponent("proj/.claude/worktrees/wt/target").path
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "proj · wt", detail: "",
                        paths: [target], bytes: 100, risk: .safe, suggested: true, cleanup: .remove)
        return (Scan(home: home, workRoot: work, meta: FakeMetadata(), runner: run), f, run)
    }

    @Test func 仍是Rust构建目录_照常清() {
        let (scan, f, run) = fixture()
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == nil)
    }

    @Test func 扫描后Cargo_toml没了_这次不删() {
        let (scan, f, run) = fixture(cargo: false)
        run.on(0, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == "扫描后情况变了（不是 Rust 项目），这次不删")
    }

    @Test func 扫描后target不再被git忽略_这次不删() {
        let (scan, f, run) = fixture()
        run.on(1, "") { a, _ in a.contains("check-ignore") }
        #expect(scan.recheck(f, now: now) == "扫描后情况变了（target 没被 git 忽略），这次不删")
    }
}
