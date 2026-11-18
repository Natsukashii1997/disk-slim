import AppKit
import DiskSlimCore
import SwiftUI

// 第 11 批：内存页。定稿「一二结合」（2026-11-18 常浩发图，预览 docs/design/ui-v9-memory-polish.html）：
// 顶卡上半照磁盘页的读法（偏紧 / 24 小时曲线 / 压力条 / 交换文件 / 能腾出），下半是占内存最多的五个；
// 白卡和磁盘页一样：替你挑好的 + 一键退出，要你说一句、先不动折起来。

/// 「磁盘 | 内存」切换条
struct PanelTabs: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let t = Tone()
        HStack(spacing: 2) {
            tab("磁盘", .disk, dot: nil)
            tab("内存", .memory, dot: store.memStatus.flatMap { $0.level == .normal ? nil : memoryColor($0.level, t) })
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(t.track))
    }

    private func tab(_ title: String, _ which: PanelTab, dot: Color?) -> some View {
        let on = store.tab == which
        return Button {
            store.tab = which
            if which == .memory { store.refreshMemory() }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            }
            .foregroundStyle(on ? Color.primary : .secondary)
            .frame(maxWidth: .infinity).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Tone().card : .clear)
                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func memoryColor(_ level: MemoryLevel, _ t: Tone) -> Color {
    switch level {
    case .normal: return t.green
    case .tight: return t.orange
    case .critical: return t.red
    }
}

/// 应用图标：直接用系统给的图标（离屏截图也画得出来）
struct AppIcon: View {
    let path: String
    var size: CGFloat = 24

    var body: some View {
        if let cg = Self.bitmap(path) {
            Image(decorative: cg, scale: 2).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [String: CGImage] = [:]

    /// 把系统图标重新画进一张 sRGB 位图（64×64 像素）再用：直接用系统给的图标位图，
    /// 它的色彩空间会让离屏截图整张发灰（2026-11-18 对照实验，L-13）
    @MainActor static func bitmap(_ path: String) -> CGImage? {
        if let hit = cache[path] { return hit }
        let icon = path.isEmpty ? NSWorkspace.shared.icon(for: .application) : NSWorkspace.shared.icon(forFile: path)
        let px = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let image = ctx.makeImage()
        cache[path] = image
        return image
    }
}

/// 没有应用图标的（Claude Code 会话、虚拟机）用一块灰底小图标
struct GlyphIcon: View {
    let symbol: String
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(Color(red: 0.85, green: 0.85, blue: 0.89)))
    }
}

