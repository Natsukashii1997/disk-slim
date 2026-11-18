import AppKit
import Charts
import DiskSlimCore
import SwiftUI

// 「首页 + 下钻」；首页 2026-11-18 改成「替你判断」（docs/design/ui-v5-hero-color.html，issue #4）。
// 控件都用自绘样式：离屏截图（--snapshot）渲染不了 AppKit 自带的按钮和勾选框。

let panelWidth: CGFloat = 368
let isSnapshot = CommandLine.arguments.contains("--snapshot")

enum Palette {
    static let accent = Color.accentColor
    static let ok = Color(red: 0.12, green: 0.62, blue: 0.33)
    static let warn = Color(red: 0.78, green: 0.49, blue: 0.07)
    static let bad = Color(red: 0.84, green: 0.27, blue: 0.27)
}

struct PrimaryButton: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 滚动区；离屏截图时换成普通堆叠，否则 ScrollView 渲染出来是空的
struct Scroller<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if isSnapshot {
            VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, 8)
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 0) { content }.padding(.horizontal, 8) }
                .frame(maxHeight: 380)
        }
    }
}

// MARK: - 面板

struct PanelView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch store.page {
                case .home: HomeView()
                case .picked: ListPage(page: .picked, title: "替你挑好的", action: "清理所选")
                case .downloads: ListPage(page: .downloads, title: "下载文件夹", action: "移到废纸篓")
                case .keep: ListPage(page: .keep, title: "先不动的", action: "清理所选")
                case .records: ListPage(page: .records, title: "对话记录", action: nil)
                case .growth: GrowthPage()
                case .alerts: AlertsPage()
                }
            }
            .disabled(store.confirming != nil)
            .blur(radius: store.confirming != nil ? 2 : 0)

            if let list = store.confirming { ConfirmView(list: list).padding(10) }
            if let t = store.toast, store.confirming == nil { ToastView(toast: t).padding(10) }
        }
        .overlay {
            if let c = store.celebration { ConfettiView(celebration: c).allowsHitTesting(false) }
        }
        .frame(width: panelWidth)
        .font(.system(size: 13))
        .background(Tone().panel)
        // 只有浅色一种外观（2026-11-18 常浩定）：系统切深色也不跟
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
    }
}

// MARK: - 首页（2026-11-18 改版「替你判断」：雾光顶卡 + 白卡三段，预览 docs/design/ui-v5-hero-color.html，issue #4）

