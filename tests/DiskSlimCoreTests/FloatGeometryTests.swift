import CoreGraphics
import Testing
@testable import DiskSlimCore

@Suite struct FloatGeometryTests {
    /// 普通屏、左边的第二块屏、很矮的屏
    let screens = [CGRect(x: 0, y: 25, width: 1440, height: 850),
                   CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                   CGRect(x: 0, y: 0, width: 800, height: 420)]

    @Test func 球始终在屏幕里_贴边留8点() {
        for s in screens {
            for edge in [BallPosition.Edge.left, .right] {
                for f in [-1.0, 0, 0.5, 1, 2] {
                    let b = FloatGeometry.ball(BallPosition(edge: edge, fraction: f), in: s)
                    #expect(s.contains(b))
                    #expect(b.width == 48 && b.height == 48)
                    if edge == .left { #expect(b.minX == s.minX + 8) } else { #expect(b.maxX == s.maxX - 8) }
                }
            }
        }
    }

    @Test func 松手贴最近的边_高度不变() {
        let s = screens[0]
        let nearLeft = CGRect(x: 600, y: 400, width: 48, height: 48)   // 球心 624 < 720
        let nearRight = CGRect(x: 800, y: 400, width: 48, height: 48)  // 球心 824 > 720
        let l = FloatGeometry.position(of: nearLeft, in: s), r = FloatGeometry.position(of: nearRight, in: s)
        #expect(l.edge == .left && r.edge == .right)
        #expect(FloatGeometry.ball(l, in: s).minY == 400)
        #expect(FloatGeometry.ball(r, in: s).minY == 400)
        // 拖到屏幕外：贴回屏幕里
        let out = FloatGeometry.position(of: CGRect(x: 2000, y: -300, width: 48, height: 48), in: s)
        #expect(out.edge == .right && out.fraction == 0)
    }

    @Test func 记下的位置换算回去不变() {
        for s in screens {
            let p = BallPosition(edge: .left, fraction: 0.3)
            let back = FloatGeometry.position(of: FloatGeometry.ball(p, in: s), in: s)
            #expect(back.edge == .left)
            #expect(abs(back.fraction - 0.3) < 1e-9)
        }
    }

    @Test func 默认在随手记猫球正下方_空14点() {
        let s = screens[0]
        let notes = FloatGeometry.ball(BallPosition(edge: .right, fraction: 0.55), in: s)
        let me = FloatGeometry.ball(FloatGeometry.defaultPosition(in: s), in: s)
        #expect(me.minX == notes.minX)
        #expect(abs(notes.minY - me.maxY - 14) < 1e-6)
        // 屏幕太矮放不下：贴到最下面，不出屏
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 120)
        #expect(tiny.contains(FloatGeometry.ball(FloatGeometry.defaultPosition(in: tiny), in: tiny)))
    }

    @Test func 面板开在朝屏幕里的一侧_放不下往里收() {
        let size = CGSize(width: 368, height: 600)
        for s in screens {
            for edge in [BallPosition.Edge.left, .right] {
                for f in [0.0, 0.5, 1] {
                    let b = FloatGeometry.ball(BallPosition(edge: edge, fraction: f), in: s)
                    let p = FloatGeometry.panel(size: size, ball: b, screen: s)
                    #expect(s.insetBy(dx: 11.9, dy: 11.9).contains(p))
                    #expect(p.width == 368)
                    #expect(p.height == min(600, s.height - 24))
                    if edge == .right { #expect(p.maxX <= b.minX - 8) } else { #expect(p.minX >= b.maxX + 8) }
                }
            }
        }
        // 球在中间高度、空间够：面板顶边和球顶对齐
        let s = screens[1]
        let b = FloatGeometry.ball(BallPosition(edge: .right, fraction: 0.9), in: s)
        #expect(FloatGeometry.panel(size: CGSize(width: 368, height: 400), ball: b, screen: s).maxY == b.maxY)
    }

    @Test func 空间三档和菜单栏同阈值() {
        let gb: Int64 = 1_073_741_824
        #expect(SpaceLevel(freeBytes: nil) == .ok)
        #expect(SpaceLevel(freeBytes: 60 * gb) == .ok)
        #expect(SpaceLevel(freeBytes: 60 * gb - 1) == .low)
        #expect(SpaceLevel(freeBytes: 30 * gb) == .low)
        #expect(SpaceLevel(freeBytes: 30 * gb - 1) == .critical)
    }
}
