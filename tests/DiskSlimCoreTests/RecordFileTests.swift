import Foundation
import Testing
@testable import DiskSlimCore

/// 五份记录文件共用的读写（第三批）：留底名字统一、都加锁、读不了不写、旧格式照样能读
@Suite struct RecordFileTests {
    let t = TempDir()
    var dir: URL { t.url.appendingPathComponent("disk-slim") }
    let now = Date(timeIntervalSince1970: 1_763_700_000)

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func breakFile(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name)
        try Data("{ broken".utf8).write(to: u)
        return u
    }

    @Test func 五份记录坏了都留底成同一种名字_内容原样() throws {
        _ = try breakFile("history.json"); _ = OperationLog(url: dir.appendingPathComponent("history.json")).load()
        _ = try breakFile("usage.json"); _ = UsageLog(url: dir.appendingPathComponent("usage.json")).load()
        _ = try breakFile("decisions.json"); _ = DecisionLog(url: dir.appendingPathComponent("decisions.json")).load()
        _ = try breakFile("alerts.json"); _ = AlertStore(url: dir.appendingPathComponent("alerts.json")).load()
        _ = try breakFile("memory.json"); _ = MemoryLog(url: dir.appendingPathComponent("memory.json")).load(now: now)
        let left = try names()
        for name in ["history", "usage", "decisions", "alerts", "memory"] {
            let backups = left.filter { $0.hasPrefix("\(name)-damaged-") }
            #expect(backups.count == 1, "\(name)：\(left)")
            // <名字>-damaged-<秒>-<8位>.json.bak
            let parts = backups.first?.dropLast(".json.bak".count).split(separator: "-") ?? []
            #expect(parts.count == 4 && parts[2].allSatisfy(\.isNumber) && parts[3].count == 8, "\(backups)")
            if let b = backups.first {
                #expect(try String(contentsOf: dir.appendingPathComponent(b), encoding: .utf8) == "{ broken")
            }
            #expect(!left.contains("\(name).json"), "坏文件已挪走")
        }
    }

    @Test func 只读时坏文件不挪() throws {
        let u = try breakFile("alerts.json")
        #expect(AlertStore(url: u).load(readOnly: true) == AlertState())
        #expect(MemoryLog(url: try breakFile("memory.json")).load(now: now, readOnly: true).trackingSince == now)
        #expect(try names() == ["alerts.json", "memory.json"])
    }

    @Test func 提醒和决定保存时也加锁() throws {
        try AlertStore(url: dir.appendingPathComponent("alerts.json")).save(AlertState())
        try DecisionLog(url: dir.appendingPathComponent("decisions.json")).save(Decisions())
        let left = try names()
        #expect(left.contains("alerts.json.lock") && left.contains("decisions.json.lock"))
    }

    @Test func 内存记录读不了时报错不写_不再覆盖() throws {
        let log = MemoryLog(url: dir.appendingPathComponent("memory.json"))
        var r = MemoryRecord(trackingSince: now)
        r.activated("a.b", at: now)
        try log.save(r)
        let before = try Data(contentsOf: log.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: log.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.url.path) }
        #expect(throws: (any Error).self) { try log.save(MemoryRecord(trackingSince: now)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.url.path)
        #expect(try Data(contentsOf: log.url) == before)
    }

    @Test func 提醒的上次自动清理_旧的数字格式照样能读_新写的是文本() throws {
        let store = AlertStore(url: dir.appendingPathComponent("alerts.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 第三批之前的写法：JSONEncoder 默认把 Date 存成离 2001-01-01 的秒数
        let old = #"{"autoCleanAt":785000000.5,"sent":{"weekly":"2026-10-30"},"settings":{"autoClean":true,"growth":true,"lowSpace":true,"weekly":true}}"#
        try Data(old.utf8).write(to: store.url)
        let s = store.load()
        #expect(s.autoCleanAt == Date(timeIntervalSinceReferenceDate: 785_000_000.5))
        #expect(s.sent["weekly"] == "2026-10-30" && s.settings.autoClean)

        var next = s
        next.autoCleanAt = now
        try store.save(next)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains(#""autoCleanAt" : "2025-11-21T04:40:00Z""#), "\(text)")
        #expect(store.load() == next)
    }

    @Test func 旧版本写的四份记录照样能读() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 第三批之前各自的写法（日期 ISO、斜杠转义与否不同），逐字取自旧编码器的输出格式
        let usage = #"[{"at":"2025-11-20T04:40:00Z","freeBytes":5,"parts":{"下载文件夹":3},"totalBytes":10}]"#
        try Data(usage.utf8).write(to: dir.appendingPathComponent("usage.json"))
        #expect(UsageLog(url: dir.appendingPathComponent("usage.json")).load().first?.parts == ["下载文件夹": 3])

        let decisions = #"{"kept":{},"snoozed":{"\/Users\/x\/a":"2025-11-28T04:40:00Z"}}"#
        try Data(decisions.utf8).write(to: dir.appendingPathComponent("decisions.json"))
        #expect(DecisionLog(url: dir.appendingPathComponent("decisions.json")).load().snoozed["/Users/x/a"] != nil)

        let history = #"[{"at":"2025-11-20T04:40:00Z","id":"x","items":[],"restored":[],"undone":false}]"#
        try Data(history.utf8).write(to: dir.appendingPathComponent("history.json"))
        let batches = OperationLog(url: dir.appendingPathComponent("history.json")).load()
        #expect(batches.count == 1 && batches[0].unfinished == nil)
    }

    @Test func 清完的批次写出来和以前一样_不多出进行中字段() throws {
        let log = OperationLog(url: dir.appendingPathComponent("history.json"))
        var b = Batch(id: "x", at: now, items: [], undone: false, restored: [], note: nil, unfinished: true)
        try log.put(b)
        #expect(try String(contentsOf: log.url, encoding: .utf8).contains("unfinished"))
        b.unfinished = nil
        try log.put(b)
        #expect(!(try String(contentsOf: log.url, encoding: .utf8)).contains("unfinished"))
        #expect(log.load().count == 1)
    }

    @Test func 写入操作记录时原地替换同一批_不打乱别的进程追加的() throws {
        let log = OperationLog(url: dir.appendingPathComponent("history.json"))
        let mine = Batch(id: "mine", at: now, items: [], undone: false, restored: [], note: nil, unfinished: true)
        try log.put(mine)
        // 期间命令行又清了一批
        try log.put(Batch(id: "cli", at: now, items: [], undone: false, restored: [], note: nil))
        var done = mine
        done.unfinished = nil
        try log.put(done)
        #expect(log.load().map(\.id) == ["mine", "cli"])
        #expect(log.load().allSatisfy { $0.unfinished == nil })
    }

    @Test func 操作记录只留最近200批() throws {
        let log = OperationLog(url: dir.appendingPathComponent("history.json"))
        try log.save((0..<205).map { Batch(id: "\($0)", at: now, items: [], undone: false, restored: [], note: nil) })
        try log.put(Batch(id: "new", at: now, items: [], undone: false, restored: [], note: nil))
        let all = log.load()
        #expect(all.count == 200 && all.last?.id == "new" && all.first?.id == "6")
    }
}
