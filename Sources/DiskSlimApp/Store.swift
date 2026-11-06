import DiskSlimCore
import Foundation
import ServiceManagement
import SwiftUI

/// 面板里的页面：首页 + 四个下钻页（第 2 版「首页 + 下钻」）。
enum Page: Hashable {
    case home, downloads, caches, decide, records, growth, week, alerts
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
    /// 每次读到可用空间都重写一份状态文件，给驿窗侧栏的挂件号码牌用（第 9 批）
    @Published var disk: DiskStatus? { didSet { writeStatus() } }
    @Published var scanning = false
    @Published var working = false
    @Published var selected: Set<String> = []
    @Published var expanded: Set<String> = []
    @Published var page: Page = .home
    @Published var confirming: [Finding]?
    @Published var toast: Toast?
    /// 每日记录（usage.json），首页曲线和涨幅页用
    @Published var samples: [UsageSample] = []
    /// 卡片上的「保留」「下周再问」（decisions.json）
    @Published var decisions: Decisions
    /// 提醒开关和发过的记录（alerts.json）
    @Published var alertState: AlertState
    /// 系统通知权限：false 时提醒设置页提示去系统设置打开
    @Published var notificationsAllowed: Bool?
    /// 操作记录里还有能放回的：首页常驻「撤销上一次」（不只清完后那 10 秒的提示）
    @Published var canUndo = false
    /// 第 8 批：桌面悬浮球开关，记在 UserDefaults，默认开
    @Published var floatingBallOn = UserDefaults.standard.object(forKey: "floatingBallOn") as? Bool ?? true {
        didSet { if !readOnly { UserDefaults.standard.set(floatingBallOn, forKey: "floatingBallOn") } }
    }
    /// 已经交给系统、还没回音的提醒：防止回音前又发一次
    private var pendingAlerts: Set<String> = []

    let home: URL
    private let usageLog: UsageLog
    private let decisionLog: DecisionLog
    private let alertStore: AlertStore
    /// 离屏截图、示例通知用：只读，不写任何记录，不发通知，不自动清理
    private let readOnly: Bool
    /// 提醒和自动清理只在打包版里跑：调试版发不了通知，也不该把真实的「已发」记录和自动清理用掉
    private var alertsActive: Bool { !readOnly && Notifier.shared.available }
    /// 每次扫描加一；扫描结果回来时代次不对就丢掉（清理后的新扫描要盖过清理前发起的旧扫描）
    private var scanGeneration = 0

    /// 正在扫描或清理时，清理和撤销按钮都不能点
    var busy: Bool { scanning || working }

