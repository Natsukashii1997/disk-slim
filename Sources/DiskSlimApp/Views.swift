import AppKit
import Charts
import DiskSlimCore
import SwiftUI

// 第 2 版「首页 + 下钻」（docs/design/ui-v2.html#v2）。
// 控件都用自绘样式：离屏截图（--snapshot）渲染不了 AppKit 自带的按钮和勾选框。

let panelWidth: CGFloat = 368
let isSnapshot = CommandLine.arguments.contains("--snapshot")

enum Palette {
    static let accent = Color.accentColor
    static let ok = Color(red: 0.12, green: 0.62, blue: 0.33)
    static let warn = Color(red: 0.78, green: 0.49, blue: 0.07)
    static let bad = Color(red: 0.84, green: 0.27, blue: 0.27)
    static let downloads = Color(red: 0.16, green: 0.63, blue: 0.60)
    static let caches = Color(red: 0.54, green: 0.39, blue: 0.82)
    static let projects = Color(red: 0.88, green: 0.47, blue: 0.23)
    static let system = Color(red: 0.60, green: 0.64, blue: 0.70)
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
                case .downloads: ListPage(page: .downloads, title: "下载文件夹", action: "移到废纸篓")
                case .caches: ListPage(page: .caches, title: "缓存与构建产物", action: "清理")
                case .decide: ListPage(page: .decide, title: "要你决定的", action: "处理所选")
                case .records: ListPage(page: .records, title: "对话记录", action: nil)
                case .growth: GrowthPage()
                case .week: WeekPage()
                case .alerts: AlertsPage()
                }
            }
            .disabled(store.confirming != nil)
            .blur(radius: store.confirming != nil ? 2 : 0)

            if let list = store.confirming { ConfirmView(list: list).padding(10) }
            if let t = store.toast, store.confirming == nil { ToastView(toast: t).padding(10) }
        }
        .frame(width: panelWidth)
        .font(.system(size: 13))
    }
}

// MARK: - 首页

