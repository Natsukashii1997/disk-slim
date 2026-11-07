import Foundation
import Testing
@testable import DiskSlimCore

/// 假废纸篓：移到临时目录里的 Trash 子目录，不碰真实的废纸篓。
struct FakeTrasher: Trasher {
    let dir: URL
    func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    }
}

@Suite struct CleanerTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }
    var work: URL { t.url.appendingPathComponent("home/work") }
    var trash: URL { t.url.appendingPathComponent("Trash") }

    func cleaner(_ run: FakeRunner = FakeRunner()) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: work), runner: run, trasher: FakeTrasher(dir: trash),
                log: .standard(home: home))
    }

    func f(_ path: String, _ cleanup: Cleanup, risk: Risk = .safe) -> Finding {
        Finding(area: .downloads, category: "测试", title: URL(fileURLWithPath: path).lastPathComponent, detail: "",
                paths: [home.appendingPathComponent(path).path], bytes: 1, risk: risk, suggested: true, cleanup: cleanup)
    }

    @Test func 移到废纸篓后能撤销放回原处() {
        let file = t.file("home/Downloads/old.dmg", bytes: 5_000)
        let c = cleaner()
        let batch = c.clean([f("Downloads/old.dmg", .trash)])

        #expect(batch.items.first?.outcome == .done)
        #expect(batch.trashedBytes > 0)
        #expect(batch.freedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("old.dmg").path))

        #expect(c.undoLast() == ["已放回：old.dmg"])
        #expect(FileManager.default.fileExists(atPath: file.path))
        // 同一次不会被撤销两次
        #expect(c.undoLast() == ["没有可以撤销的操作（清理命令和直接删除的放不回去）"])
    }

    @Test func 原位置又有同名文件时不覆盖() {
        t.file("home/Downloads/a.zip")
        let c = cleaner()
        _ = c.clean([f("Downloads/a.zip", .trash)])
        t.file("home/Downloads/a.zip")
        #expect(c.undoLast() == ["没有放回：a.zip（原位置已有同名文件，挪开后可以再撤销）"])
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("a.zip").path))
    }

    @Test func 删除worktree构建产物_正在使用的跳过() {
        let target = t.dir("home/work/proj/.claude/worktrees/a/target")
        t.file("home/work/proj/.claude/worktrees/a/target/debug/app", bytes: 8_000)
        let busyTarget = t.dir("home/work/proj/.claude/worktrees/b/target")
        let run = FakeRunner()
        run.on(0, "cargo build --target-dir \(busyTarget.path)\n") { a, _ in a.first == "ps" }

        let batch = cleaner(run).clean([f("work/proj/.claude/worktrees/a/target", .remove),
                                        f("work/proj/.claude/worktrees/b/target", .remove)])
        #expect(batch.items[0].outcome == .done)
        #expect(batch.items[0].freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(batch.items[1].outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: busyTarget.path))
        // 直接删除的不能撤销，撤销时要说清楚
        #expect(cleaner(run).undoLast() == ["没有可以撤销的操作（清理命令和直接删除的放不回去）"])
    }

    @Test func 安全门拒绝的一个字节都不动() {
        let doc = t.file("home/Documents/report.pdf")
        let main = t.dir("home/work/proj/target")
        let batch = cleaner().clean([f("Documents/report.pdf", .trash), f("work/proj/target", .remove),
                                     f("Downloads/x", .trash, risk: .readOnly)])
        #expect(batch.items.allSatisfy { $0.outcome == .failed && $0.message.hasPrefix("拒绝执行") })
        #expect(FileManager.default.fileExists(atPath: doc.path))
        #expect(FileManager.default.fileExists(atPath: main.path))
    }

    @Test func 运行清理命令_没装的跳过() {
        t.file("home/.npm/_cacache/a", bytes: 4_000)
        let run = FakeRunner()
        var called: [[String]] = []
        run.on(0, "") { a, _ in if a.first == "npm" { called.append(a); return true }; return false }
        run.on(127, "") { a, _ in a.first == "pip3" }
        let batch = cleaner(run).clean([
            f(".npm/_cacache", .command(["npm", "cache", "clean", "--force"])),
            f("Library/Caches/pip", .command(["pip3", "cache", "purge"])),
        ])
        #expect(called == [["npm", "cache", "clean", "--force"]])
        #expect(batch.items[0].outcome == .done)
        #expect(batch.items[1].outcome == .skipped)
        #expect(batch.items[1].message == "没装 pip3，跳过")
    }

    @Test func 每次操作都写进记录() {
        t.file("home/Downloads/a.dmg")
        let c = cleaner()
        _ = c.clean([f("Downloads/a.dmg", .trash)])
        _ = c.clean([f("Downloads/gone.dmg", .trash)])
        let log = OperationLog.standard(home: home).load()
        #expect(log.count == 2)
        #expect(log[0].items.first?.trashed.isEmpty == false)
        #expect(log[1].items.first?.outcome == .skipped)
    }

    @Test func 执行前复核不通过的跳过_不动文件() {
        let file = t.file("home/Downloads/kept.dmg")
        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: work), runner: FakeRunner(), trasher: FakeTrasher(dir: trash),
                        log: .standard(home: home), recheck: { _ in "扫描后标了「保留」，这次不清" })
        let batch = c.clean([f("Downloads/kept.dmg", .trash)])
        #expect(batch.items[0].outcome == .skipped)
        #expect(batch.items[0].message == "扫描后标了「保留」，这次不清")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func 沙盒模式不运行清理命令() {
        t.file("home/.npm/_cacache/a", bytes: 4_000)
        let run = FakeRunner()
        var called = false
        run.on(0, "") { a, _ in if a.first == "npm" { called = true; return true }; return false }
        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: work), runner: run, trasher: FakeTrasher(dir: trash),
                        log: .standard(home: home), allowCommands: false)
        let batch = c.clean([f(".npm/_cacache", .command(["npm", "cache", "clean", "--force"]))])
        #expect(!called)
        #expect(batch.items[0].outcome == .skipped)
    }

    @Test func 相关程序在跑时不删Homebrew下载缓存() {
        let dl = t.dir("home/Library/Caches/Homebrew/downloads")
        let run = FakeRunner()
        run.on(0, "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/ruby /opt/homebrew/Library/Homebrew/brew.rb install wget\n") { a, _ in a.first == "ps" }
        let batch = cleaner(run).clean([f("Library/Caches/Homebrew/downloads", .remove)])
        #expect(batch.items[0].outcome == .skipped)
        #expect(FileManager.default.fileExists(atPath: dl.path))
        // 没在跑时可以删
        let batch2 = cleaner().clean([f("Library/Caches/Homebrew/downloads", .remove)])
        #expect(batch2.items[0].outcome == .done)
        #expect(!FileManager.default.fileExists(atPath: dl.path))
    }

    @Test func 操作记录损坏时留底并提示_不提供撤销() throws {
        let log = OperationLog.standard(home: home)
        try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: log.url)
        t.file("home/Downloads/a.dmg")
        let batch = cleaner().clean([f("Downloads/a.dmg", .trash)])
        #expect(batch.note?.contains("另存为") == true)
        let backups = try FileManager.default.contentsOfDirectory(atPath: log.url.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("history-damaged-") }
        #expect(backups.count == 1)
        #expect(log.load().count == 1) // 新记录照常写入
    }
}