    /// 应用里那一个（退出时要问它是不是正在清理）
    static weak var main: Store?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, readOnly: Bool = false) {
        self.home = home
        self.readOnly = readOnly
        usageLog = UsageLog.standard(home: home)
        decisionLog = DecisionLog.standard(home: home)
        alertStore = AlertStore.standard(home: home)
        disk = diskStatus(of: home)
        samples = usageLog.load(readOnly: readOnly)
        decisions = decisionLog.load(readOnly: readOnly)
        alertState = alertStore.load(readOnly: readOnly)
        if !readOnly { Store.main = self }
        // 第一次运行：从下一个周五开始发周报，不补发装上之前那个周五的
        if !readOnly, Notifier.shared.available, alertState.sent["weekly"] == nil {
            alertState.sent["weekly"] = BeijingTime.dayKey(Weekly.lastReport(atOrBefore: Date()))
            try? alertStore.save(alertState)
        }
    }

    private var cleaner: Cleaner { Scan(home: home).cleaner() }

    // MARK: 扫描

    func refreshDisk() { disk = diskStatus(of: home) }

    private func writeStatus() {
        guard !readOnly, let disk else { return }
        try? StatusFile(disk: disk, now: Date()).write(to: StatusFile.url(home: home))
    }

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
                self.recordUsage(r)
                self.checkAlerts()
                self.autoCleanIfDue()
            }
        }
    }

    /// 只在真实扫描完成后记（不放进 apply：离屏截图也会调 apply）
    private func recordUsage(_ r: ScanReport) {
        guard !readOnly, let s = Usage.sample(from: r), let all = try? usageLog.record(s) else { return }
        samples = all
    }

    /// 应用开着时每 30 分钟看一次：今天（北京时间）还没有记录、或者周报 / 自动清理到点了而扫描结果超过一小时，
    /// 就在后台扫描一次（扫描完成会写记录、查提醒、按需自动清理）；否则直接查提醒
    /// 第 7 批：每 5 分钟读一次可用空间（很便宜）；比上次扫描时掉了 8 GB 以上就马上扫描，否则每 30 分钟按原来的规则看一次
    func dailyLoop() async {
        guard !readOnly else { return }
        var tick = 0
        while !Task.isCancelled {
            refreshDisk()
            let now = Date()
            if Alerts.shouldRescanForDrop(free: disk?.availableBytes, freeAtScan: report?.disk?.availableBytes,
                                          scannedAt: report?.scannedAt, now: now) {
                scan()
            } else if tick % 6 == 0 {
                if needsScan(now: now) { scan() } else { checkAlerts(); autoCleanIfDue() }
            }
            tick += 1
            try? await Task.sleep(nanoseconds: 300_000_000_000)
        }
    }

    private func needsScan(now: Date) -> Bool {
        let today = BeijingTime.dayKey(now)
        if !samples.contains(where: { BeijingTime.dayKey($0.at) == today }) { return true }
        guard let r = report else { return true }
        if now.timeIntervalSince(r.scannedAt) < 3600 { return false }
        // 通知被拒时周报发不出去，也就一直「没发」：不为它反复扫描
        let weeklyPending = alertState.settings.weekly && notificationsAllowed != false
            && alertState.sent["weekly"] != BeijingTime.dayKey(Weekly.lastReport(atOrBefore: now))
        return weeklyPending || Alerts.shouldAutoClean(now: now, free: disk?.availableBytes, state: alertState)
    }

    // MARK: 提醒

    /// 本周还要决定的卡片；没扫描过时为空
    var cards: [WeeklyCard] { report.map { Weekly.cards($0.findings, decisions: decisions, now: Date()) } ?? [] }

    func checkAlerts() {
        guard alertsActive else { return }
        let now = Date()
        let due = Alerts.due(now: now, free: disk?.availableBytes, samples: samples,
                             cards: report == nil ? nil : cards, state: alertState)
        var state = alertState
        // 只有系统确实收下了才记「已发」：权限被拒时不记，打开权限后还能补发
        for a in due where !pendingAlerts.contains(a.key) {
            pendingAlerts.insert(a.key)
            Notifier.shared.send(title: a.title, body: a.body) { ok, _ in
                Task { @MainActor in
                    self.pendingAlerts.remove(a.key)
                    self.notificationsAllowed = ok
                    guard ok else { return }
                    var s = self.alertState
                    s.sent[a.key] = a.day
                    self.saveAlerts(s)
                }
            }
        }
        // 周报到点时没有要决定的：记成这周已处理，免得每小时重扫一次去等卡片。
        // 下载文件夹没读到（比如没授权）时不算，授权后本周还能提醒
        let friday = Weekly.lastReport(atOrBefore: now)
        if state.settings.weekly, let r = report, r.downloadsBytes != nil, cards.isEmpty { state.sent["weekly"] = BeijingTime.dayKey(friday) }
        if state != alertState { saveAlerts(state) }
    }

    // MARK: 开机自启

    /// 只在装进「应用程序」后才能开：从 dist/ 注册的话，搬走或重新打包就失效了
    var installedInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/") && Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier == "local.nat.disk-slim"
    }
    @Published var loginItemOn = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?

    func setLoginItem(_ on: Bool) {
        guard !readOnly, installedInApplications else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "没设置成功：\(error.localizedDescription)"
        }
        refreshLoginItem()
        if on && SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// 用户可能在系统设置里改过：打开提醒设置页时重读
    func refreshLoginItem() {
        let status = SMAppService.mainApp.status
        loginItemOn = status == .enabled
        if status == .requiresApproval { loginItemError = "要在「系统设置 › 通用 › 登录项」里允许磁盘瘦身" }
    }

    // MARK: 授权

    /// 读不全的位置（多半是没给「完全磁盘访问权限」）：首页提示去授权
    var unreadable: [String] { report?.needsAccess ?? [] }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    func refreshNotificationPermission() {
        guard alertsActive else { return }
        Notifier.shared.allowed { ok in Task { @MainActor in self.notificationsAllowed = ok } }
    }

    func setSetting(_ key: WritableKeyPath<AlertSettings, Bool>, _ on: Bool) {
        var state = alertState
        state.settings[keyPath: key] = on
        // 重新打开周报：从下一个周五开始，不补发关着期间的
        if key == \.weekly, on { state.sent["weekly"] = BeijingTime.dayKey(Weekly.lastReport(atOrBefore: Date())) }
        saveAlerts(state)
    }

    private func saveAlerts(_ state: AlertState) {
        alertState = state
        if !readOnly { try? alertStore.save(state) }
    }

    /// 自动清理（默认关）：可用低于 60 GB、今天还没跑过时，只清「看不见的」里安全、默认勾选的项；下载文件夹不动
    func autoCleanIfDue() {
        // 用户正在确认清理、或者刚清完还能撤销时不插队，下一轮再说（这时不记今天已跑）
        guard alertsActive, !busy, confirming == nil, toast?.canUndo != true, let r = report,
              Alerts.shouldAutoClean(now: Date(), free: disk?.availableBytes, state: alertState) else { return }
        var state = alertState
        state.autoCleanAt = Date()
        saveAlerts(state)
        let picks = Alerts.autoCleanPicks(r.findings)
        guard !picks.isEmpty else { return }
        working = true
        let cleaner = cleaner
        Task.detached {
            let batch = cleaner.clean(picks)
            await MainActor.run {
                self.working = false
                // 什么都没清掉（都在用或被跳过）就不打扰
                let gained = batch.freedBytes + batch.trashedBytes
                if gained > 0 {
                    let text = Self.summary(batch)
                    if self.toast == nil { self.toast = Toast(text: "自动清理：" + text, canUndo: false) }
                    Notifier.shared.send(title: "自动清理腾出了 \(formatBytes(gained))", body: text)
                }
                self.report = nil
                self.scan(force: true)
            }
        }
    }

    // MARK: 每周卡片

    func keep(_ card: WeeklyCard) { decide { $0.keep(card, now: Date()) } }
    func snooze(_ card: WeeklyCard) { decide { $0.snooze(card, now: Date()) } }

    private func decide(_ change: (inout Decisions) -> Void) {
        var d = decisions
        change(&d)
        decisions = d
        if !readOnly {
            do { try decisionLog.save(d) } catch {
                toast = Toast(text: "这个决定没保存成功（\(error.localizedDescription)），重启后会忘掉。", canUndo: false)
            }
        }
        // 选了保留的项马上不再默认勾选
        if let r = report {
            let findings = applyDecisions(r.findings, d)
            report = ScanReport(scannedAt: r.scannedAt, seconds: r.seconds, disk: r.disk, findings: findings,
                                downloadsBytes: r.downloadsBytes, trashBytes: r.trashBytes, needsAccess: r.needsAccess)
            selected.subtract(findings.filter { d.isKept($0) }.map(\.id))
        }
    }

    func apply(_ r: ScanReport) {
        // 扫描时从磁盘读决定；万一上次保存失败，这里再用内存里的套一次，选过保留的不会又被勾上
        let r = ScanReport(scannedAt: r.scannedAt, seconds: r.seconds, disk: r.disk, findings: applyDecisions(r.findings, decisions),
                           downloadsBytes: r.downloadsBytes, trashBytes: r.trashBytes, needsAccess: r.needsAccess)
        report = r
        disk = r.disk
        if !readOnly { canUndo = cleaner.canUndo() }
        // 确认框里还是旧扫描的清单：收起来，按新结果重新确认
        if confirming != nil {
            confirming = nil
            toast = Toast(text: "扫描结果更新了，请重新选择后再确认清理。", canUndo: false)
        }
        selected = Set(r.findings.filter(\.suggested).map(\.id))
        scanning = false
    }

    // MARK: 查询

    /// 最近 7 天每天最后一份记录
    var dailySamples: [UsageSample] { Usage.daily(samples, now: Date()) }

    /// 涨幅排行里某个位置对应哪个下钻页：只认里面有能勾选清理的项的那一页（「其他」、废纸篓、只展示的、已经扫不到的都没有）
    func pageFor(part name: String) -> Page? {
        if name == Usage.downloads { return .downloads }
        return report?.findings.first { $0.area == .hidden && $0.selectable && Usage.partName($0) == name }?.page
    }

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
        guard !busy else {
            toast = Toast(text: "正在扫描或清理，没有执行。等它结束再点一次。", canUndo: false)
            return
        }
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
