import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct DownloadsTests {
    // 小文件实际也占一个块（4 KB），默认阈值要远大于它，只有专门测大文件的用例才调小
    func scan(_ t: TempDir, _ meta: FakeMetadata, bigBytes: Int64 = 1_000_000_000) -> [String: Finding] {
        var rules = DownloadsRules()
        rules.bigBytes = bigBytes
        let found = DownloadsScanner(root: t.url, now: now, meta: meta, rules: rules).scan()
        return Dictionary(uniqueKeysWithValues: found.map { ($0.title, $0) })
    }

    @Test func 安装包超过七天建议清理_七天内不建议() {
        let t = TempDir()
        t.file("old.dmg"); t.file("new.pkg")
        let r = scan(t, FakeMetadata(added: ["old.dmg": daysAgo(10), "new.pkg": daysAgo(3)]))
        #expect(r["old.dmg"]?.category == "安装包")
        #expect(r["old.dmg"]?.suggested == true)
        #expect(r["old.dmg"]?.cleanup == .trash)
        #expect(r["new.pkg"] == nil)
    }

    @Test func 压缩包旁边有同名文件夹才算已解压() {
        let t = TempDir()
        t.file("skill-main.zip"); t.dir("skill-main")
        t.file("data.tar.gz"); t.dir("data")
        t.file("lonely.zip")
        let r = scan(t, FakeMetadata(added: ["skill-main.zip": daysAgo(2), "data.tar.gz": daysAgo(2),
                                             "lonely.zip": daysAgo(2), "skill-main": daysAgo(2), "data": daysAgo(2)]))
        #expect(r["skill-main.zip"]?.category == "已解压的压缩包")
        #expect(r["skill-main.zip"]?.suggested == true)
        #expect(r["data.tar.gz"]?.category == "已解压的压缩包")
        #expect(r["lonely.zip"] == nil)
        // 解压出来的文件夹本身是用户的，不建议
        #expect(r["skill-main"] == nil)
    }

    @Test func 三十天没打开列出但不勾选_从没打开时按下载日期算() {
        let t = TempDir()
        t.file("book.pdf"); t.file("audio.m4a"); t.file("fresh.pdf")
        let r = scan(t, FakeMetadata(
            added: ["book.pdf": daysAgo(40), "audio.m4a": daysAgo(60), "fresh.pdf": daysAgo(40)],
            used: ["audio.m4a": daysAgo(50), "fresh.pdf": daysAgo(5)]))
        #expect(r["book.pdf"]?.category == "久未打开")
        #expect(r["book.pdf"]?.suggested == false)
        #expect(r["book.pdf"]?.detail.contains("没打开过") == true)
        #expect(r["audio.m4a"]?.detail.contains("上次打开") == true)
        #expect(r["fresh.pdf"] == nil)
    }

    @Test func 最近的大文件只提示不勾选() {
        let t = TempDir()
        t.file("big.mp4", bytes: 50_000); t.file("small.mp4", bytes: 10)
        let r = scan(t, FakeMetadata(added: ["big.mp4": daysAgo(1), "small.mp4": daysAgo(1)]), bigBytes: 20_000)
        #expect(r["big.mp4"]?.category == "最近下载的大文件")
        #expect(r["big.mp4"]?.suggested == false)
        #expect(r["big.mp4"]?.cleanup == Cleanup.none) // PRD 4.1：只提示，不能勾选
        #expect(r["small.mp4"] == nil)
    }

    @Test func 打了保留标签的永远不建议_隐藏文件不看() {
        let t = TempDir()
        t.file("keep.dmg"); t.file(".DS_Store")
        let r = scan(t, FakeMetadata(added: ["keep.dmg": daysAgo(100), ".DS_Store": daysAgo(100)],
                                     tagged: ["keep.dmg": ["保留"]]))
        #expect(r.isEmpty)
    }
}

/// 独立测试员的对抗用例（2026-11-05 第 2 批审查）。断言写的是「期望的安全行为」：失败的用例就是发现的 bug。
@Suite struct DownloadsAdversarialTests {
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

    // MARK: - 下载区边界

    @Test func 下载区边界() throws {
        let dl = home.appendingPathComponent("Downloads")
        t.file("home/Downloads/seven.dmg")
        t.file("home/Downloads/eight.dmg")
        t.file("home/Downloads/thirty.txt")
        t.file("home/Downloads/x.tar.gz")
        t.dir("home/Downloads/x")
        t.file("home/Downloads/kept.dmg")
        t.dir("home/Downloads/folder.zip")
        t.dir("home/Downloads/folder")
        var meta = FakeMetadata()
        meta.added = ["seven.dmg": daysAgo(7), "eight.dmg": daysAgo(7.01), "thirty.txt": daysAgo(30),
                      "x.tar.gz": daysAgo(1), "x": daysAgo(1), "kept.dmg": daysAgo(90),
                      "folder.zip": daysAgo(1), "folder": daysAgo(1)]
        meta.tagged = ["kept.dmg": ["保留"]]
        let found = DownloadsScanner(root: dl, now: now, meta: meta).scan()
        func cat(_ n: String) -> String? { found.first { $0.title == n }?.category }
        #expect(cat("seven.dmg") == nil)          // 恰好 7 天：不算「超过」
        #expect(cat("eight.dmg") == "安装包")
        #expect(cat("thirty.txt") == nil)         // 恰好 30 天：不算
        #expect(cat("x.tar.gz") == "已解压的压缩包")
        #expect(cat("kept.dmg") == nil)
        #expect(cat("folder.zip") == nil, "名字以 .zip 结尾的文件夹被当成已解压的压缩包建议清理")
    }
}
