import Foundation
@testable import DiskSlimCore

/// 每个测试一个临时目录，用完自动删。
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("disk-slim-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func file(_ path: String, bytes: Int = 16, modified: Date? = nil) -> URL {
        let u = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(count: bytes).write(to: u)
        if let modified { setModified(u, modified) }
        return u
    }

    @discardableResult
    func dir(_ path: String, modified: Date? = nil) -> URL {
        let u = url.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        if let modified { setModified(u, modified) }
        return u
    }

    func setModified(_ u: URL, _ date: Date) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
    }
}

/// 按文件名给出元数据。
struct FakeMetadata: FileMetadata {
    var added: [String: Date] = [:]
    var used: [String: Date] = [:]
    var tagged: [String: [String]] = [:]
    func dateAdded(_ url: URL) -> Date? { added[url.lastPathComponent] }
    func lastUsed(_ url: URL) -> Date? { used[url.lastPathComponent] }
    func tags(_ url: URL) -> [String] { tagged[url.lastPathComponent] ?? [] }
}

/// 按命令前缀匹配给出输出；没配的命令返回失败。
final class FakeRunner: CommandRunner {
    var replies: [(match: (([String], URL?) -> Bool), status: Int32, output: String)] = []
    func on(_ status: Int32 = 0, _ output: String, when match: @escaping ([String], URL?) -> Bool) {
        replies.append((match, status, output))
    }
    func run(_ args: [String], cwd: URL?) -> (status: Int32, output: String) {
        for r in replies where r.match(args, cwd) { return (r.status, r.output) }
        return (1, "")
    }
}

let now = Date(timeIntervalSince1970: 1_793_840_000) // 2026-11-05 前后，测试只看相对天数
func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

/// 让 worktree 满足「是 Rust 构建目录、PR 已合并、没改动、没在编译」的假回复；测某一条时只破坏那一条。
@discardableResult
func healthyRunner(_ run: FakeRunner = FakeRunner(), branch: String = "feat-x", head: String = "abc123") -> FakeRunner {
    run.on(0, "\(branch) \(head)\n") { a, _ in a.first == "gh" }
    run.on(0, branch + "\n") { a, _ in a.contains("--show-current") }
    run.on(0, head + "\n") { a, _ in a.contains("rev-parse") }
    run.on(0, "") { a, _ in a.contains("check-ignore") }
    run.on(0, "") { a, _ in a.contains("--porcelain") }
    run.on(0, "") { a, _ in a.first == "ps" }
    return run
}
