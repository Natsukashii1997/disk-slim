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
