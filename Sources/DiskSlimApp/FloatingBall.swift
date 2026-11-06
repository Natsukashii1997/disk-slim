import AppKit
import Combine
import DiskSlimCore
import SwiftUI

/// 第 8 批：桌面悬浮球。贴在屏幕左右边上，点一下在旁边打开和菜单栏同一个面板（同一个 Store）。
/// 做法照随手记的悬浮球（digiworld/desktop/floating-notes）：无边框浮动小窗、拖完贴边、按显示器记位置。
@MainActor
final class FloatingBall: NSObject {
    static let shared = FloatingBall()

    private var store: Store?
    private var ballWindow: BallWindow?
    private var ballView: BallView?
    private var panel: FloatingPanel?
    private var host: NSHostingController<AnyView>?
    private var bag: Set<AnyCancellable> = []
    private var clickMonitors: [Any] = []
    private var screenObserver: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var saved = Saved.load()

    var panelOpen: Bool { panel?.isVisible == true }

    /// 应用启动后调一次（菜单栏图标的 .task 里）。开关和可用空间变了自动跟着变
    func start(store: Store) {
        guard self.store == nil else { return }
        self.store = store
        store.$floatingBallOn.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.setVisible(on) } }
            .store(in: &bag)
        store.$disk.receive(on: DispatchQueue.main)
            .sink { [weak self] d in MainActor.assumeIsolated { self?.ballView?.update(free: d?.availableBytes) } }
            .store(in: &bag)
    }

    // MARK: 显示 / 隐藏

    private func setVisible(_ on: Bool) {
        if on {
            if ballWindow == nil { makeBall() }
            restoreBall()
            ballWindow?.orderFrontRegardless()
        } else {
            closePanel()
            ballWindow?.orderOut(nil)
        }
    }

    private func makeBall() {
        let size = FloatGeometry.size
        let w = BallWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let v = BallView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.owner = self
        v.update(free: store?.disk?.availableBytes)
        w.contentView = v
        ballWindow = w
        ballView = v
        // 插拔显示器、改分辨率：按记下的位置重新摆
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.restoreBall() } }
    }

    // MARK: 位置

    private func screenKey(_ screen: NSScreen) -> String {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(n.uint32Value))?.takeRetainedValue()
        else { return "primary" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 球现在所在的那块屏；显示器重新配置的瞬间 screens 可能是空的，这时返回 nil
    private func currentScreen() -> NSScreen? {
        let c = ballWindow.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func restoreBall() {
        // 记下的那块屏不在了（或从没拖过）：留在球现在所在的屏，不跟着键盘焦点跳到别的屏
        guard let w = ballWindow,
              let screen = NSScreen.screens.first(where: { screenKey($0) == saved.lastDisplay }) ?? currentScreen()
        else { return }
        let pos = saved.positions[screenKey(screen)] ?? FloatGeometry.defaultPosition(in: screen.visibleFrame)
        w.setFrame(FloatGeometry.ball(pos, in: screen.visibleFrame), display: true)
        if panelOpen { placePanel() }
    }

    /// 拖完松手：贴最近的左右边，记到这块显示器上
    fileprivate func snapBall() {
        guard let w = ballWindow, let screen = currentScreen() else { return }
        let pos = FloatGeometry.position(of: w.frame, in: screen.visibleFrame)
        saved.positions[screenKey(screen)] = pos
        saved.lastDisplay = screenKey(screen)
        saved.save()
        w.setFrame(FloatGeometry.ball(pos, in: screen.visibleFrame), display: true)
        if panelOpen { placePanel() }
    }

    // MARK: 面板

    fileprivate func toggle() {
        panelOpen ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let store, ballWindow != nil else { return }
        if panel == nil { makePanel(store) }
        // 和菜单栏面板打开时一样：回首页、收起确认框、结果旧了就重扫
        store.page = .home
        store.confirming = nil
        store.scanIfStale()
        placePanel()
        panel?.makeKeyAndOrderFront(nil)
        ballView?.expanded = true
        installMonitors()
    }

    func closePanel() {
        guard panelOpen else { return }
        panel?.orderOut(nil)
        ballView?.expanded = false
        removeMonitors()
    }

    private func makePanel(_ store: Store) {
        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.onCancel = { [weak self] in self?.closePanel() }
        // 和菜单栏弹出面板一样的半透明底、圆角
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
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.panelOpen == true { self?.placePanel() } } }
        }
        panel = p
        host = hc
    }

    private func placePanel() {
        guard let p = panel, let hc = host, let ball = ballWindow, let screen = currentScreen() else { return }
        var size = hc.preferredContentSize
        if size.height < 50 { size = hc.view.fittingSize }
        let frame = FloatGeometry.panel(size: CGSize(width: panelWidth, height: max(size.height, 120)),
                                        ball: ball.frame, screen: screen.visibleFrame)
        p.setFrame(frame, display: true)
    }

    /// 点面板和球以外的地方收起（别的应用里点也算）
    private func installMonitors() {
        removeMonitors()
        let kinds: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: kinds, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }) { clickMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: kinds, handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window !== self.panel, e.window !== self.ballWindow { self.closePanel() }
            }
            return e
        }) { clickMonitors.append(l) }
    }

    private func removeMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    /// 每块显示器上记的位置（UserDefaults）
    private struct Saved: Codable {
        var positions: [String: BallPosition] = [:]
        var lastDisplay: String?
        static let key = "floatingBallPositions"
        static func load() -> Saved {
            guard let d = UserDefaults.standard.data(forKey: key), let s = try? JSONDecoder().decode(Saved.self, from: d)
            else { return Saved() }
            return s
        }
        func save() {
            if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Saved.key) }
        }
    }
}

