import XCTest
@testable import NookClip

/// 立即单击识别器测试：单击零延迟返回，双击按时间间隔判定——
/// 替代 onTapGesture(count:2)+onTapGesture 组合（该组合下单击要等满
/// 双击判定窗口才回调，列表点击选中可感知延迟）。
/// 显式注入判定间隔，不依赖系统双击速度设置（测试确定性）
final class ImmediateTapDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func register(
        _ detector: inout ImmediateTapDetector,
        at date: Date
    ) -> ImmediateTapDetector.Kind {
        detector.register(at: date, interval: 0.5)
    }

    /// 首击 → single（不等双击窗口）
    func testFirstTapIsSingle() {
        var detector = ImmediateTapDetector()
        XCTAssertEqual(register(&detector, at: t0), .single)
    }

    /// 双击窗口内的第二击 → double
    func testSecondTapWithinIntervalIsDouble() {
        var detector = ImmediateTapDetector()
        _ = register(&detector, at: t0)
        XCTAssertEqual(register(&detector, at: t0.addingTimeInterval(0.2)), .double)
    }

    /// 超过窗口的第二击仍是新的 single
    func testSecondTapBeyondIntervalIsSingle() {
        var detector = ImmediateTapDetector()
        _ = register(&detector, at: t0)
        XCTAssertEqual(register(&detector, at: t0.addingTimeInterval(0.6)), .single)
    }

    /// 双击判定后计数复位：第三击是新的 single
    func testTapAfterDoubleIsSingle() {
        var detector = ImmediateTapDetector()
        _ = register(&detector, at: t0)
        _ = register(&detector, at: t0.addingTimeInterval(0.2))
        XCTAssertEqual(register(&detector, at: t0.addingTimeInterval(0.3)), .single)
    }

    /// 未选中状态下点击切换记录：首次点击为 single，且不开启双击窗口（随后快速点击为 single，防止误触发粘贴）
    func testTapWhenUnselectedPreventsDoubleTapOnFastSecondTap() {
        var detector = ImmediateTapDetector()
        // 第一次点击：未选中（从其他行切换过来）
        let first = detector.register(isSelected: false, at: t0, interval: 0.5)
        XCTAssertEqual(first, .single)

        // 0.2 秒后第二次快速点击（此时已是选中态）：仍必须判定为 single，不能为 double
        let second = detector.register(isSelected: true, at: t0.addingTimeInterval(0.2), interval: 0.5)
        XCTAssertEqual(second, .single)
    }

    /// 显式 reset 清空双击时间窗口
    func testResetClearsTapWindow() {
        var detector = ImmediateTapDetector()
        _ = detector.register(isSelected: true, at: t0, interval: 0.5)
        detector.reset()
        XCTAssertEqual(detector.register(isSelected: true, at: t0.addingTimeInterval(0.2), interval: 0.5), .single)
    }

    /// 未选中状态下即使多次快速点击，也全部返回 single，绝不误触发 double
    func testMultipleFastTapsWhileUnselectedAllReturnSingle() {
        var detector = ImmediateTapDetector()
        for offset in [0.0, 0.1, 0.2, 0.3] {
            let kind = detector.register(isSelected: false, at: t0.addingTimeInterval(offset), interval: 0.5)
            XCTAssertEqual(kind, .single)
        }
    }

    /// 选中之后的主动双击：首次点击为 single，窗口内的第二次点击正常判定为 double
    func testDoubleTapSucceedsAfterItemIsAlreadySelected() {
        var detector = ImmediateTapDetector()
        // 切换到该行：首次未选中点击
        XCTAssertEqual(detector.register(isSelected: false, at: t0, interval: 0.5), .single)

        // 已经选中后，用户意图明确的双击：第一击与第二击
        let tSelected = t0.addingTimeInterval(1.0)
        XCTAssertEqual(detector.register(isSelected: true, at: tSelected, interval: 0.5), .single)
        XCTAssertEqual(detector.register(isSelected: true, at: tSelected.addingTimeInterval(0.2), interval: 0.5), .double)
    }
}
