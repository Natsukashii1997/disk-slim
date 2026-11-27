import Foundation
import Testing
@testable import DiskSlimCore

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct SizeAdversarialTests {
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

    // MARK: - 大小

    @Test func 指向目录的符号链接_大小不该算目标目录() throws {
        t.file("outside/big.bin", bytes: 1_000_000)
        t.dir("home/Downloads")
        let link = home.appendingPathComponent("Downloads/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: t.url.appendingPathComponent("outside"))
        #expect(allocatedSize(link) < 100_000, "符号链接被算成了目标目录的大小：\(allocatedSize(link))")
    }
}

@Suite struct MeasureSizeTests {
    let fm = FileManager.default

    @Test func 硬链接只算一份_含子目录里的多份链接() throws {
        let t = TempDir()
        let dir = t.dir("target")
        let orig = t.file("target/deps/libfoo.rlib", bytes: 65_536)
        let one = allocatedSize(orig)
        #expect(one >= 65_536)

        try fm.linkItem(at: orig, to: dir.appendingPathComponent("libfoo.rlib"))
        let nested = t.dir("target/build/nested")
        try fm.linkItem(at: orig, to: nested.appendingPathComponent("libfoo-copy.rlib"))

        #expect(allocatedSize(dir) == one)
        #expect(allocatedSizeIfReadable(dir) == one)
    }

    @Test func 多组硬链接与普通文件混在一起_硬链接去重_不同文件照常相加() throws {
        let t = TempDir()
        let dir = t.dir("mix")
        let a = t.file("mix/a.bin", bytes: 65_536)
        let b = t.file("mix/b.bin", bytes: 131_072)
        let c = t.file("mix/plain1.bin", bytes: 32_768)
        let d = t.file("mix/sub/plain2.bin", bytes: 49_152)

        try fm.linkItem(at: a, to: dir.appendingPathComponent("sub/a-link.bin"))
        try fm.linkItem(at: b, to: dir.appendingPathComponent("sub/b-link.bin"))

        let expected = allocatedSize(a) + allocatedSize(b) + allocatedSize(c) + allocatedSize(d)
        #expect(allocatedSize(dir) == expected)
        #expect(allocatedSizeIfReadable(dir) == expected)
    }

    @Test func 硬链接另一份在测量目录外_目录内那份照常计入() throws {
        let t = TempDir()
        let outside = t.file("outside/a.bin", bytes: 65_536)
        let inside = t.dir("inside")
        try fm.linkItem(at: outside, to: inside.appendingPathComponent("a.bin"))

        let one = allocatedSize(outside)
        #expect(allocatedSize(inside) == one)
        // 测量共同父目录时才去重成一份
        #expect(allocatedSize(t.url) == one)
    }

    @Test func 单个文件_空目录_不存在路径() {
        let t = TempDir()
        let f = t.file("single.bin", bytes: 40_960)
        #expect(allocatedSize(f) >= 40_960)
        #expect(allocatedSizeIfReadable(f) == allocatedSize(f))

        let empty = t.dir("empty")
        #expect(allocatedSize(empty) == 0)
        #expect(allocatedSizeIfReadable(empty) == 0)

        let missing = t.url.appendingPathComponent("no-such-file")
        #expect(allocatedSize(missing) == 0)
        #expect(allocatedSizeIfReadable(missing) == nil)
    }

    @Test func 目录里不跟随符号链接_悬空链接不报错() throws {
        let t = TempDir()
        t.file("outside/big.bin", bytes: 1_000_000)
        let dir = t.dir("box")
        let real = t.file("box/real.bin", bytes: 65_536)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-dir"),
                                  withDestinationURL: t.url.appendingPathComponent("outside"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link-file"),
                                  withDestinationURL: t.url.appendingPathComponent("outside/big.bin"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("broken"),
                                  withDestinationURL: t.url.appendingPathComponent("does-not-exist"))

        let size = allocatedSizeIfReadable(dir)
        #expect(size != nil)
        #expect(size! >= allocatedSize(real))
        #expect(size! < 200_000)
        // 带目录标记的符号链接 URL 也不跟随
        let linkAsDir = URL(fileURLWithPath: dir.appendingPathComponent("link-dir").path, isDirectory: true)
        #expect(allocatedSize(linkAsDir) < 100_000)
    }

    @Test func 不可读目录触发onError_可读同级文件照常累加() throws {
        let t = TempDir()
        let dir = t.dir("parent")
        let ok = t.file("parent/ok.bin", bytes: 65_536)
        let secret = t.dir("parent/secret")
        t.file("parent/secret/hidden.bin", bytes: 65_536)

        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secret.path) }

        #expect(allocatedSize(dir) == allocatedSize(ok))
        #expect(allocatedSizeIfReadable(dir) == nil)
        #expect(allocatedSize(secret) == 0)
        #expect(allocatedSizeIfReadable(secret) == nil)
    }

    @Test func FileID按设备和inode共同区分() {
        #expect(FileID(dev: 1, ino: 42) == FileID(dev: 1, ino: 42))
        #expect(FileID(dev: 1, ino: 42) != FileID(dev: 2, ino: 42))
        #expect(FileID(dev: 1, ino: 42) != FileID(dev: 1, ino: 43))
        let set: Set<FileID> = [FileID(dev: 1, ino: 42), FileID(dev: 1, ino: 42), FileID(dev: 2, ino: 42)]
        #expect(set.count == 2)
    }
}

