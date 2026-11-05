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

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        disk = diskStatus(of: home)
    }

    private var cleaner: Cleaner {
        let scan = Scan(home: home)
        return Cleaner(safety: SafetyGuard(home: scan.home, workRoot: scan.workRoot), log: .standard(home: home))
    }

    // MARK: 扫描

    func refreshDisk() { disk = diskStatus(of: home) }

    /// 打开面板时调用：没扫过或超过 10 分钟就重扫
    func scanIfStale() {
        refreshDisk()
        if let r = report, Date().timeIntervalSince(r.scannedAt) < 600 { return }
        scan()
    }

    func scan() {
        guard !scanning else { return }
        scanning = true
        let home = home
        Task.detached {
            let r = Scan(home: home).run()
            await MainActor.run { self.apply(r) }
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

    func askToClean(_ list: [Finding]) { if !list.isEmpty { confirming = list } }

    func clean(_ list: [Finding]) {
        confirming = nil
        working = true
        let cleaner = cleaner
        Task.detached {
            let batch = cleaner.clean(list)
            await MainActor.run {
                self.working = false
                self.toast = Toast(text: Self.summary(batch), canUndo: batch.trashedBytes > 0)
                self.report = nil
                self.scan()
            }
        }
    }

    func undo() {
        toast = nil
        let cleaner = cleaner
        Task.detached {
            let lines = cleaner.undoLast()
            await MainActor.run {
                let placed = lines.filter { $0.hasPrefix("已放回") }.count
                let others = lines.filter { !$0.hasPrefix("已放回") }
                var text = placed > 0 ? "已放回 \(placed) 项" : ""
                if !others.isEmpty { text += (text.isEmpty ? "" : "；") + others.joined(separator: "；") }
                self.toast = Toast(text: text, canUndo: false)
                self.report = nil
                self.scan()
            }
        }
    }

    nonisolated static func summary(_ b: Batch) -> String {
        var parts: [String] = []
        if b.trashedBytes > 0 { parts.append("移到废纸篓 \(formatBytes(b.trashedBytes))（清空后才释放）") }
        if b.freedBytes > 0 { parts.append("已释放 \(formatBytes(b.freedBytes))") }
        let skipped = b.items.filter { $0.outcome != .done }.count
        if skipped > 0 { parts.append("\(skipped) 项没清（正在使用、已经不在或没装对应工具）") }
        return parts.isEmpty ? "没有清理任何东西" : parts.joined(separator: "，")
    }
}

func total(_ list: [Finding]) -> Int64 { list.reduce(0) { $0 + $1.bytes } }