/// 球所在的小窗：不抢焦点
final class BallWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 面板所在的窗：能接收键盘（Esc 收起），但不把磁盘瘦身切到前台
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

/// 球本身：画定稿图标；悬停微微上浮，面板开着时外圈一道青光；空间告急时左上角一个橙点 / 红点
final class BallView: NSView {
    weak var owner: FloatingBall?
    var expanded = false { didSet { needsDisplay = true } }
    private var hover = false
    private var dragging = false
    private var level = SpaceLevel.ok

    /// 打包时 scripts/bundle.sh 把 assets/floating-ball.png 复制成 Contents/Resources/ball.png
    static let icon = Bundle.main.image(forResource: "ball")

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("磁盘瘦身悬浮球")
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(free: Int64?) {
        level = SpaceLevel(freeBytes: free)
        let text = free.map { "磁盘瘦身 · 可用 \(formatBytes($0))" } ?? "磁盘瘦身"
        toolTip = text
        setAccessibilityValue(text)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { owner?.toggle() }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clear(bounds)
        if hover && !dragging && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { ctx.translateBy(x: 0, y: 1) }
        ctx.setAlpha(dragging ? 0.85 : (hover || expanded ? 1 : 0.96))
        let disk = bounds.insetBy(dx: 1, dy: 1)
        if let icon = BallView.icon {
            icon.draw(in: disk)
        } else {
            // 缺图时画一个青蓝色圆，不崩
            NSColor(red: 0.16, green: 0.55, blue: 0.70, alpha: 1).setFill()
            NSBezierPath(ovalIn: disk).fill()
        }
        if expanded {
            NSColor(red: 0.37, green: 0.83, blue: 0.93, alpha: 1).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.9, dy: 0.9))
            ring.lineWidth = 1.5
            ring.stroke()
        }
        if level != .ok {
            // 左上角（AppKit 原点在左下）
            let dot = NSRect(x: 1, y: bounds.height - 14, width: 13, height: 13)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: dot).fill()
            (level == .critical ? NSColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
                                : NSColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)).setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 2, dy: 2)).fill()
        }
    }

    /// 按下后挪动超过 4 点算拖动（松手贴边），否则算点击（开关面板）
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = window.convertPoint(toScreen: event.locationInWindow), start = window.frame.origin
        var moved = false
        while let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                         inMode: .eventTracking, dequeue: true) {
            let p = next.window?.convertPoint(toScreen: next.locationInWindow) ?? NSEvent.mouseLocation
            let dx = p.x - origin.x, dy = p.y - origin.y
            if hypot(dx, dy) > 4, !moved { moved = true; dragging = true; needsDisplay = true }
            if moved { window.setFrameOrigin(NSPoint(x: start.x + dx, y: start.y + dy)) }
            if next.type == .leftMouseUp { break }
        }
        dragging = false
        MainActor.assumeIsolated {
            if moved { owner?.snapBall() } else { owner?.toggle() }
        }
        // 贴边时窗口自己挪走了，不一定收到 mouseExited：按鼠标现在的位置重新算悬停
        hover = window.frame.contains(NSEvent.mouseLocation)
        needsDisplay = true
    }
}
