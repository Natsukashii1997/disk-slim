import CoreGraphics
import Foundation
import Testing
@testable import DiskSlimCore

@Suite struct PendantTests {
    let gb: Int64 = 1_073_741_824

    @Test func 状态文件按三档写档位() {
        let now = Date(timeIntervalSince1970: 1_793_900_000)
        #expect(StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 86 * gb), now: now).level == "ok")
        #expect(StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 45 * gb), now: now).level == "low")
        #expect(StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 24 * gb), now: now).level == "critical")
        // 正好 60 / 30 GB 不算低于
        #expect(StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 60 * gb), now: now).level == "ok")
        #expect(StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 30 * gb), now: now).level == "low")
    }

    @Test func 状态文件写进去读回来一样_时间是ISO8601() throws {
        let tmp = TempDir(), dir = tmp.url
        let url = StatusFile.url(home: dir)
        let s = StatusFile(disk: DiskStatus(totalBytes: 460 * gb, availableBytes: 45 * gb),
                           now: Date(timeIntervalSince1970: 1_793_900_000))
        try s.write(to: url)
        #expect(StatusFile.read(from: url) == s)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"updatedAt\":\"2026-11-05T"))
        #expect(text.contains("Z\""))  // 带时区（UTC）
        #expect(text.contains("\"level\":\"low\""))
        #expect(text.contains("\"version\":1"))
    }

    @Test func 坏的状态文件读出来是空() throws {
        let tmp = TempDir(), dir = tmp.url
        let url = StatusFile.url(home: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{半份".utf8).write(to: url)
        #expect(StatusFile.read(from: url) == nil)
        #expect(StatusFile.read(from: dir.appendingPathComponent("没有")) == nil)
    }

    @Test func 链接解析出挂件位置() {
        let r = PanelLink.anchor(from: URL(string: "diskslim://panel/toggle?x=1867.5&y=-20&w=49&h=49")!)
        #expect(r == CGRect(x: 1867.5, y: -20, width: 49, height: 49))
        // 大小写不敏感的协议和主机
        #expect(PanelLink.anchor(from: URL(string: "DiskSlim://PANEL/toggle?x=1&y=2&w=3&h=4")!) != nil)
    }

    @Test func 不对的链接一律不认() {
        for s in ["diskslim://panel/toggle?x=1&y=2&w=3",          // 缺 h
                  "diskslim://panel/toggle?x=1&y=2&w=0&h=4",      // 大小为 0
                  "diskslim://panel/toggle?x=1&y=2&w=900&h=4",    // 大得离谱
                  "diskslim://panel/toggle?x=nan&y=2&w=3&h=4",    // 不是有限数
                  "diskslim://panel/toggle?x=inf&y=2&w=3&h=4",
                  "diskslim://panel/toggle?x=1e9&y=2&w=3&h=4",    // 远在天边
                  "diskslim://panel/open?x=1&y=2&w=3&h=4",        // 别的路径
                  "diskslim://clean/toggle?x=1&y=2&w=3&h=4",      // 别的主机
                  "http://panel/toggle?x=1&y=2&w=3&h=4"] {        // 别的协议
            #expect(PanelLink.anchor(from: URL(string: s)!) == nil, "\(s)")
        }
    }

    @Test func 左上原点换成左下原点() {
        // 主屏 1080 高；挂件顶在 y=100、高 49 → AppKit 里底边在 1080-149
        let r = PanelLink.appKitRect(CGRect(x: 1867, y: 100, width: 49, height: 49), primaryHeight: 1080)
        #expect(r == CGRect(x: 1867, y: 931, width: 49, height: 49))
        // 面板照样开在挂件朝屏幕里那侧
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let p = FloatGeometry.panel(size: CGSize(width: 368, height: 600), ball: r, screen: screen)
        #expect(p.maxX == r.minX - 8)
        #expect(screen.contains(p))
    }

    @Test func 点挂件那一下先被当成点外面收起_紧跟的开关指令不再打开() {
        let pendant = CGRect(x: 1400, y: 400, width: 49, height: 49)
        let onPendant = PanelToggle.OutsideClick(point: CGPoint(x: 1420, y: 430), uptime: 100)
        // 面板开着：收起
        #expect(PanelToggle.decide(isOpen: true, lastOutside: nil, anchor: pendant, now: 100) == .close)
        // 收起面板的那一下就点在挂件上：同一下点击，不再打开
        #expect(PanelToggle.decide(isOpen: false, lastOutside: onPendant, anchor: pendant, now: 100.3) == .none)
        // 机器卡、链接晚到 2 秒：还是同一下
        #expect(PanelToggle.decide(isOpen: false, lastOutside: onPendant, anchor: pendant, now: 102) == .none)
        // 点在挂件边上几点以内也算（按下后鼠标轻微移动）
        let edge = PanelToggle.OutsideClick(point: CGPoint(x: 1395, y: 400), uptime: 100)
        #expect(PanelToggle.decide(isOpen: false, lastOutside: edge, anchor: pendant, now: 100.2) == .none)
        // 3 秒以后才到：是新的一下，打开
        #expect(PanelToggle.decide(isOpen: false, lastOutside: onPendant, anchor: pendant, now: 103.1) == .open)
        // 点别处收起后马上去点挂件：收起那下不在挂件上，打开，不被吞掉
        let elsewhere = PanelToggle.OutsideClick(point: CGPoint(x: 600, y: 300), uptime: 100)
        #expect(PanelToggle.decide(isOpen: false, lastOutside: elsewhere, anchor: pendant, now: 100.2) == .open)
        // 从没收起过：打开；开机秒数比记录还小（不会发生，防一手）：打开
        #expect(PanelToggle.decide(isOpen: false, lastOutside: nil, anchor: pendant, now: 100) == .open)
        #expect(PanelToggle.decide(isOpen: false, lastOutside: onPendant, anchor: pendant, now: 50) == .open)
    }

    @Test func 链接边界值() {
        func ok(_ q: String) -> Bool { PanelLink.anchor(from: URL(string: "diskslim://panel/toggle?\(q)")!) != nil }
        #expect(ok("x=1&y=2&w=400&h=400"))
        #expect(!ok("x=1&y=2&w=401&h=40"))
        #expect(!ok("x=1&y=2&w=-49&h=49"))
        #expect(!ok("x=1&y=2&w=49&h=-49"))
        #expect(!ok("x=abc&y=2&w=49&h=49"))
        // 坐标可以是负的（主屏左边或上面还有一块屏）
        #expect(ok("x=-1900&y=-1000&w=49&h=49"))
    }

    @Test func 副屏在主屏上方时换算() {
        // 主屏 956 高；副屏在它上面，挂件 y=-600（左上原点）→ AppKit 里在主屏顶边之上
        let r = PanelLink.appKitRect(CGRect(x: 300, y: -600, width: 49, height: 49), primaryHeight: 956)
        #expect(r == CGRect(x: 300, y: 1507, width: 49, height: 49))
        #expect(r.minY > 956)
    }
}
