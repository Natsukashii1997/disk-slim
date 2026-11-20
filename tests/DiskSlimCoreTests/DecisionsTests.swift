import Foundation
import Testing
@testable import DiskSlimCore

// 以下来自第 0–6 批整体审查（2026-11-05）的对抗测试：每个用例只测一件事，注释写期望。
// 这些用例在提交 e02ed76 上都失败，说明对应的问题当时还在。
@Suite struct DecisionsTests {
    let t = TempDir()

    /// 期望：「保留」按项记（PRD 3.3）。用户在「久未打开」的卡片上保留了 x.zip，后来解压出同名文件夹，
    /// 它变成「已解压的压缩包」，也不该重新被默认勾选（否则「清理建议项」会把它移走）。
    /// 实际：决定按「分组 + 路径」记，分组一变就对不上，x.zip 又被默认勾选。
    @Test func 保留过的文件换了分组_仍不该被默认勾选() {
        let path = t.url.appendingPathComponent("Downloads/x.zip")
        let stale = downloadsItem(path, category: "久未打开", suggested: false)
        var d = Decisions()
        d.keep(WeeklyCard(id: "downloads|久未打开", tag: "久未打开", title: "t", why: "w", findings: [stale]), now: now)

        let extracted = downloadsItem(path, category: "已解压的压缩包", suggested: true)
        #expect(applyDecisions([extracted], d).first?.suggested == false)
    }

    /// 期望：decisions.json 在但读不了时，之后保存新的决定不能把原来所有「保留」覆盖掉。
    /// 实际：读不了当成「没有决定」，下一次保存整份覆盖，保留过的下载文件重新被默认勾选。
    @Test func 决定记录读不了时_保存新决定不该覆盖掉旧的保留() throws {
        let log = DecisionLog(url: t.url.appendingPathComponent("decisions.json"))
        let kept = downloadsItem(t.url.appendingPathComponent("Downloads/keep.dmg"))
        var old = Decisions()
        old.keep(WeeklyCard(id: "k", tag: "安装包", title: "t", why: "w", findings: [kept]), now: now)
        try log.save(old)

        chmod(log.url.path, 0o000)
        var d = log.load() // 应用启动时读
        let other = downloadsItem(t.url.appendingPathComponent("Downloads/other.dmg"))
        d.snooze(WeeklyCard(id: "o", tag: "安装包", title: "t", why: "w", findings: [other]), now: now)
        try? log.save(d) // 之后用户在卡片上点了「下周再问」
        chmod(log.url.path, 0o644)

        #expect(log.load().isKept(kept))
    }
}