/// 首页的颜色。只有浅色一种外观（2026-11-18 常浩定，删掉了深色）
struct Tone {
    private func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    var panel: Color { hex(0xECECF0) }
    var card: Color { hex(0xFFFFFF) }
    var red: Color { hex(0xFF3B30) }
    var orange: Color { hex(0xFF9500) }
    var green: Color { hex(0x34C759) }
    var blue: Color { hex(0x0071E3) }
    var used: Color { hex(0xC9CBE0) }
    var track: Color { .black.opacity(0.06) }
    var hair: Color { .black.opacity(0.08) }
    /// 顶卡底色「雾光」：很淡的紫、蓝、青，就是「能拿回」那串字的颜色调淡
    var mist: LinearGradient {
        LinearGradient(colors: [hex(0xF1ECFF), hex(0xE8EFFE), hex(0xE3F5F2)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// 「能拿回」的渐变字和色条
    var gain: LinearGradient {
        LinearGradient(colors: [hex(0x9B5CF6), hex(0x5B6CF9), hex(0x2F8FE6), hex(0x22B3A6)], startPoint: .leading, endPoint: .trailing)
    }

    /// 可用空间的颜色，和菜单栏图标同一套：低于 30 GB 红，低于 60 GB 橙，60 GB 以上绿
    func level(_ gb: Double) -> Color { gb < 30 ? red : gb < 60 ? orange : green }
}

/// 首页大按钮：蓝底白字，圆角 12
struct BigButton: ButtonStyle {
    let color: Color
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
    }
}

/// 「要你说一句」里的小按钮：第一个实心，其余描边
struct ChipButton: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        let t = Tone()
        configuration.label
            .font(.system(size: 12, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? t.card : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(primary ? Color.primary : .clear))
            .overlay(Capsule().stroke(primary ? .clear : t.hair))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .fixedSize()
    }
}

/// 「51.8 GB」拆成数字和单位，数字大、单位小
func splitBytes(_ bytes: Int64) -> (String, String) {
    let s = formatBytes(bytes)
    guard let space = s.lastIndex(of: " ") else { return (s, "") }
    return (String(s[..<space]), String(s[s.index(after: space)...]))
}

/// 首页列表里给人看的名字：worktree 编译文件写成「AI 编译文件 · 项目」
func friendlyName(_ f: Finding) -> String {
    if f.category.contains("构建产物") {
        let project = f.title.range(of: " · ", options: .backwards).map { String(f.title[..<$0.lowerBound]) } ?? f.title
        return "AI 编译文件 · \(project)"
    }
    // 备份文件夹名很长，日期已经写在说明里
    if f.title.hasPrefix("Codex 备份 · ") { return "Codex 备份" }
    return f.title
}

/// 「替你挑好的」按用途合并成几行
func pickedLabel(_ f: Finding) -> String {
    if f.area == .downloads {
        switch f.category {
        case "安装包": return "下载里装好的安装包"
        case "已解压的压缩包": return "下载里解压过的压缩包"
        default: return "下载里的\(f.category)"
        }
    }
    if f.category.contains("构建产物") { return "AI 写代码编出来的文件" }
    if f.category == "备份快照" { return "Codex 旧备份" }
    if f.category == "包管理器缓存" { return "下载缓存" }
    return f.category
}

/// 记下放某个视图的窗口：缩小键要知道自己在悬浮面板里还是菜单栏弹出的窗口里
final class WindowBox { weak var window: NSWindow? }

struct WindowReader: NSViewRepresentable {
    let box: WindowBox
    func makeNSView(context: Context) -> NSView { Reader(box: box) }
    func updateNSView(_ v: NSView, context: Context) {
        guard let r = v as? Reader else { return }
        r.box = box
        box.window = r.window
    }
    private final class Reader: NSView {
        var box: WindowBox
        init(box: WindowBox) { self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { if let window { box.window = window } }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: Store
    /// 缩小键用：放首页的窗口（不用 @State：本机只有命令行工具，State 宏插件用不了；WindowReader 每次更新把窗口补进新盒子）
    private let host = WindowBox()
    /// 菜单栏弹出的面板靠它收起
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let t = Tone()
        VStack(spacing: 12) {
            meta
            if !store.unreadable.isEmpty { accessHint(t) }
            HeroCard(t: t)
            decideCard(t)
            footer
        }
        .padding(14)
    }