// 以下来自第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题当时还在。
/// 改进程环境变量，必须串行
@Suite(.serialized) struct ProcessRunnerLocaleTests {
    /// 期望：从访达或登录项启动的应用没有 LANG / LC_*（实测已装的 /Applications/DiskSlim.app 进程就没有），
    /// 这时也要认出命令行里带着 target 路径的进程，正在用的构建产物不删（PRD 4.2「无编译进程在用」）。
    /// 实际：`ps` 在 C 区域设置下把路径里的「个人」转义成 `M-dM-8…`（同 L-09），字符串永远对不上，照删不误。
    @Test func 没有区域设置时_正在使用的构建产物不该被删() throws {
        let t = TempDir()
        let home = t.url.appendingPathComponent("个人/home")
        let target = t.dir("个人/home/work/proj/.claude/worktrees/wt/target")
        let server = t.file("个人/home/work/proj/.claude/worktrees/wt/target/debug/server", bytes: 4096)

        let names = ["LC_ALL", "LANG", "LC_CTYPE"]
        let saved = names.map { name in (name, getenv(name).map { String(cString: $0) }) }
        names.forEach { unsetenv($0) }
        defer { for (name, value) in saved { if let value { setenv(name, value, 1) } } }

        // 相当于 target/debug/server 正在运行
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "sleep 30", server.path]
        try p.run()
        defer { p.terminate() }
        Thread.sleep(forTimeInterval: 0.3)

        let c = Cleaner(safety: SafetyGuard(home: home, workRoot: home.appendingPathComponent("work")), runner: ProcessRunner(),
                        trasher: FakeTrasher(dir: t.url.appendingPathComponent("Trash")), log: .standard(home: home))
        let f = Finding(area: .hidden, category: "已合并 worktree 的构建产物", title: "proj · wt", detail: "",
                        paths: [target.path], bytes: 1, risk: .safe, suggested: true, cleanup: .remove)
        _ = c.clean([f])
        #expect(FileManager.default.fileExists(atPath: target.path))
    }
}

@Suite struct FormatTests {
    @Test func 日期按北京时间显示() {
        // 2026-10-05 17:00 UTC 是北京时间 10 月 6 日凌晨 1 点
        let d = ISO8601DateFormatter().date(from: "2026-10-05T17:00:00Z")!
        #expect(BeijingTime.monthDay(d) == "10 月 6 日")
    }

    @Test func 大小按1024进位() {
        #expect(formatBytes(43 * 1_048_576) == "43 MB")
        #expect(formatBytes(Int64(6.2 * 1_073_741_824)) == "6.2 GB")
        #expect(formatBytes(500) == "1 KB")
    }
}
