import XCTest
@testable import NookClip

/// 飞行动画的几何计算测试。
///
/// 只覆盖纯函数（`PasteStackFlightGeometry`）：轨迹、缩放、透明度、窗口矩形。
/// 真正的 NSPanel 与 SwiftUI 动画依赖 NSApp 事件循环，放在真机冒烟里验。
@MainActor
final class PasteStackFlightGeometryTests: XCTestCase {

    // MARK: 轨迹

    func testPathStartsAndEndsAtGivenPoints() {
        let start = NSPoint(x: 120, y: 900)
        let end = NSPoint(x: 620, y: 240)
        let control = PasteStackFlightGeometry.controlPoint(from: start, to: end)

        let atZero = PasteStackFlightGeometry.point(progress: 0, from: start, control: control, to: end)
        let atOne = PasteStackFlightGeometry.point(progress: 1, from: start, control: control, to: end)

        XCTAssertEqual(atZero.x, start.x, accuracy: 0.001)
        XCTAssertEqual(atZero.y, start.y, accuracy: 0.001)
        XCTAssertEqual(atOne.x, end.x, accuracy: 0.001)
        XCTAssertEqual(atOne.y, end.y, accuracy: 0.001)
    }

    func testProgressIsClampedToUnitRange() {
        let start = NSPoint(x: 0, y: 0)
        let end = NSPoint(x: 100, y: 100)
        let control = PasteStackFlightGeometry.controlPoint(from: start, to: end)

        let below = PasteStackFlightGeometry.point(progress: -3, from: start, control: control, to: end)
        let above = PasteStackFlightGeometry.point(progress: 4, from: start, control: control, to: end)

        XCTAssertEqual(below.x, start.x, accuracy: 0.001)
        XCTAssertEqual(below.y, start.y, accuracy: 0.001)
        XCTAssertEqual(above.x, end.x, accuracy: 0.001)
        XCTAssertEqual(above.y, end.y, accuracy: 0.001)
    }

    /// 控制点必须往上抬（屏幕坐标 y 越大越靠上）。
    ///
    /// 浮窗永远在屏幕下方，如果轨迹往下拱，卡片会先沉进屏幕边缘再往上爬，
    /// 观感像「东西掉下去了又飞回来」。
    func testControlPointLiftsAboveTheStraightLine() {
        let start = NSPoint(x: 200, y: 1000)
        let end = NSPoint(x: 600, y: 200)
        let control = PasteStackFlightGeometry.controlPoint(from: start, to: end)

        let midpointY = (start.y + end.y) / 2
        XCTAssertGreaterThan(control.y, midpointY, "控制点应该在中点之上")
    }

    /// 抬升量要有上下限：近距离不拱成大弧、跨屏也不飞出屏幕。
    func testControlPointLiftIsClamped() {
        // 极短距离：抬升取下限
        let near = PasteStackFlightGeometry.controlPoint(
            from: NSPoint(x: 0, y: 0),
            to: NSPoint(x: 4, y: 2)
        )
        XCTAssertEqual(near.y, (0 + 2) / 2 + PasteStackFlightGeometry.minLift, accuracy: 0.001)

        // 极长距离：抬升取上限
        let far = PasteStackFlightGeometry.controlPoint(
            from: NSPoint(x: 0, y: 0),
            to: NSPoint(x: 5000, y: 4000)
        )
        XCTAssertEqual(far.y, (0 + 4000) / 2 + PasteStackFlightGeometry.maxLift, accuracy: 0.001)
    }

    // MARK: 缩放与透明度

    func testCardShrinksTowardsItsDestination() {
        XCTAssertEqual(PasteStackFlightGeometry.cardScale(progress: 0), 1, accuracy: 0.001)
        XCTAssertEqual(
            PasteStackFlightGeometry.cardScale(progress: 1),
            PasteStackFlightGeometry.endScale,
            accuracy: 0.001
        )
        let half = PasteStackFlightGeometry.cardScale(progress: 0.5)
        XCTAssertLessThan(half, 1)
        XCTAssertGreaterThan(half, PasteStackFlightGeometry.endScale)
    }

    func testCardFadesInThenOut() {
        // 起点还没显形：从零淡入，避免在鼠标位置「啪」地出现
        XCTAssertEqual(PasteStackFlightGeometry.cardOpacity(progress: 0), 0, accuracy: 0.001)
        // 中段完全不透明，保证内容可读
        XCTAssertEqual(PasteStackFlightGeometry.cardOpacity(progress: 0.5), 1, accuracy: 0.001)
        // 终点前淡出，把注意力交给落地的真实行
        XCTAssertEqual(PasteStackFlightGeometry.cardOpacity(progress: 1), 0, accuracy: 0.001)
    }

    func testOpacityIsMonotonicAcrossFadeIn() {
        var previous = -1.0
        for step in 0...12 {
            let value = PasteStackFlightGeometry.cardOpacity(progress: Double(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous - 0.0001, "淡入段不应回退")
            previous = value
        }
    }

    // MARK: 窗口矩形

    /// 窗口必须同时包住起点和终点。
    ///
    /// 这里曾经用 `NSRect(x:y:width:0,height:0).union(end)` 求并集，
    /// 宽高为 0 的矩形 `isEmpty` 为真、被 `NSUnionRect` 直接忽略，起点丢失后
    /// 卡片会从窗口外「凭空出现」。
    func testWindowRectContainsBothEnds() {
        let start = NSPoint(x: 100, y: 900)
        let end = NSRect(x: 300, y: 200, width: 320, height: 26)
        let rect = PasteStackFlightGeometry.windowRect(from: start, to: end, margin: 10)

        XCTAssertTrue(rect.contains(start), "窗口必须包含起点")
        XCTAssertTrue(rect.contains(NSPoint(x: end.minX, y: end.minY)))
        XCTAssertTrue(rect.contains(NSPoint(x: end.maxX, y: end.maxY)))
    }

    func testWindowRectAppliesMarginOnEverySide() {
        let start = NSPoint(x: 500, y: 500)
        let end = NSRect(x: 520, y: 480, width: 100, height: 26)
        let margin: CGFloat = 24
        let rect = PasteStackFlightGeometry.windowRect(from: start, to: end, margin: margin)

        XCTAssertEqual(rect.minX, min(start.x, end.minX) - margin, accuracy: 0.001)
        XCTAssertEqual(rect.minY, min(start.y, end.minY) - margin, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, max(start.x, end.maxX) + margin, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, max(start.y, end.maxY) + margin, accuracy: 0.001)
    }

    /// 起点落在终点矩形内部时，窗口仍然不能塌成零尺寸
    func testWindowRectStaysNonEmptyWhenStartIsInsideEnd() {
        let end = NSRect(x: 300, y: 200, width: 320, height: 26)
        let start = NSPoint(x: end.midX, y: end.midY)
        let rect = PasteStackFlightGeometry.windowRect(from: start, to: end, margin: 8)

        XCTAssertFalse(rect.isEmpty)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
    }

    // MARK: 时长

    /// 飞行时长得卡在「看得清」和「不挡事」之间。
    ///
    /// 超过 0.6s 连续复制时会互相追尾，成一串拖影；低于 0.25s 又看不清是飞过去的。
    func testFlightDurationStaysInReadableRange() {
        XCTAssertGreaterThanOrEqual(PasteStackFlightOverlay.duration, 0.25)
        XCTAssertLessThanOrEqual(PasteStackFlightOverlay.duration, 0.6)
    }
}
