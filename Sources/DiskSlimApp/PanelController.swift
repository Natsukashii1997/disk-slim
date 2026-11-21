import AppKit
import DiskSlimCore
import SwiftUI

/// 面板窗口本身：建窗口、摆位置（顶边对齐挂件或球）、内容变高时收回屏内、点外面收起。
/// 开在谁旁边、开关时首页和球怎么变、状态文件怎么写，由 `FloatingBall` 决定（第三批从它里面拆出来）。
@MainActor
final class PanelController {
    private var panel: FloatingPanel?
    private var host: NSHostingController<AnyView>?
    private var sizeObservation: NSKeyValueObservation?
    private var resizeObserver: Any?
    private var clickMonitors: [Any] = []

    /// 面板要对齐的框（挂件或球，AppKit 屏幕坐标）；nil 时不摆
    private let target: () -> CGRect?
    /// 框所在的屏找不到时用哪块
    private let fallbackScreen: () -> NSScreen?
    /// 点在这个窗口上不算「外面」（球）
    private let companion: () -> NSWindow?
    /// 点了面板和球以外的地方
    private let onOutsideClick: () -> Void
    /// 按了 Esc
    private let onCancel: () -> Void

    init(target: @escaping () -> CGRect?, fallbackScreen: @escaping () -> NSScreen?, companion: @escaping () -> NSWindow?,
         onOutsideClick: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.target = target
        self.fallbackScreen = fallbackScreen
        self.companion = companion
        self.onOutsideClick = onOutsideClick
        self.onCancel = onCancel
    }

    var isOpen: Bool { panel?.isVisible == true }

    /// 第一次打开时才建窗口
    func makeIfNeeded(_ store: Store) {
        if panel == nil { make(store) }
    }

    func orderFront() { panel?.makeKeyAndOrderFront(nil) }

    func orderOut() { panel?.orderOut(nil) }

    private func make(_ store: Store) {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // 只有浅色一种外观（2026-11-18 常浩定）：系统切深色也不跟
        p.appearance = NSAppearance(named: .aqua)
        p.onCancel = { [weak self] in self?.onCancel() }
        // 半透明底、圆角（和系统弹出面板一样）
        let fx = NSVisualEffectView(frame: p.contentLayoutRect)
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        let hc = NSHostingController(rootView: AnyView(PanelView().environmentObject(store)))
        hc.sizingOptions = [.preferredContentSize]
        hc.view.frame = fx.bounds
        hc.view.autoresizingMask = [.width, .height]
        fx.addSubview(hc.view)
        p.contentView = fx
        // 换页、展开分组时面板高度跟着内容变；顶边保持和球对齐
        sizeObservation = hc.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.isOpen == true { self?.place() } } }
        }
        // 上面那条有时不来：窗口被 SwiftUI 内容直接撑高，顶边不动往下长，底边会出屏幕
        // （2026-11-18 真屏：挂件在右上时切到内存页，691→754 点，页脚「强制退出…」被切掉一半）。尺寸一变就按同样规则把位置收回屏内
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen == true { self?.keepInside() } }
        }
        panel = p
        host = hc
    }

    func place() {
        guard let p = panel, let hc = host, let target = target(), let screen = screen(containing: target) else { return }
        var size = hc.preferredContentSize
        if size.height < 50 { size = hc.view.fittingSize }
        let frame = FloatGeometry.panel(size: CGSize(width: panelWidth, height: max(size.height, 120)),
                                        ball: target, screen: screen.visibleFrame)
        p.setFrame(frame, display: true)
    }

    /// 只挪位置不改大小：按 place 同样的规则（顶边对齐挂件或球、四周留 12 点）算出该在哪，不在就挪过去
    private func keepInside() {
        guard let p = panel, let target = target(), let screen = screen(containing: target) else { return }
        let want = FloatGeometry.panel(size: p.frame.size, ball: target, screen: screen.visibleFrame).origin
        if want != p.frame.origin { p.setFrameOrigin(want) }
    }

    /// 挂件或球所在的那块屏
    private func screen(containing r: CGRect) -> NSScreen? {
        let c = NSPoint(x: r.midX, y: r.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? fallbackScreen()
    }

    /// 点面板和球以外的地方收起（别的应用里点也算，驿窗挂件也算）
    func installMonitors() {
        removeMonitors()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.onOutsideClick() }
        }) { clickMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window !== self.panel, e.window !== self.companion() { self.onOutsideClick() }
            }
            return e
        }) { clickMonitors.append(l) }
    }

    func removeMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }
}
