import DiskSlimCore
import Foundation
import SwiftUI

/// 面板里的页面：首页 + 四个下钻页（第 2 版「首页 + 下钻」）。
enum Page: Hashable {
    case home, downloads, caches, decide, records
}

extension Finding {
    /// 每一项归到哪个下钻页
    var page: Page {
        if area == .downloads { return .downloads }
        if risk == .readOnly { return .records }
        if risk == .confirm || cleanup == .none { return .decide }
        return .caches
    }

    /// 能不能勾选（只展示、没有清理方式的不能）
    var selectable: Bool { risk != .readOnly && cleanup != .none }
}

struct Toast: Identifiable {
    let id = UUID()
    let text: String
    let canUndo: Bool
}

@MainActor
final class Store: ObservableObject {
    @Published var report: ScanReport?
    @Published var disk: DiskStatus?
    @Published var scanning = false
    @Published var working = false
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var page: Page = .home
    @Published var confirming: [Finding]?
    @Published var toast: Toast?

    let home: URL
    /// 每次扫描加一；扫描结果回来时代次不对就丢掉（清理后的新扫描要盖过清理前发起的旧扫描）
    private var scanGeneration = 0

    /// 正在扫描或清理时，清理和撤销按钮都不能点
    var busy: Bool { scanning || working }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        disk = diskStatus(of: home)
    }

    private var cleaner: Cleaner { Scan(home: home).cleaner() }

    // MARK: 扫描

    func refreshDisk() { disk = diskStatus(of: home) }

    /// 打开面板时调用：没扫过或超过 10 分钟就重扫
    func scanIfStale() {
        refreshDisk()
        if let r = report, Date().timeIntervalSince(r.scannedAt) < 600 { return }
        scan()
    }

    /// `force` 为 true 时（清理、撤销之后）即使正在扫描也重新开始，旧的那次结果会被丢掉
    func scan(force: Bool = false) {
        if scanning && !force { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanning = true
        let home = home
        Task.detached {
            let r = Scan(home: home).run()
            await MainActor.run {
                guard generation == self.scanGeneration else { return }
                self.apply(r)
            }
        }
    }

    func apply(_ r: ScanReport) {
        report = r
        disk = r.disk
        selected = Set(r.findings.filter(\.suggested).map(\.id))
        scanning = false
    }

    // MARK: 查询

    func findings(_ page: Page) -> [Finding] { report?.findings.filter { $0.page == page } ?? [] }
    func picked(_ page: Page) -> [Finding] { findings(page).filter { $0.selectable && selected.contains($0.id) } }
    /// 首页大按钮：下载 + 缓存与构建产物里已勾选的
    var suggestedPicks: [Finding] { picked(.downloads) + picked(.caches) }

    func toggle(_ f: Finding) {
        guard f.selectable else { return }
        if selected.contains(f.id) { selected.remove(f.id) } else { selected.insert(f.id) }
    }

    // MARK: 清理

    func askToClean(_ list: [Finding]) { if !list.isEmpty && !busy { confirming = list } }

    func clean(_ list: [Finding]) {
        confirming = nil
        guard !busy else { return }
        working = true
        toast = nil
        let cleaner = cleaner
        Task.detached {
            let batch = cleaner.clean(list)
            await MainActor.run {
                self.working = false
                self.toast = Toast(text: Self.summary(batch), canUndo: batch.trashedBytes > 0 && batch.note == nil)
                self.report = nil
                self.scan(force: true)
            }
        }
    }

    func undo() {
        guard !working else { return }
        toast = nil
        working = true
        let cleaner = cleaner
        Task.detached {
            let lines = cleaner.undoLast()
            await MainActor.run {
                let placed = lines.filter { $0.hasPrefix("已放回") }.count
                let others = lines.filter { !$0.hasPrefix("已放回") }
                var text = placed > 0 ? "已放回 \(placed) 项" : ""
                if !others.isEmpty { text += (text.isEmpty ? "" : "；") + others.joined(separator: "；") }
                self.working = false
                self.toast = Toast(text: text, canUndo: false)
                self.report = nil
                self.scan(force: true)
            }
        }
    }

    nonisolated static func summary(_ b: Batch) -> String {
        var parts: [String] = []
        if b.trashedBytes > 0 { parts.append("移到废纸篓 \(formatBytes(b.trashedBytes))（清空后才释放）") }
        if b.freedBytes > 0 { parts.append("已释放 \(formatBytes(b.freedBytes))") }
        let skipped = b.items.filter { $0.outcome != .done }.count
        if skipped > 0 { parts.append("\(skipped) 项没清（正在使用、刚有变化、已经不在或没装对应工具）") }
        var text = parts.isEmpty ? "没有清理任何东西" : parts.joined(separator: "，")
        if let note = b.note { text += "。注意：\(note)" }
        return text
    }
}

func total(_ list: [Finding]) -> Int64 { list.reduce(0) { $0 + $1.bytes } }
