import Foundation
import Testing
@testable import DiskSlimCore

/// 每一项「是什么」（`Finding.kind`）和由它派生的名字。这些名字有的显示在界面上，有的是 usage.json 里落盘的键，
/// 改一个字都要是有意的：这里逐字锁住（issue #20 之前这些判断散在各处，直接拿分组名的中文去比）。
@Suite struct FindingKindTests {
    func f(_ area: Area, _ category: String, _ title: String, cleanup: Cleanup = .trash, risk: Risk = .safe) -> Finding {
        Finding(area: area, category: category, title: title, detail: "d", paths: ["/p/" + title], bytes: 1, risk: risk,
                suggested: false, cleanup: cleanup)
    }

    @Test func 分组名一个字都没变() {
        #expect(Category.installer == "安装包")
        #expect(Category.extractedArchive == "已解压的压缩包")
        #expect(Category.staleDownload == "久未打开")
        #expect(Category.recentBigDownload == "最近下载的大文件")
        #expect(Category.landedBuild == "已合并 worktree 的构建产物")
        #expect(Category.activeBuild == "还在做的 worktree 构建产物")
        #expect(Category.blockedBuild == "暂时不能清的构建产物")
        #expect(Category.packageCache == "包管理器缓存")
        #expect(Category.testBrowser == "测试用浏览器")
        #expect(Category.backup == "备份快照")
        #expect(Category.vm == "虚拟机")
        #expect(Category.records == "对话记录")
    }

    @Test func 扫描器给出的每个分组都认得出类型() {
        let kinds: [(String, Finding.Kind)] = [
            (Category.installer, .installer), (Category.extractedArchive, .extractedArchive),
            (Category.staleDownload, .staleDownload), (Category.recentBigDownload, .recentBigDownload),
            (Category.landedBuild, .worktreeBuild), (Category.activeBuild, .worktreeBuild), (Category.blockedBuild, .worktreeBuild),
            (Category.packageCache, .packageCache), (Category.testBrowser, .testBrowser), (Category.backup, .backup),
            (Category.vm, .vm), (Category.records, .records), ("别的什么", .other),
        ]
        for (category, kind) in kinds { #expect(f(.hidden, category, "t").kind == kind, "\(category)") }
        // 已知位置表里的每一项都落在认识的类型里
        for p in KnownPlaces.all { #expect(f(.hidden, p.category, p.title).kind != .other, "\(p.title)") }
    }

    /// usage.json 里各位置的名字：改了，涨幅曲线就和以前的记录接不上
    @Test func 涨幅记录里的名字不变() {
        #expect(Usage.partName(f(.hidden, Category.landedBuild, "postpane · 439-relay-end")) == "postpane · worktree 构建产物")
        #expect(Usage.partName(f(.hidden, Category.activeBuild, "a · b · wt")) == "a · b · worktree 构建产物")
        #expect(Usage.partName(f(.hidden, Category.blockedBuild, "postpane · x")) == "postpane · worktree 构建产物")
        #expect(Usage.partName(f(.hidden, Category.backup, "Codex 备份 · session-20260916-180223")) == "Codex 备份")
        #expect(Usage.partName(f(.hidden, Category.packageCache, "npm 缓存")) == "npm 缓存")
        #expect(Usage.partName(f(.hidden, Category.vm, "Colima 虚拟机")) == "Colima 虚拟机")
        #expect(Usage.partName(f(.hidden, Category.records, "Codex 对话记录", risk: .readOnly)) == "Codex 对话记录")
    }

    @Test func 首页列表里的名字不变() {
        #expect(friendlyName(f(.hidden, Category.activeBuild, "postpane · 439-relay-end")) == "AI 编译文件 · postpane")
        #expect(friendlyName(f(.hidden, Category.landedBuild, "a · b · wt")) == "AI 编译文件 · a · b")
        #expect(friendlyName(f(.hidden, Category.backup, "Codex 备份 · session-20260916-180223")) == "Codex 备份")
        #expect(friendlyName(f(.hidden, Category.packageCache, "npm 缓存")) == "npm 缓存")
        #expect(friendlyName(f(.downloads, Category.installer, "a.dmg")) == "a.dmg")
        // 只有 Codex 备份那几项才缩成「Codex 备份」。下载文件夹里碰巧叫这个名字的文件照显示真名
        // （issue #20 之前按标题开头判断，会把它也缩掉；独立审查指出后保留新的判断）
        #expect(friendlyName(f(.downloads, Category.recentBigDownload, "Codex 备份 · 导出.zip")) == "Codex 备份 · 导出.zip")
    }

    @Test func 替你挑好的按用途合并的名字不变() {
        #expect(pickedLabel(f(.downloads, Category.installer, "a.dmg")) == "下载里装好的安装包")
        #expect(pickedLabel(f(.downloads, Category.extractedArchive, "a.zip")) == "下载里解压过的压缩包")
        #expect(pickedLabel(f(.downloads, Category.staleDownload, "a.pdf")) == "下载里的久未打开")
        #expect(pickedLabel(f(.hidden, Category.landedBuild, "p · w")) == "AI 写代码编出来的文件")
        #expect(pickedLabel(f(.hidden, Category.activeBuild, "p · w")) == "AI 写代码编出来的文件")
        #expect(pickedLabel(f(.hidden, Category.backup, "Codex 备份 · x")) == "Codex 旧备份")
        #expect(pickedLabel(f(.hidden, Category.packageCache, "uv 缓存")) == "下载缓存")
        #expect(pickedLabel(f(.hidden, Category.testBrowser, "Playwright 浏览器")) == "测试用浏览器")
        #expect(pickedLabel(f(.hidden, Category.vm, "Colima 虚拟机")) == "虚拟机")
    }

    /// `scan --json` 的字段：类型是算出来的，不进 JSON
    @Test func 扫描结果的JSON字段不变() throws {
        let data = try JSONEncoder().encode(f(.hidden, Category.packageCache, "npm 缓存", cleanup: .command(["npm"])))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        #expect(keys == ["area", "bytes", "category", "cleanup", "detail", "id", "paths", "risk", "suggested", "title"])
    }

    @Test func 撤销结果里数得出放回了几项() {
        #expect("\(Cleaner.restoredPrefix)：a.dmg" == "已放回：a.dmg")
    }
}
