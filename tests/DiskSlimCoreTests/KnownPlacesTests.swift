import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct KnownPlacesTests {
    @Test func 存在且够大的位置才列出_每个子目录可以各算一项() {
        let t = TempDir()
        t.file(".npm/_cacache/a", bytes: 50_000)
        t.file(".cache/uv/tiny", bytes: 10)
        t.file(".codex/recovery/guard-0901/state.sqlite", bytes: 50_000)
        t.file(".codex/recovery/guard-0916/state.sqlite", bytes: 50_000)
        let found = KnownPlacesScanner(home: t.url, minBytes: 20_000).scan()
        let titles = found.map(\.title)

        #expect(titles.contains("npm 缓存"))
        #expect(!titles.contains("uv 缓存"))
        #expect(titles.contains("Codex 备份 · guard-0901"))
        #expect(titles.contains("Codex 备份 · guard-0916"))
        #expect(found.first { $0.title == "npm 缓存" }?.cleanup == .command(["npm", "cache", "clean", "--force"]))
        #expect(found.first { $0.title == "npm 缓存" }?.suggested == true)
        #expect(found.first { $0.title.hasPrefix("Codex 备份") }?.suggested == false)
    }

    /// 2026-11-18 起（issue #4）：最新一份留着保底，一个月以前的旧份默认勾选（进废纸篓），一个月内的先留着；仍是需确认，不进自动清理
    @Test func Codex备份_留最新一份_一个月前的旧份默认勾选() {
        let t = TempDir()
        let dates: [String: Double] = ["session-guard-0827": 83, "session-guard-0916": 63, "before-mod-0915": 64, "provider-1110": 8]
        for (name, days) in dates {
            t.file(".codex/recovery/\(name)/state.sqlite", bytes: 50_000, modified: daysAgo(days))
            t.setModified(t.url.appendingPathComponent(".codex/recovery/\(name)"), daysAgo(days))
        }
        let found = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now).scan()
        let r = Dictionary(uniqueKeysWithValues: found.map { ($0.title.replacingOccurrences(of: "Codex 备份 · ", with: ""), $0) })
        // 名字排序和时间先后对不上：最新一份按修改时间认
        #expect(r["provider-1110"]?.suggested == false)
        #expect(r["provider-1110"]?.detail.hasSuffix("最新一份，留着保底") == true)
        #expect(r["session-guard-0827"]?.suggested == true)
        #expect(r["session-guard-0916"]?.suggested == true)
        #expect(r["before-mod-0915"]?.suggested == true)
        #expect(found.allSatisfy { $0.risk == .confirm && $0.cleanup == .trash })
        #expect(Alerts.autoCleanPicks(found).isEmpty)
        #expect(found.filter { $0.bucket(now: now) == .picked }.count == 3)
    }

    /// 2026-11-19 起（积压清单组 6）：Playwright 浏览器删了不会自动重新下载，驿窗、剪藏插件的扩展测试直接全挂（两边 L-16）。
    /// 改成需确认、不默认勾选：归「先不动」、不进自动清理；用户自己挑了仍能删。Puppeteer 这次不动，仍是安全、默认勾选
    @Test func Playwright浏览器_需确认_不默认勾选_不进自动清理() {
        let t = TempDir()
        t.file("Library/Caches/ms-playwright/chromium-1248/chrome", bytes: 50_000)
        t.file(".cache/puppeteer/chrome/chrome", bytes: 50_000)
        let found = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now).scan()
        let pw = found.first { $0.title == "Playwright 浏览器" }
        #expect(pw?.risk == .confirm)
        #expect(pw?.suggested == false)
        #expect(pw?.cleanup == .remove)
        #expect(pw?.detail.contains("不会自动重新下载") == true)
        #expect(pw?.bucket(now: now) == .keep)
        #expect(Alerts.autoCleanPicks(found).allSatisfy { $0.title != "Playwright 浏览器" })
        // 用户自己勾了还能删：安全门照样放行
        let guardian = SafetyGuard(home: t.url, workRoot: t.url.appendingPathComponent("work"))
        #expect(pw.map { guardian.refusal(for: $0) } == .some(nil))

        let pp = found.first { $0.title == "Puppeteer 浏览器" }
        #expect(pp?.risk == .safe && pp?.suggested == true)
        #expect(Alerts.autoCleanPicks(found).contains { $0.title == "Puppeteer 浏览器" })
    }

    @Test func Codex备份_一个月内做的除了最新一份也先留着() {
        let t = TempDir()
        for (name, days) in [("a", 10.0), ("b", 2.0)] {
            t.file(".codex/recovery/\(name)/x", bytes: 50_000, modified: daysAgo(days))
            t.setModified(t.url.appendingPathComponent(".codex/recovery/\(name)"), daysAgo(days))
        }
        let found = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now).scan()
        #expect(found.allSatisfy { !$0.suggested })
        #expect(found.first { $0.title.hasSuffix(" · a") }?.detail.hasSuffix("一个月内做的，先留着") == true)
    }

    @Test func 虚拟机_记最近用过的日期_一个月没用才问() {
        for (days, bucket) in [(3.0, Bucket.keep), (45.0, Bucket.ask)] {
            let t = TempDir()
            t.file(".colima/_lima/colima-x/diffdisk", bytes: 60_000, modified: daysAgo(days))
            t.setModified(t.url.appendingPathComponent(".colima/_lima/colima-x"), daysAgo(days))
            t.setModified(t.url.appendingPathComponent(".colima/_lima"), daysAgo(days))
            t.setModified(t.url.appendingPathComponent(".colima"), daysAgo(days))
            let vm = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now).scan().first { $0.title == "Colima 虚拟机" }
            #expect(vm?.bucket(now: now) == bucket, "\(days) 天没用")
            #expect(vm?.suggested == false && vm?.cleanup == Cleanup.none)
            if days < 30 { #expect(vm?.detail.hasSuffix("还用过，先留着") == true) }
            else { #expect(vm?.detail.hasPrefix("45 天没用了。") == true) }
        }
    }

    @Test func 最近修改时间只看往下两层() {
        let t = TempDir()
        let root = t.dir("vm", modified: daysAgo(50))
        t.file("vm/a/b/deep.img", modified: daysAgo(1)) // 第三层，不算
        t.setModified(t.url.appendingPathComponent("vm/a/b"), daysAgo(40))
        t.setModified(t.url.appendingPathComponent("vm/a"), daysAgo(40))
        t.setModified(root, daysAgo(50))
        let got = latestModification(root)!
        #expect(abs(got.timeIntervalSince(daysAgo(40))) < 2)
    }

    /// 审查 L2：30～31 天之间说明和分段要一致
    @Test func 虚拟机刚过30天_说明和分段一致() {
        let t = TempDir()
        t.file("Library/Application Support/Claude/vm_bundles/b/s.img", bytes: 60_000, modified: daysAgo(30.5))
        let vm = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now, useOf: { _ in daysAgo(30.5) }).scan().first
        #expect(vm?.bucket(now: now) == .ask)
        #expect(vm?.detail.hasPrefix("30 天没用了。") == true)
    }

    /// 审查 L3：Colima 开着不重启时，只有第三层的磁盘文件在变
    @Test func 虚拟机最近使用看到第三层的磁盘文件() {
        let t = TempDir()
        t.file(".colima/_lima/colima-x/diffdisk", bytes: 60_000, modified: daysAgo(1))
        for d in [".colima/_lima/colima-x", ".colima/_lima", ".colima"] { t.setModified(t.url.appendingPathComponent(d), daysAgo(60)) }
        let vm = KnownPlacesScanner(home: t.url, minBytes: 20_000, now: now).scan().first { $0.title == "Colima 虚拟机" }
        #expect(vm?.bucket(now: now) == .keep)
    }

    /// 审查 L1：整次扫描用同一个时间，备份的 30 天也按它算
    @Test func 扫描传入的时间也用在备份上() {
        let t = TempDir()
        let home = t.dir("home")
        for (name, days) in [("old", 25.0), ("new", 1.0)] {
            t.file("home/.codex/recovery/\(name)/x", bytes: 60 * 1_048_576, modified: daysAgo(days))
            t.setModified(home.appendingPathComponent(".codex/recovery/\(name)"), daysAgo(days))
        }
        let scan = Scan(home: home, workRoot: home.appendingPathComponent("work"), meta: FakeMetadata(added: [:]), runner: FakeRunner())
        let old = scan.run(now: now).findings.first { $0.title == "Codex 备份 · old" }
        #expect(old?.suggested == false) // 按传入的时间只过了 25 天
        let later = scan.run(now: now.addingTimeInterval(10 * 86_400)).findings.first { $0.title == "Codex 备份 · old" }
        #expect(later?.suggested == true)
    }

    /// L-08：旧版写下的扫描结果、操作日志里没有 lastUsed 这个键，要照样读回
    @Test func 旧格式的Finding没有lastUsed也能读回() throws {
        let json = #"{"id":"x|/a","area":"hidden","category":"虚拟机","title":"t","detail":"d","paths":["/a"],"bytes":1,"risk":"confirm","suggested":false,"cleanup":{"none":{}}}"#
        let f = try JSONDecoder().decode(Finding.self, from: Data(json.utf8))
        #expect(f.lastUsed == nil && f.title == "t")
        let back = try JSONDecoder().decode(Finding.self, from: JSONEncoder().encode(
            Finding(area: .hidden, category: "虚拟机", title: "t", detail: "d", paths: ["/a"], bytes: 1, risk: .confirm,
                    suggested: false, cleanup: .none, lastUsed: now)))
        #expect(back.lastUsed == now)
    }

    @Test func 多个路径合成一项() {
        let t = TempDir()
        t.file(".codex/sessions/a.jsonl", bytes: 30_000)
        t.file(".codex/archived_sessions/b.jsonl", bytes: 30_000)
        let found = KnownPlacesScanner(home: t.url, minBytes: 50_000).scan()
        let codex = found.first { $0.title == "Codex 对话记录" }
        #expect(codex?.paths.count == 2)
        #expect(codex?.risk == .readOnly)
    }

    @Test func 只展示的项永远不勾选也没有清理方式() {
        // 已知位置表里的只展示项
        for p in KnownPlaces.all where p.risk == .readOnly {
            #expect(p.cleanup == .none)
            #expect(p.suggested == false)
        }
        // 就算有人把清理方式写错，Finding 也会强制改回来
        let f = Finding(area: .hidden, category: "对话记录", title: "x", detail: "", paths: ["/x"],
                        bytes: 1, risk: .readOnly, suggested: true, cleanup: .remove)
        #expect(f.suggested == false)
        #expect(f.cleanup == .none)
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
