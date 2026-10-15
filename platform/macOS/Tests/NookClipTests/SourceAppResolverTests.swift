import XCTest
@testable import NookClip

/// 复制来源归因（SourceAppResolver）：
/// 修复「Chrome 复制 → 0.35s 内切到 Orca，来源被记成 Orca」的轮询竞态。
final class SourceAppResolverTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// bug 场景：复制后不足一个轮询周期切走 → 归因到切换前的应用
    func testCopyThenQuickSwitchAttributesToPreviousApp() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.google.Chrome", name: "Google Chrome", isSelf: false, at: t0)
        resolver.record(bundleId: "com.orca", name: "Orca", isSelf: false, at: t0.addingTimeInterval(0.2))
        let source = resolver.resolve(now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(source?.bundleId, "com.google.Chrome")
        XCTAssertEqual(source?.name, "Google Chrome")
    }

    /// 当前应用已驻留超过一个轮询周期 → 归因当前应用（正常场景不受影响）
    func testStableAppAttributesToItself() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.google.Chrome", name: "Google Chrome", isSelf: false, at: t0)
        resolver.record(bundleId: "com.orca", name: "Orca", isSelf: false, at: t0.addingTimeInterval(5))
        XCTAssertEqual(resolver.resolve(now: t0.addingTimeInterval(30))?.bundleId, "com.orca")
    }

    /// 无激活记录（NookClip 刚启动）→ nil，由调用方回退当前前台应用
    func testEmptyHistoryReturnsNil() {
        let resolver = SourceAppResolver()
        XCTAssertNil(resolver.resolve(now: t0))
    }

    /// NookClip 自身激活（面板）不参与归因
    func testSelfActivationSkipped() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.google.Chrome", name: "Google Chrome", isSelf: false, at: t0)
        resolver.record(bundleId: "nook.self", name: "NookClip", isSelf: true, at: t0.addingTimeInterval(0.1))
        XCTAssertEqual(resolver.resolve(now: t0.addingTimeInterval(0.2))?.bundleId, "com.google.Chrome")
    }

    /// 快速来回切换（A → B → A）：检测时 A 激活不足一个周期，归因到 B（在 B 中复制后切回）
    func testBounceBackAttributesToMiddleApp() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.orca", name: "Orca", isSelf: false, at: t0)
        resolver.record(bundleId: "com.google.Chrome", name: "Google Chrome", isSelf: false, at: t0.addingTimeInterval(0.1))
        resolver.record(bundleId: "com.orca", name: "Orca", isSelf: false, at: t0.addingTimeInterval(0.25))
        XCTAssertEqual(resolver.resolve(now: t0.addingTimeInterval(0.3))?.bundleId, "com.google.Chrome")
    }

    /// 历史超长时裁剪，不崩溃且仍能归因
    func testHistoryTrimmed() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        for i in 0..<20 {
            resolver.record(bundleId: "app\(i)", name: "app\(i)", isSelf: false, at: t0.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertEqual(resolver.resolve(now: t0.addingTimeInterval(100))?.bundleId, "app19")
    }

    /// NookClip 面板驻留超过一个周期时剪贴板变化（面板内选中复制 / NookClip 触发的
    /// 钥匙串弹窗）→ 如实归因为 NookClip，而不是之前的外部应用
    func testResidentSelfAttributesToNookClip() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.google.Chrome", name: "Google Chrome", isSelf: false, at: t0)
        resolver.record(bundleId: "com.lx3xun.nookclip", name: "NookClip", isSelf: true, at: t0.addingTimeInterval(5))
        let source = resolver.resolve(now: t0.addingTimeInterval(10))
        XCTAssertEqual(source?.bundleId, "com.lx3xun.nookclip")
        XCTAssertEqual(source?.name, "NookClip")
    }

    /// 历史仅有 NookClip 自身（刚启动即打开面板）且已驻留 → 归因为 NookClip（此前返回 nil 导致「未知来源」）
    func testOnlySelfHistoryAttributesToNook() {
        var resolver = SourceAppResolver(pollInterval: 0.35)
        resolver.record(bundleId: "com.lx3xun.nookclip", name: "NookClip", isSelf: true, at: t0)
        XCTAssertEqual(resolver.resolve(now: t0.addingTimeInterval(1))?.name, "NookClip")
    }
}