    private var meta: some View {
        HStack {
            Text(statusLine)
            Spacer()
            Button { store.scan() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("重新扫描")
            // 缩小键（2026-11-18 常浩选甲「同款线条」，预览 docs/design/ui-v7-minimize.html）：收回挂件、悬浮球或菜单栏图标
            Button { FloatingBall.shared.collapse(host.window) { dismiss() } } label: {
                // 横线只有一两个像素高：给一块 18×18 的点击区，不然差一个像素就点不中
                Image(systemName: "minus").frame(width: 18, height: 18).contentShape(Rectangle())
            }
                .buttonStyle(.plain).help("缩小")
                .background(WindowReader(box: host))
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private var statusLine: String {
        if store.scanning { return "正在扫描…" }
        let total = store.disk.map { "共 \(formatBytes($0.totalBytes))" } ?? ""
        guard let r = store.report else { return total.isEmpty ? "还没扫描" : "\(total) · 还没扫描" }
        return "\(total) · \(BeijingTime.hourMinute(r.scannedAt)) 扫描"
    }

    /// 没有「完全磁盘访问权限」时有些位置量不到：说清影响，一键打开系统设置那一页（授权要用户自己点）
    private func accessHint(_ t: Tone) -> some View {
        Button { store.openFullDiskAccessSettings() } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(t.orange)
                Text("\(store.unreadable.joined(separator: "、"))读不了，它们的变化会算进「其他」。点这里打开「完全磁盘访问权限」，把磁盘瘦身加进去；列表里已经有的话，先用「−」删掉再加（每次更新后都要）。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 白卡：替你挑好的 / 要你说一句 / 先不动

    private func decideCard(_ t: Tone) -> some View {
        VStack(spacing: 0) {
            picked(t).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
            let askCount = store.askCards.count + store.askInfo.count
            // 还没有扫描结果（刚清理完正在重扫）时不说「没有」「0 KB」，免得像真的清空了
            let scanned = store.report != nil
            drawerRow(t, .ask, title: "要你说一句",
                      sub: !scanned ? Self.afterScan : askCount == 0 ? "现在没有要问你的" : store.drawer == .ask ? "选一个就行，选错了能撤销" : askSub) {
                if askCount > 0 {
                    Text("\(askCount)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(t.card)
                        .frame(minWidth: 20, minHeight: 20).padding(.horizontal, askCount > 9 ? 4 : 0)
                        .background(Capsule().fill(Color.primary))
                }
            }
            if store.drawer == .ask { askDrawer(t) }
            let keep = store.keepList
            drawerRow(t, .keep, title: "先不动", sub: !scanned ? Self.afterScan : keep.isEmpty ? "没有" : "\(keep.count) 项还在用或留着保底") {
                if scanned { Text(formatBytes(total(keep))).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
            }
            if store.drawer == .keep { keepDrawer(t, keep) }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(t.card))
    }

    static let afterScan = "扫描完就有"

    private var askSub: String {
        (store.askCards.map(\.title) + store.askInfo.map(\.title)).joined(separator: "、")
    }

    @ViewBuilder private func picked(_ t: Tone) -> some View {
        let picks = store.suggestedPicks
        let (num, unit) = splitBytes(total(picks))
        VStack(alignment: .leading, spacing: 0) {
            Button { store.page = .picked } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("替你挑好的").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Spacer()
                    if !picks.isEmpty {
                        Text(num).font(.system(size: 26, weight: .bold)).monospacedDigit().tracking(-0.5).foregroundStyle(t.gain)
                        Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.gain)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if picks.isEmpty {
                Text(store.report == nil ? "扫描完就知道能清多少" : "这会儿没有要清的，挺干净")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(groups(picks), id: \.0) { g in
                        HStack {
                            Text(g.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(formatBytes(g.1)).monospacedDigit()
                        }
                    }
                }
                .font(.system(size: 12))
                .padding(.top, 10).padding(.bottom, 14)
            }

            Button(store.working ? "正在清理…" : "一键清理") { store.askToClean(picks) }
                .buttonStyle(BigButton(color: t.blue, enabled: !picks.isEmpty && !store.busy))
                .disabled(picks.isEmpty || store.busy)

            let trash = total(picks.filter { $0.cleanup == .trash })
            if trash > 0, let disk = store.disk {
                HStack(spacing: 0) {
                    Text("\(formatBytes(trash)) 先进废纸篓，清空后到 \(formatBytes(disk.availableBytes + total(picks))) · ")
                    Button("打开废纸篓") { store.openTrash() }.buttonStyle(.plain).foregroundStyle(t.blue)
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
    }

    /// 按用途合并，大的在前
    private func groups(_ picks: [Finding]) -> [(String, Int64)] {
        var sums: [String: Int64] = [:]
        for f in picks { sums[pickedLabel(f), default: 0] += f.bytes }
        return sums.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    private func drawerRow<Trailing: View>(_ t: Tone, _ which: HomeDrawer, title: String, sub: String,
                                           @ViewBuilder trailing: () -> Trailing) -> some View {
        Button { store.drawer = store.drawer == which ? nil : which } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                trailing()
                Image(systemName: store.drawer == which ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 12)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(t.hair).frame(height: 1) }
    }

    private func askDrawer(_ t: Tone) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.askCards) { card in
                question(title: "\(card.title) · \(formatBytes(card.bytes))", why: card.why) {
                    if card.findings.allSatisfy({ $0.area == .downloads }) {
                        Button("都不要了") { store.askToClean(card.findings) }.buttonStyle(ChipButton(primary: true))
                        Button("让我挑") { store.page = .downloads }.buttonStyle(ChipButton())
                        Button("都留着") { store.keep(card) }.buttonStyle(ChipButton())
                    } else {
                        Button(card.actionLabel) { store.askToClean(card.findings) }.buttonStyle(ChipButton(primary: true))
                        Button("留着") { store.keep(card) }.buttonStyle(ChipButton())
                    }
                    // 第 5 批定的「下周再问」：首页照样列着，只是周五不再催
                    Button("下周再问") { store.snooze(card) }.buttonStyle(ChipButton())
                }
                .disabled(store.busy)
            }
            ForEach(store.askInfo) { f in
                question(title: "\(f.title) · \(formatBytes(f.bytes))", why: f.detail) {
                    Button("还要用，留着") { store.keep(f) }.buttonStyle(ChipButton(primary: true))
                }
            }
            if store.askCards.isEmpty && store.askInfo.isEmpty {
                Text("现在没有要问你的，有新的会在周五通知你。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func question<Buttons: View>(title: String, why: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { buttons() }
        }
    }

    private func keepDrawer(_ t: Tone, _ keep: [Finding]) -> some View {
        let shown = 8
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(keep.prefix(shown)) { f in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(friendlyName(f)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        Text(f.detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Text(formatBytes(f.bytes)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
            }
            Button(keep.count > shown ? "还有 \(keep.count - shown) 项，全部看看 ›" : "想自己挑着清，点这里 ›") { store.page = .keep }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(t.blue)
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            let records = store.findings(.records)
            Button(store.report == nil ? "对话记录 · \(Self.afterScan)" : "对话记录 \(formatBytes(total(records))) · 只看不删") { store.page = .records }
            Spacer()
            Button("提醒") { store.page = .alerts }
            if store.canUndo { Button("撤销") { store.undo() }.disabled(store.busy) }
            Button("退出") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// 顶卡：现在可用多少、这周掉了多少、清完能到多少。点进涨幅页
struct HeroCard: View {
    @EnvironmentObject var store: Store
    let t: Tone

    var body: some View {
        let days = store.dailySamples
        let free = store.disk?.availableBytes ?? 0
        let picks = store.suggestedPicks
        let soon = total(picks.filter { $0.cleanup != .trash })
        Button { store.page = .growth } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("可用空间")
                    Spacer()
                    if let first = days.first, let last = days.last, days.count >= 2 {
                        Text("这周 \(formatDelta(last.freeBytes - first.freeBytes)) ›")
                    } else {
                        Text("涨幅 ›")
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)

                CelebrationClock(celebration: store.celebration, frozenAt: store.celebrationFrozenAt) { elapsed in
                    let gb = shownGB(elapsed)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(gb.map { String(format: "%.1f", $0) } ?? "—")
                            .font(.system(size: 48, weight: .bold)).monospacedDigit().tracking(-1)
                            .foregroundStyle(levelColor(gb))
                        Text("GB").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let c = store.celebration {
                            Text("+\(formatBytes(c.freedBytes))").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(t.gain))
                                .scaleEffect(pillScale(elapsed)).opacity(pillScale(elapsed) > 0 ? 1 : 0)
                        }
                    }
                }
                .padding(.top, 6)

                if days.count >= 2 {
                    Spark(values: days.map { Double($0.freeBytes) / 1_073_741_824 }, color: t.red)
                        .frame(height: 40).padding(.top, 12)
                } else {
                    Text(GrowthPage.notEnough).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                }

                if let disk = store.disk {
                    CapacityBar(total: disk.totalBytes, free: free, gain: total(picks), t: t)
                        .frame(height: 8).padding(.top, 16)
                }

                HStack {
                    if let c = store.celebration, picks.isEmpty {
                        Text("刚腾出 ") + Text(formatBytes(c.freedBytes)).fontWeight(.semibold).foregroundColor(.primary)
                        Spacer()
                        if c.trashedBytes > 0 {
                            Text("废纸篓里还有 \(formatBytes(c.trashedBytes))").fontWeight(.semibold).foregroundStyle(t.gain)
                        }
                    } else if picks.isEmpty {
                        Text("暂时没有能拿回的")
                    } else {
                        Text("清完约 ") + Text(formatBytes(free + soon)).fontWeight(.semibold).foregroundColor(.primary)
                        Spacer()
                        Text("能拿回 \(formatBytes(total(picks)))").fontWeight(.semibold).foregroundStyle(t.gain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18).fill(t.mist))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(t.hair, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 低于 30 GB 红，低于 60 GB 橙，够用时就是正文色
    private func levelColor(_ gb: Double?) -> Color {
        guard let gb, gb < 60 else { return .primary }
        return t.level(gb)
    }

    /// 刚清理完的头 1.4 秒，数字从清理前滚到清理后（先快后慢）；其余时候就是现在的可用空间
    private func shownGB(_ elapsed: TimeInterval?) -> Double? {
        let gb = { (b: Int64) in Double(b) / 1_073_741_824 }
        if let c = store.celebration, let elapsed, elapsed < Celebration.countUp {
            let k = max(0, elapsed) / Celebration.countUp
            return gb(c.fromBytes) + (gb(c.toBytes) - gb(c.fromBytes)) * (1 - pow(1 - k, 3))
        }
        return store.disk.map { gb($0.availableBytes) }
    }

    /// 「+X GB」先弹大一点再落定
    private func pillScale(_ elapsed: TimeInterval?) -> Double {
        guard let e = elapsed else { return 1 }
        let k = min(1, max(0, (e - 0.25) / 0.35))
        return k <= 0 ? 0 : k < 1 ? 0.9 + 0.2 * sin(k * .pi) + 0.1 * k : 1
    }
}

/// 彩带和数字滚动的时钟：放的时候按真实时间每帧刷新，其余时候不刷；离屏截图时定格在给定的秒数
struct CelebrationClock<Content: View>: View {
    let celebration: Celebration?
    let frozenAt: TimeInterval?
    @ViewBuilder let content: (TimeInterval?) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let c = celebration, !reduceMotion {
            if let frozenAt {
                content(frozenAt)
            } else {
                TimelineView(.animation(paused: Date().timeIntervalSince(c.at) > Celebration.duration)) { tl in
                    content(tl.date.timeIntervalSince(c.at))
                }
            }
        } else {
            content(nil)
        }
    }
}

/// 彩带雨：从面板顶上飘落，边转边摆，落到底部淡出；颜色是「能拿回」那组紫、蓝、青再加一点暖金。
/// 每片的位置、速度、颜色由序号算出来，同一时刻画出来都一样（离屏截图能定格）
struct ConfettiView: View {
    let celebration: Celebration
    @EnvironmentObject var store: Store

    var body: some View {
        CelebrationClock(celebration: celebration, frozenAt: store.celebrationFrozenAt) { elapsed in
            if let t = elapsed, t < Celebration.duration {
                Canvas { ctx, size in Self.draw(&ctx, size: size, t: t) }
            }
        }
    }

    static let colors: [Color] = [0x9B5CF6, 0x5B6CF9, 0x2F8FE6, 0x22B3A6, 0xFFB21E].map {
        Color(red: Double(($0 >> 16) & 0xff) / 255, green: Double(($0 >> 8) & 0xff) / 255, blue: Double($0 & 0xff) / 255)
    }
    static let count = 90

    /// 0～1 之间的伪随机数：同一片、同一用途永远一样
    static func rand(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311) * 12.9898) * 43758.5453
        return x - x.rounded(.down)
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        for i in 0..<count {
            let start = -20 - rand(i, 1) * 160                // 从面板上沿外面开始，错开落下
            let vy = 100 + rand(i, 2) * 110                   // 每秒落多少点
            let y = start + vy * t
            if y < -20 || y > size.height + 20 { continue }
            let phase = rand(i, 3) * 6.28
            let x = rand(i, 4) * size.width + (rand(i, 5) - 0.5) * 70 * t + sin(t * 4.2 + phase) * 10
            // 快放完时、或落到底部时淡出
            let fadeEnd = min(1, max(0, (Celebration.duration - t) / 0.6))
            let fadeBottom = min(1, max(0, (size.height - 10 - y) / 40))
            let alpha = min(fadeEnd, fadeBottom)
            if alpha <= 0 { continue }
            let w = 5 + rand(i, 6) * 4, h = 8 + rand(i, 7) * 6
            var c = ctx
            c.opacity = alpha
            c.translateBy(x: x, y: y)
            c.rotate(by: .radians(rand(i, 8) * 6.28 + (rand(i, 9) - 0.5) * 9 * t))
            c.scaleBy(x: 1, y: max(0.15, abs(cos(t * 5.5 + phase))))
            c.fill(Path(roundedRect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), cornerRadius: 1.2),
                   with: .color(colors[i % colors.count]))
        }
    }
}

/// 7 天可用空间的小曲线：一条线、一层渐隐的面、末端一个点
struct Spark: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let top = max(60, (values.max() ?? 0) * 1.1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count > 1 ? g.size.width * CGFloat(i) / CGFloat(values.count - 1) : 0,
                        y: 3 + (g.size.height - 6) * (1 - CGFloat(min(v, top) / top)))
            }
            let line = Path { p in p.addLines(pts) }
            ZStack {
                Path { p in
                    p.addLines(pts)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.24), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                line.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(color).frame(width: 6, height: 6).position(last)
                }
            }
        }
    }
}

/// 一条色带：已经用掉的 / 能拿回的（渐变）/ 现在可用的（和可用空间同色：红 / 橙 / 绿）
struct CapacityBar: View {
    let total: Int64
    let free: Int64
    let gain: Int64
    let t: Tone

    var body: some View {
        GeometryReader { g in
            let all = Double(max(total, 1))
            let gap: CGFloat = 2
            let w = g.size.width - gap * 2
            let gainW = max(gain > 0 ? 3 : 0, w * CGFloat(Double(gain) / all))
            let freeW = max(3, w * CGFloat(Double(free) / all))
            HStack(spacing: gap) {
                Rectangle().fill(t.used)
                if gain > 0 { Rectangle().fill(t.gain).frame(width: gainW) }
                Rectangle().fill(t.level(Double(free) / 1_073_741_824)).frame(width: freeW)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - 下钻页

struct PageHeader: View {
    @EnvironmentObject var store: Store
    let title: String

    var body: some View {
        HStack {
            Button { store.page = .home } label: { Label("返回", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Palette.accent)
            Spacer()
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
    }
}

struct ListPage: View {
    @EnvironmentObject var store: Store
    let page: Page
    let title: String
    /// nil 表示这一页只展示，没有清理按钮
    let action: String?

    /// 一组超过这么多项时默认折叠，只露最大的几项
    private let foldOver = 8
    private let foldShow = 6

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: title)

            let items = store.findings(page)
            Scroller {
                if items.isEmpty {
                    Text(store.scanning ? "正在扫描…" : "这里没有东西").foregroundStyle(.secondary).padding(16)
                }
                ForEach(groups(items), id: \.name) { g in group(g) }
                if page == .records {
                    Text("要清 Codex 对话请在 Codex 里操作；Claude 对话在 Claude 设置 › 存储里看。")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(8)
                }
            }

            if let action {
                let picks = store.picked(page)
                HStack(spacing: 10) {
                    Text("已选 \(picks.count) 项 · \(formatBytes(total(picks)))").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action) { store.askToClean(picks) }
                        .buttonStyle(PrimaryButton(enabled: !picks.isEmpty && !store.busy))
                        .disabled(picks.isEmpty || store.busy)
                        .fixedSize()
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    private struct Group: Hashable { let name: String; let items: [Finding]
        static func == (a: Group, b: Group) -> Bool { a.name == b.name }
        func hash(into h: inout Hasher) { h.combine(name) }
    }

    private func groups(_ items: [Finding]) -> [Group] {
        var order: [String] = []
        for f in items where !order.contains(f.category) { order.append(f.category) }
        let groups = order.map { name in Group(name: name, items: items.filter { $0.category == name }.sorted { $0.bytes > $1.bytes }) }
        // 有建议勾选的组在前，其次是能勾的，最后是不能清的；同档保持扫描顺序
        func rank(_ g: Group) -> Int {
            g.items.contains(where: \.suggested) ? 0 : g.items.contains(where: \.selectable) ? 1 : 2
        }
        return groups.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    @ViewBuilder private func group(_ g: Group) -> some View {
        let folded = g.items.count > foldOver && !store.expanded.contains(g.name)
        let shown = folded ? Array(g.items.prefix(foldShow)) : g.items
        HStack {
            Text(g.name).font(.system(size: 11.5, weight: .semibold))
            Text("\(g.items.count) 项").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Spacer()
            Text(formatBytes(total(g.items))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
        ForEach(shown) { f in ItemRow(f: f) }
        if g.items.count > foldOver {
            Button {
                if folded { store.expanded.insert(g.name) } else { store.expanded.remove(g.name) }
            } label: {
                let rest = g.items.dropFirst(foldShow)
                Text(folded ? "还有 \(rest.count) 项 · \(formatBytes(total(Array(rest))))，展开" : "收起")
                    .font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 34).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var store: Store
    let f: Finding

    var body: some View {
        HStack(spacing: 0) {
            row
            // 替你挑好的项可以「留着」：记成保留，以后不再默认勾选，归到「先不动」（涨了超过 1 GB 再问）
            if store.bucket(f) == .picked {
                Button("留着") { store.keep(f) }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                    .padding(.trailing, 8).disabled(store.busy)
            }
        }
    }

    private var row: some View {
        Button { store.toggle(f) } label: {
            HStack(spacing: 8) {
                Group {
                    if f.selectable {
                        Image(systemName: store.selected.contains(f.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(store.selected.contains(f.id) ? Palette.accent : .secondary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(f.title).lineLimit(1).truncationMode(.middle)
                        chip
                    }
                    Text(f.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                Text(formatBytes(f.bytes)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.paths.joined(separator: "\n"))
    }

    @ViewBuilder private var chip: some View {
        if f.risk == .readOnly { tag("只展示", .secondary) }
        else if f.cleanup == .none { tag(f.area == .downloads ? "只提示" : "不能清", .secondary) }
        // 替你挑好的已经替用户判断过，不再挂「需确认」
        else if f.risk == .confirm && store.bucket(f) != .picked { tag("需确认", Palette.warn) }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .fixedSize()
    }
}

// MARK: - 清理前确认、清理后提示

struct ConfirmView: View {
    @EnvironmentObject var store: Store
    let list: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("确认清理 \(list.count) 项").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                line("移到废纸篓，可以撤销", list.filter { $0.cleanup == .trash })
                line("直接删除可再生的目录，不能撤销", list.filter { $0.cleanup == .remove })
                line("运行官方清理命令，不能撤销", list.filter { if case .command = $0.cleanup { return true }; return false })
            }
            // 替你挑好的已经替用户判断过；自己从「先不动」里挑的需确认项才提醒
            if list.contains(where: { $0.risk == .confirm && store.bucket($0) != .picked }) {
                Text("其中有「需确认」的项，请确认你已经看过。").font(.system(size: 11.5)).foregroundStyle(Palette.warn)
            }
            Text("移到废纸篓的要清空废纸篓后才真正腾出空间。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("取消") { store.confirming = nil }.buttonStyle(QuietButton())
                Button(store.busy ? "正在扫描…" : "确认清理") { store.clean(list) }
                    .buttonStyle(PrimaryButton(enabled: !store.busy)).disabled(store.busy)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background).shadow(color: .black.opacity(0.25), radius: 14, y: 6))
    }

    @ViewBuilder private func line(_ text: String, _ group: [Finding]) -> some View {
        if !group.isEmpty {
            HStack {
                Text(text)
                Spacer()
                Text("\(group.count) 项 · \(formatBytes(total(group)))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var store: Store
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Text(toast.text).font(.system(size: 12)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if toast.canUndo {
                Button("撤销") { store.undo() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.56, green: 0.75, blue: 1))
                    .disabled(store.working)
            }
            Button { store.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13)))
        .task(id: toast.id) {
            if isSnapshot { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if store.toast?.id == toast.id { store.toast = nil }
        }
    }
}

// MARK: - 涨幅

/// 每天一个点的可用空间折线（GB）。横轴按相隔天数排，中间缺的天会空出来
struct FreeChart: View {
    let days: [UsageSample]
    let height: CGFloat
    let showDates: Bool

    private var start: Int { days.first.map { BeijingTime.dayNumber($0.at) } ?? 0 }
    private func x(_ s: UsageSample) -> Double { Double(BeijingTime.dayNumber(s.at) - start) }

    var body: some View {
        Chart(days, id: \.at) { s in
            let gb = Double(s.freeBytes) / 1_073_741_824
            LineMark(x: .value("第几天", x(s)), y: .value("可用 GB", gb))
                .foregroundStyle(Palette.accent)
            PointMark(x: .value("第几天", x(s)), y: .value("可用 GB", gb))
                .foregroundStyle(gb < 30 ? Palette.bad : gb < 60 ? Palette.warn : Palette.accent)
                .symbolSize(showDates ? 28 : 16)
        }
        // 两头各留小半天，第一天和最后一天的点和日期不会被裁掉
        .chartXScale(domain: -0.4...(max(1, days.last.map(x) ?? 1) + 0.4))
        .chartXAxis {
            if showDates {
                AxisMarks(values: days.map(x)) { v in
                    AxisGridLine()
                    AxisValueLabel(anchor: .top) {
                        if let i = v.as(Double.self), let s = days.first(where: { x($0) == i }) { Text(BeijingTime.shortDay(s.at)) }
                    }
                }
            }
        }
        .chartYAxis {
            // 首页是小图，只留网格线；涨幅页的大图带刻度
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine()
                if showDates { AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g))G") } } }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: height)
    }
}

struct GrowthPage: View {
    @EnvironmentObject var store: Store
    static let notEnough = "从今天开始每天记一次可用空间和各目录大小，攒够两天就能看到谁在涨。"

    var body: some View {
        let days = store.dailySamples
        VStack(spacing: 0) {
            PageHeader(title: "涨幅")
            Scroller {
                if days.count < 2 {
                    Text(Self.notEnough + "（已有 \(days.count) 天）")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(8)
                } else {
                    Text("最近 7 天可用空间").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 6)
                    FreeChart(days: days, height: 120, showDates: true).padding(6)
                    if let (new, old) = Usage.latestAndPrevious(days) {
                        section("谁涨了多少（\(BeijingTime.shortDay(old.at)) → \(BeijingTime.shortDay(new.at))）", Usage.headline(days, now: Date()))
                        changes(Usage.changes(from: old, to: new))
                    }
                    if let first = days.first, let last = days.last, days.count > 2 {
                        section("近 7 天合计（\(BeijingTime.shortDay(first.at)) → \(BeijingTime.shortDay(last.at))）",
                                Usage.freeChange(from: first, to: last))
                        changes(Usage.changes(from: first, to: last))
                    }
                    Text("扫描完成就记一次，同一天只留最后一份；变化不到 50 MB 的不列。移到废纸篓的东西清空前仍占空间；读不了的位置（比如没有权限）当天不单列，变化算进「其他」。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).padding(8)
                }
            }
        }
    }

    private func section(_ title: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if let sub { Text(sub).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder private func changes(_ list: [UsageChange]) -> some View {
        if list.isEmpty {
            Text("没有超过 50 MB 的变化").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(6)
        }
        let biggest = list.map(\.delta.magnitude).max() ?? 1
        ForEach(list, id: \.name) { c in
            let target = store.pageFor(part: c.name)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.name).lineLimit(1).truncationMode(.middle)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(c.delta > 0 ? Palette.bad.opacity(0.7) : Palette.ok.opacity(0.7))
                            .frame(width: max(3, g.size.width * CGFloat(c.delta.magnitude) / CGFloat(max(1, biggest))))
                    }
                    .frame(height: 4)
                }
                Spacer(minLength: 6)
                Text(formatDelta(c.delta)).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(c.delta > 0 ? Palette.bad : Palette.ok)
                if let target {
                    Button("去处理") { store.page = target }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }
}

// MARK: - 提醒设置

struct AlertsPage: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = store.alertState.settings
        let free = store.disk.map { "现在 \(formatBytes($0.availableBytes))" } ?? ""
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "提醒设置")
            if store.notificationsAllowed == false {
                Text("系统没允许磁盘瘦身发通知，下面的提醒收不到。到「系统设置 › 通知 › DiskSlim」里打开「允许通知」。")
                    .font(.system(size: 11.5)).foregroundStyle(Palette.bad).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                info("可用低于 60 GB 图标变橙、低于 30 GB 变红", free)
                toggle(\.lowSpace, s.lowSpace, "可用低于 30 GB 时发通知", "一天最多一次")
                toggle(\.growth, s.growth, "某个位置一天涨超过 10 GB 时发通知", "比如某个项目一天多开了几个 worktree")
                toggle(\.weekly, s.weekly, "每周五 18:00 发周报", "有待决定的事才发；那时没开着应用，之后打开会补发")
                toggle(\.autoClean, s.autoClean, "自动清理缓存和构建产物",
                       "默认关。打开后只在可用低于 60 GB 时、每天最多一次，只清「缓存与构建产物」里默认勾选的项，下载文件夹不动。运行清理命令和直接删除的不能撤销。")
                switchRow(store.floatingBallOn, "显示桌面悬浮球",
                          "贴在屏幕边上，点一下打开这个面板；拖到左边或右边会自动贴边。可用低于 60 GB 时左上角亮橙点，低于 30 GB 亮红点。关掉后从菜单栏图标还能打开") {
                    store.floatingBallOn.toggle()
                }
                switchRow(store.loginItemOn, "开机自动打开",
                          store.loginItemError ?? (store.installedInApplications ? "登录后自动出现在菜单栏" : "装进「应用程序」后才能打开（运行 scripts/install.sh）"),
                          enabled: store.installedInApplications) { store.setLoginItem(!store.loginItemOn) }
            }
            .padding(.horizontal, 10).padding(.bottom, 12)
        }
        .onAppear { store.refreshNotificationPermission(); store.refreshLoginItem() }
    }

    private func info(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 6).padding(.vertical, 8)
    }

    private func toggle(_ key: WritableKeyPath<AlertSettings, Bool>, _ on: Bool, _ title: String, _ sub: String) -> some View {
        switchRow(on, title, sub) { store.setSetting(key, !on) }
    }

    private func switchRow(_ on: Bool, _ title: String, _ sub: String, enabled: Bool = true, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // 自绘开关：离屏截图画不出系统自带的
                Capsule().fill(on ? Palette.ok : Color.secondary.opacity(0.3))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(2).shadow(radius: 0.5) }
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityValue(on ? "开" : "关")
    }
}

