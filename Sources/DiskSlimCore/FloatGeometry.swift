import CoreGraphics

/// 桌面悬浮球贴在哪条边、在这条边上的高度比例（0 = 最下，1 = 最上）。按显示器分别记。
public struct BallPosition: Codable, Equatable, Sendable {
    public enum Edge: String, Codable, Sendable { case left, right }
    public var edge: Edge
    public var fraction: Double

    public init(edge: Edge, fraction: Double) {
        self.edge = edge
        self.fraction = fraction
    }
}

/// 悬浮球和它旁边那个面板的位置计算（屏幕坐标，原点在左下）。
/// 做法照随手记的悬浮球（digiworld/desktop/floating-notes/Geometry.swift）：48 点、离屏幕边 8 点、拖完贴最近的左右边。
public enum FloatGeometry {
    public static let size: CGFloat = 48
    public static let margin: CGFloat = 8
    /// 随手记猫球的默认位置：右边、高度比例 0.55
    public static let notesFraction = 0.55
    /// 默认摆在猫球正下方，中间空 14 点
    public static let gapBelowNotes: CGFloat = 14

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }

    /// 球能上下移动的范围
    static func span(_ screen: CGRect) -> CGFloat { max(1, screen.height - 2 * margin - size) }

    public static func ball(_ p: BallPosition, in screen: CGRect) -> CGRect {
        let x = p.edge == .left ? screen.minX + margin : screen.maxX - margin - size
        let f = CGFloat(min(max(p.fraction, 0), 1))
        let y = screen.minY + margin + max(0, screen.height - 2 * margin - size) * f
        return CGRect(x: clamp(x, screen.minX, screen.maxX - size), y: clamp(y, screen.minY, screen.maxY - size),
                      width: size, height: size)
    }

    /// 拖完松手：按球心贴到更近的左边或右边，高度保持
    public static func position(of frame: CGRect, in screen: CGRect) -> BallPosition {
        BallPosition(edge: frame.midX < screen.midX ? .left : .right,
                     fraction: Double(clamp((frame.minY - screen.minY - margin) / span(screen), 0, 1)))
    }

    /// 第一次出现的位置：右边，紧挨在随手记猫球下方
    public static func defaultPosition(in screen: CGRect) -> BallPosition {
        let notes = ball(BallPosition(edge: .right, fraction: notesFraction), in: screen)
        let y = notes.minY - gapBelowNotes - size
        return BallPosition(edge: .right, fraction: Double(clamp((y - screen.minY - margin) / span(screen), 0, 1)))
    }

    /// 面板开在球朝屏幕里的那一侧，顶边和球顶对齐；放不下就往里收，四周至少留 12 点
    public static func panel(size content: CGSize, ball: CGRect, screen: CGRect) -> CGRect {
        let w = min(content.width, screen.width - 24), h = min(content.height, screen.height - 24)
        let x = ball.midX < screen.midX ? ball.maxX + 8 : ball.minX - 8 - w
        return CGRect(x: clamp(x, screen.minX + 12, screen.maxX - w - 12),
                      y: clamp(ball.maxY - h, screen.minY + 12, screen.maxY - h - 12),
                      width: w, height: h)
    }
}
