import Foundation
import Testing
@testable import DiskSlimCore

/// 操作记录逐项落盘（第三批）：清到一半断掉，已经移走的也记着、能撤销
@Suite struct CleanerJournalTests {
    let t = TempDir()
    var home: URL { t.url.appendingPathComponent("home") }
    var trash: URL { t.url.appendingPathComponent("Trash") }
    var log: OperationLog { .standard(home: home) }

    /// 每次移到废纸篓前，把磁盘上的操作记录拍一张；第 `failAt` 次（从 1 数）不移、报错，当作那一刻断掉了
    final class SpyTrasher: Trasher, @unchecked Sendable {
        let inner: FakeTrasher
        let log: OperationLog
        let failAt: Int?
        var calls = 0
        var seen: [[Batch]] = []
        init(dir: URL, log: OperationLog, failAt: Int? = nil) {
            inner = FakeTrasher(dir: dir)
            self.log = log
            self.failAt = failAt
        }
        func trash(_ url: URL) throws -> URL {
            calls += 1
            seen.append(log.load(readOnly: true))
            if calls == failAt { throw CocoaError(.fileWriteUnknown) }
            return try inner.trash(url)
        }
    }

    func cleaner(_ trasher: Trasher) -> Cleaner {
        Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: FakeRunner(),
                trasher: trasher, log: log)
    }

    func f(_ name: String) -> Finding {
        Finding(area: .downloads, category: "测试", title: name, detail: "",
                paths: [home.appendingPathComponent("Downloads/\(name)").path], bytes: 1, risk: .safe, suggested: true, cleanup: .trash)
    }

    @Test func 每清完一项就写进操作记录_清完去掉进行中() throws {
        for n in ["a.zip", "b.zip", "c.zip"] { t.file("home/Downloads/\(n)") }
        let spy = SpyTrasher(dir: trash, log: log)
        let batch = cleaner(spy).clean([f("a.zip"), f("b.zip"), f("c.zip")])

        // 移第 1 个之前：已经有一条「进行中」、还没有项；移第 3 个之前：前两项都已落盘
        #expect(spy.seen.map { $0.last?.items.count } == [0, 1, 2])
        #expect(spy.seen.allSatisfy { $0.count == 1 && $0.last?.unfinished == true && $0.last?.id == batch.id })
        let saved = log.load()
        #expect(saved.count == 1 && saved[0].unfinished == nil && saved[0].items.count == 3)
        #expect(batch.unfinished == nil && batch.note == nil)
    }

    @Test func 清到一半断掉_已经移走的照样能撤销() throws {
        for n in ["a.zip", "b.zip", "c.zip"] { t.file("home/Downloads/\(n)") }
        // 第 3 个移之前断掉：取那一刻磁盘上的记录，当作应用就停在这里
        let spy = SpyTrasher(dir: trash, log: log, failAt: 3)
        _ = cleaner(spy).clean([f("a.zip"), f("b.zip"), f("c.zip")])
        let atCrash = try #require(spy.seen.last)
        try withFileLock(log.url) { try log.save(atCrash) }
        #expect(atCrash.last?.unfinished == true && atCrash.last?.items.count == 2)

        let c = cleaner(FakeTrasher(dir: trash))
        #expect(c.canUndo())
        #expect(c.undoLast().sorted() == ["已放回：a.zip", "已放回：b.zip"])
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: home.appendingPathComponent("Downloads/a.zip").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("Downloads/b.zip").path))
    }

    @Test func 写不进操作记录时_提示这次不能撤销() throws {
        for n in ["a.zip", "b.zip"] { t.file("home/Downloads/\(n)") }
        final class OnceBroken: Trasher, @unchecked Sendable {
            let inner: FakeTrasher; let log: OperationLog; var n = 0
            init(_ dir: URL, _ log: OperationLog) { inner = FakeTrasher(dir: dir); self.log = log }
            func trash(_ url: URL) throws -> URL {
                n += 1
                // 第 1 项清完后的那次写入会失败：把记录文件换成读不了的
                if n == 2 { try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: log.url.path) }
                return try inner.trash(url)
            }
        }
        let trasher = OnceBroken(trash, log)
        // 第 1 项落盘之后记录文件变得读不了：后面几次写都失败，结果要提示不能撤销
        let batch = cleaner(trasher).clean([f("a.zip"), f("b.zip")])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.url.path)
        #expect(batch.note?.contains("操作记录没保存成功") == true)
    }
}
