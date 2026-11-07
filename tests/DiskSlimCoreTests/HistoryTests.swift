import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct HistoryTests {
    let pnpm = Cleanup.command(["pnpm", "store", "prune"])
    let npm = Cleanup.command(["npm", "cache", "clean", "--force"])

    func finding(_ title: String, _ cleanup: Cleanup) -> Finding {
        Finding(area: .hidden, category: "包管理器缓存", title: title, detail: "原说明", paths: ["/x/\(title)"],
                bytes: 469 * 1_048_576, risk: .safe, suggested: true, cleanup: cleanup)
    }

    func batch(_ daysAgo: Double, _ cleanup: Cleanup, freed: Int64, outcome: Outcome = .done) -> Batch {
        Batch(id: UUID().uuidString, at: now.addingTimeInterval(-daysAgo * 86_400),
              items: [ItemResult(title: "x", paths: [], cleanup: cleanup, outcome: outcome, message: "",
                                 trashedBytes: 0, freedBytes: freed, trashed: [:])],
              undone: false)
    }

    @Test func 上次几乎没释放的命令不再默认勾选() {
        let out = applyHistory([finding("pnpm 存储", pnpm)], history: [batch(1, pnpm, freed: 0)], now: now)
        #expect(out[0].suggested == false)
        #expect(out[0].detail.contains("只释放了"))
        #expect(out[0].bytes == 469 * 1_048_576) // 目录大小照实显示
        #expect(out[0].id == finding("pnpm 存储", pnpm).id) // 还是同一项
    }

    @Test func 上次确实释放了的照常勾选() {
        let out = applyHistory([finding("npm 缓存", npm)], history: [batch(1, npm, freed: 144 * 1_048_576)], now: now)
        #expect(out[0].suggested == true)
        #expect(out[0].detail == "原说明")
    }

    @Test func 只看最近一次_超过三十天的不算() {
        // 最近一次释放了很多，更早一次没释放：按最近一次
        let recent = applyHistory([finding("pnpm 存储", pnpm)],
                                  history: [batch(10, pnpm, freed: 0), batch(1, pnpm, freed: 300 * 1_048_576)], now: now)
        #expect(recent[0].suggested == true)
        let old = applyHistory([finding("pnpm 存储", pnpm)], history: [batch(40, pnpm, freed: 0)], now: now)
        #expect(old[0].suggested == true)
    }

    @Test func 没执行成功的和别的清理方式不受影响() {
        let skipped = applyHistory([finding("pnpm 存储", pnpm)], history: [batch(1, pnpm, freed: 0, outcome: .skipped)], now: now)
        #expect(skipped[0].suggested == true)
        let trash = Finding(area: .downloads, category: "安装包", title: "a.dmg", detail: "", paths: ["/a.dmg"],
                            bytes: 1, risk: .safe, suggested: true, cleanup: .trash)
        #expect(applyHistory([trash], history: [batch(1, .trash, freed: 0)], now: now)[0].suggested == true)
    }
}