struct HomeView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            if !store.unreadable.isEmpty { accessHint }
            growth
            VStack(alignment: .leading, spacing: 2) {
                section("可以清")
                row(.downloads, color: Palette.downloads, title: "下载文件夹", sub: downloadsSub, value: total(store.picked(.downloads)))
                row(.caches, color: Palette.caches, title: "缓存与构建产物", sub: "\(store.picked(.caches).count) 项 · 官方命令清或直接删", value: total(store.picked(.caches)))
                section("要你决定").padding(.top, 6)
                row(.decide, color: Palette.projects, title: "备份、虚拟机、在用的构建产物", sub: "默认不勾，逐项看", value: total(store.findings(.decide)))
                row(.records, color: Palette.system, title: "对话记录", sub: "只展示，不会删", value: total(store.findings(.records)))
                let cards = store.cards
                row(.week, color: Palette.warn, title: "本周待决定",
                    sub: store.report == nil ? "扫描完就有" : cards.isEmpty ? "都处理完了" : "\(cards.count) 件，一件一件点完",
                    value: cards.reduce(0) { $0 + $1.bytes })
            }
            .padding(.horizontal, -6)

            let picks = store.suggestedPicks
            Button(store.working ? "正在清理…" : picks.isEmpty ? "暂时没有建议清理的" : "清理建议项 · \(formatBytes(total(picks)))") { store.askToClean(picks) }
                .buttonStyle(PrimaryButton(enabled: !picks.isEmpty && !store.busy))
                .disabled(picks.isEmpty || store.busy)

            HStack {
                Button("提醒设置") { store.page = .alerts }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                if store.canUndo {
                    Button("撤销上一次清理") { store.undo() }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Palette.accent)
                        .disabled(store.busy)
                        .padding(.leading, 10)
                }
                Spacer()
                Button("退出磁盘瘦身") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var downloadsSub: String {
        let all = store.findings(.downloads).count, picked = store.picked(.downloads).count
        return "建议 \(picked) 项 · 另有 \(all - picked) 项可以看看"
    }

    private var hero: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(store.disk.map { String(format: "%.1f", Double($0.availableBytes) / 1_073_741_824) } ?? "—")
                        .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(freeColor)
                    Text("GB 可用").foregroundStyle(.secondary)
                }
                Text(statusLine).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.scan() } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("重新扫描")
        }
    }

    private var freeColor: Color {
        guard let d = store.disk else { return .primary }
        let gb = Double(d.availableBytes) / 1_073_741_824
        return gb < 30 ? Palette.bad : gb < 60 ? Palette.warn : .primary
    }

    private var statusLine: String {
        if store.scanning { return "正在扫描…" }
        guard let r = store.report else { return "还没扫描" }
        let total = store.disk.map { "共 \(formatBytes($0.totalBytes))" } ?? ""
        return "\(total) · \(BeijingTime.hourMinute(r.scannedAt)) 扫描"
    }

    /// 没有「完全磁盘访问权限」时有些位置量不到：说清影响，一键打开系统设置那一页（授权要用户自己点）
    private var accessHint: some View {
        Button { store.openFullDiskAccessSettings() } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(Palette.warn)
                Text("\(store.unreadable.joined(separator: "、"))读不了，它们的变化会算进「其他」。点这里打开「完全磁盘访问权限」，把磁盘瘦身加进去；列表里已经有的话，先用「−」删掉再加（每次更新后都要）。")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.warn.opacity(0.1)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 最近 7 天可用空间曲线和「比昨天少了 X，主要是 Y」，点进涨幅页；不够两天先说明
    private var growth: some View {
        let days = store.dailySamples
        return Button { store.page = .growth } label: {
            VStack(alignment: .leading, spacing: 6) {
                if days.count >= 2 {
                    FreeChart(days: days, height: 64, showDates: false)
                    if let line = Usage.headline(days, now: Date()) {
                        Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.secondary)
                        Text(GrowthPage.notEnough).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
    }

    private func row(_ page: Page, color: Color, title: String, sub: String, value: Int64) -> some View {
        Button { store.page = page } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(formatBytes(value)).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        else if f.risk == .confirm { tag("需确认", Palette.warn) }
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
            if list.contains(where: { $0.risk == .confirm }) {
                Text("其中有「需确认」的项，请确认你已经看过。").font(.system(size: 11.5)).foregroundStyle(Palette.warn)
            }
            Text("移到废纸篓的要清空废纸篓后才真正腾出空间。").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("取消") { store.confirming = nil }.buttonStyle(QuietButton())
                Button("确认清理") { store.clean(list) }.buttonStyle(PrimaryButton())
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

// MARK: - 本周待决定

/// 一次一件：移到废纸篓（或清理，先经过确认框）/ 保留（以后不再问）/ 下周再问
struct WeekPage: View {
    @EnvironmentObject var store: Store
    private let showFiles = 6

    var body: some View {
        let cards = store.cards
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "本周待决定")
            if let card = cards.first {
                VStack(alignment: .leading, spacing: 10) {
                    Text("还有 \(cards.count) 件").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(card.tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.warn)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Palette.warn.opacity(0.15)))
                        Text(card.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(formatBytes(card.bytes)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            Text("可腾出").foregroundStyle(.secondary)
                        }
                        Text(card.why).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        // 只有一项时标题就是它，不再列一遍
                        if card.findings.count > 1 { VStack(alignment: .leading, spacing: 3) {
                            ForEach(card.findings.prefix(showFiles), id: \.id) { f in
                                HStack {
                                    Text(f.title).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(formatBytes(f.bytes)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                .font(.system(size: 12))
                            }
                            if card.findings.count > showFiles {
                                Text("等 \(card.findings.count) 个").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 2) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

                    HStack(spacing: 8) {
                        Button(card.actionLabel) { store.askToClean(card.findings) }
                            .buttonStyle(PrimaryButton(enabled: !store.busy)).disabled(store.busy)
                        Button("保留") { store.keep(card) }.buttonStyle(QuietButton()).disabled(store.busy)
                        Button("下周再问") { store.snooze(card) }.buttonStyle(QuietButton()).disabled(store.busy)
                    }
                    Text("「保留」以后不再问、也不再默认勾选（涨了超过 1 GB 会再问）；「下周再问」到下周五 18:00 再出现。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                Text(store.scanning || store.report == nil ? "正在扫描…" : "本周都处理完了。下周五 18:00 再来。")
                    .foregroundStyle(.secondary).padding(16)
            }
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