struct MemoryHome: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let t = Tone()
        VStack(spacing: 12) {
            MemoryHero(t: t)
            card(t)
            footer
        }
    }

    // MARK: 白卡

    private func card(_ t: Tone) -> some View {
        let plan = store.memPlan
        let asks = plan?.asks ?? []
        let keep = plan?.keep ?? []
        return VStack(spacing: 0) {
            picked(t, plan).padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
            row(t, .ask, title: "要你说一句", sub: plan == nil ? "正在看…" : asks.isEmpty ? "现在没有要问你的"
                : store.memDrawer == .ask ? "选一个就行" : asks.map(askShort).joined(separator: "、")) {
                if !asks.isEmpty {
                    Text("\(asks.count)").font(.system(size: 11.5, weight: .bold)).foregroundStyle(t.card)
                        .frame(minWidth: 20, minHeight: 20).background(Capsule().fill(Color.primary))
                }
            }
            if store.memDrawer == .ask && !asks.isEmpty { askDrawer(t, asks) }
            row(t, .keep, title: "先不动", sub: plan == nil ? "正在看…" : keep.isEmpty ? "没有" : "\(keep.count) 个在用、要收消息或还在观察") {
                if let plan, !keep.isEmpty { Text(formatBytes(plan.keepBytes)).font(.system(size: 13, weight: .semibold)).monospacedDigit() }
            }
            if store.memDrawer == .keep && !keep.isEmpty { keepDrawer(keep) }
        }
        .background(RoundedRectangle(cornerRadius: 18).fill(t.card))
    }

    @ViewBuilder private func picked(_ t: Tone, _ plan: MemoryPlan?) -> some View {
        let picks = plan?.picked ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("替你挑好的").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if !picks.isEmpty {
                    let (num, unit) = splitBytes(plan?.pickedBytes ?? 0)
                    Text(num).font(.system(size: 26, weight: .bold)).monospacedDigit().tracking(-0.5).foregroundStyle(t.gain)
                    Text(unit).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.gain)
                }
            }
            if picks.isEmpty {
                Text(plan == nil ? "正在看谁闲着…" : "这会儿没有闲着的程序")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(picks, id: \.app.pid) { a in
                        HStack(spacing: 10) {
                            AppIcon(path: a.app.bundlePath)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.app.name).font(.system(size: 12.5))
                                Text(idleText(a.app)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formatBytes(a.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 10).padding(.bottom, 14)
            }
            Button(store.memWorking ? "正在退出…" : "一键退出") { store.quitPicked() }
                .buttonStyle(BigButton(color: t.blue, enabled: !picks.isEmpty && !store.memWorking))
                .disabled(picks.isEmpty || store.memWorking)
            if !picks.isEmpty {
                Text("和按 ⌘Q 一样，没保存的会先问你").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 8)
            }
        }
    }

    private func idleText(_ app: RunningApp) -> String {
        let h = Int(Date().timeIntervalSince(store.memRecord.lastUsed(app)) / 3600)
        return h >= 48 ? "\(h / 24) 天没用" : "\(h) 小时没用"
    }

    private func askShort(_ a: MemoryAsk) -> String {
        switch a {
        case .sessions: return "Claude 会话"
        case .browser(let b): return b.app.name
        case .restart: return "重启"
        }
    }

    private func askDrawer(_ t: Tone, _ asks: [MemoryAsk]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(asks, id: \.id) { ask in
                let (title, why, yes, no) = words(ask)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(why).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button(yes) { store.answer(ask, yes: true) }.buttonStyle(ChipButton(primary: true))
                        Button(no) { store.answer(ask, yes: false) }.buttonStyle(ChipButton())
                    }
                    .disabled(store.memWorking)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func words(_ a: MemoryAsk) -> (String, String, String, String) {
        switch a {
        case .sessions(let keys, let bytes):
            return ("\(keys.count) 个 Claude 会话半天以上没动 · \(formatBytes(bytes))",
                    "收掉后在 Claude 里给它发消息，就会接着聊。", "收掉", "留着")
        case .browser(let b):
            return ("\(b.app.name) · \(formatBytes(b.bytes))", "退出后再打开会恢复标签页，正在填的表单会丢。", "退出 \(b.app.name)", "还在用")
        case .restart(let days, let swap):
            return ("\(days) 天没重启，交换文件占磁盘 \(formatBytes(swap))", "找空档重启一次，能拿回这些磁盘，内存也会松快。", "今晚提醒我", "这周别问")
        }
    }

    private func keepDrawer(_ keep: [MemoryKeepItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(keep.enumerated()), id: \.offset) { _, k in
                HStack(spacing: 10) {
                    if let id = k.bundleID, let a = store.memUsage?.apps.first(where: { $0.app.bundleID == id }) {
                        AppIcon(path: a.app.bundlePath)
                    } else {
                        GlyphIcon(symbol: k.name == "虚拟机" ? "desktopcomputer" : "terminal", size: 24)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(k.name).font(.system(size: 12.5)).lineLimit(1)
                        Text(k.reason.rawValue).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatBytes(k.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Trailing: View>(_ t: Tone, _ which: HomeDrawer, title: String, sub: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        Button { store.memDrawer = store.memDrawer == which ? nil : which } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                trailing()
                Image(systemName: store.memDrawer == which ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 12)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(t.hair).frame(height: 1) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { store.forceArmed = nil; store.page = .forceQuit } label: {
                HStack(spacing: 4) {
                    Text("强制退出…")
                    Text("⌥⌘Esc").foregroundStyle(.tertiary)
                }
            }
            .help("程序卡住时用；也可以按 Option + Command + Esc 打开系统的强制退出窗口")
            Spacer()
            Button("提醒") { store.page = .alerts }
            Button("退出") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

/// 内存顶卡：上半照磁盘页（偏紧 / 24 小时曲线 / 压力条 / 交换文件 / 能腾出），下半是谁占着
struct MemoryHero: View {
    @EnvironmentObject var store: Store
    let t: Tone

    var body: some View {
        let s = store.memStatus
        let color = s.map { memoryColor($0.level, t) } ?? .secondary
        let points = store.memRecord.pressure
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("内存压力")
                Spacer()
                Text("24 小时")
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s?.level.label ?? "—").font(.system(size: 48, weight: .bold)).tracking(-1).foregroundStyle(color)
                if let s { Text("\(Int((Double(s.totalBytes) / 1_073_741_824).rounded())) GB 内存").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .padding(.top, 6)

            if points.count >= 2 {
                Spark(values: points.map { Double($0.usedPercent) }, color: color, fit: true)
                    .frame(height: 40).padding(.top, 12)
            } else {
                Text("曲线要攒几个小时才画得出来").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10)
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.used)
                    Capsule().fill(color).frame(width: g.size.width * CGFloat(s?.usedPercent ?? 0) / 100)
                }
            }
            .frame(height: 8).padding(.top, 16)

            HStack {
                if let s { Text("交换文件 ") + Text(formatBytes(s.swapUsedBytes)).fontWeight(.semibold).foregroundColor(.primary) }
                Spacer()
                if let p = store.memPlan, p.pickedBytes > 0 {
                    Text("能腾出 \(formatBytes(p.pickedBytes))").fontWeight(.semibold).foregroundStyle(t.gain)
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 8)

            if let top = store.memPlan?.top, let first = top.first, first.bytes > 0 {
                Rectangle().fill(t.hair).frame(height: 1).padding(.top, 12)
                VStack(spacing: 9) {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 8) {
                            icon(item)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).font(.system(size: 12)).lineLimit(1)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color(red: 0.24, green: 0.24, blue: 0.35).opacity(0.16))
                                        Capsule().fill(Color(red: 0.49, green: 0.53, blue: 0.72))
                                            .frame(width: g.size.width * CGFloat(Double(item.bytes) / Double(first.bytes)))
                                    }
                                }
                                .frame(height: 4)
                            }
                            Text(formatBytes(item.bytes)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(t.mist))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(t.hair, lineWidth: 1))
    }

    @ViewBuilder private func icon(_ item: MemoryTopItem) -> some View {
        switch item.kind {
        case .app(let id):
            AppIcon(path: store.memUsage?.apps.first { $0.app.bundleID == id }?.app.bundlePath ?? "", size: 20)
        case .sessions: GlyphIcon(symbol: "terminal")
        case .vm: GlyphIcon(symbol: "desktopcomputer")
        }
    }
}

/// 强制退出页：程序卡住时用；和按 ⌥⌘Esc 出来的系统窗口是一回事，多了内存数字
struct ForceQuitPage: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let t = Tone()
        let apps = (store.memUsage?.apps ?? []).filter { MemoryGuard.mayQuit(bundleID: $0.app.bundleID) && $0.app.pid != getpid() }
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: "强制退出")
            Text("程序卡住、点不动时用。「退出」会先问你保存；「强制退出」立刻关掉，没保存的会丢，要点两下。也可以按 Option + Command + Esc 打开系统的同一个窗口。")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element.app.pid) { i, a in
                    HStack(spacing: 10) {
                        AppIcon(path: a.app.bundlePath)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.app.name).font(.system(size: 12.5)).lineLimit(1)
                            Text(formatBytes(a.bytes)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer()
                        Button("退出") { store.quit(a) }.buttonStyle(ChipButton())
                        Button(store.forceArmed == a.key ? "确认强制退出" : "强制退出") { store.forceQuit(a) }
                            .buttonStyle(ChipButton(primary: store.forceArmed == a.key, danger: true))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(t.hair).frame(height: 1) } }
                }
                if apps.isEmpty {
                    Text("正在读…").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
                }
            }
            .disabled(store.memWorking)
            .background(RoundedRectangle(cornerRadius: 14).fill(t.card))
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .onAppear { store.refreshMemory() }
    }
}
