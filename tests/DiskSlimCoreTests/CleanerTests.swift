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

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct OperationLogAdversarialTests {
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
}

/// 第 7 批（worktree 构建产物直接删除 + 自动清理）的独立审查对抗用例。每个用例只测一件事，注释写期望。
@Suite struct CleanerStagingTests {
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
}

// 以下来自第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题当时还在。
@Suite struct UndoAdversarialTests {
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

// 以下来自第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题当时还在。
/// B8–B12 修复后补的用例
@Suite struct OperationLogFollowupTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }

    func cleaner() -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: FakeRunner(),
                trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
    }

    /// B9：扫描是只读的，坏掉的操作记录不该被它挪走（留给清理时挪并提示）
    @Test func 扫描不挪坏掉的操作记录() throws {
        let log = OperationLog.standard(home: home)
        try FileManager.default.createDirectory(at: log.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{ broken".utf8).write(to: log.url)
        _ = Scan(home: home, workRoot: home.appendingPathComponent("work"), meta: FakeMetadata(), runner: FakeRunner()).run()
        #expect(FileManager.default.fileExists(atPath: log.url.path))
        #expect(cleaner().canUndo() == false)
        #expect(FileManager.default.fileExists(atPath: log.url.path))
    }

    /// B12：两个进程（这里用两个线程模拟）同时清理，两批都要记下来，谁也不覆盖谁
    @Test func 同时清理两批都记进操作记录() {
        let files = (0..<8).map { t.file("home/Downloads/f\($0).dmg") }
        let ids = Locked<[String]>([])
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let item = Finding(area: .downloads, category: "安装包", title: files[i].lastPathComponent, detail: "",
                               paths: [files[i].path], bytes: 1, risk: .safe, suggested: true, cleanup: .trash)
            let b = cleaner().clean([item])
            ids.mutate { $0.append(b.id) }
        }
        let logged = Set(OperationLog.standard(home: home).load().map(\.id))
        #expect(logged == Set(ids.value))
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
