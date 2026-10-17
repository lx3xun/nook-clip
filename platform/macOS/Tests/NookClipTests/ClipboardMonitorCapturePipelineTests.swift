import XCTest
@testable import NookClip

/// 捕获管线线程预算（接缝 B 变体：主线程心跳观测）。
/// 轮询拆分契约：粘贴板读取留在主线程（快），敏感检测/特征分析 FFI/
/// 哈希/载荷落盘在后台执行。判定方式：间谍引擎在 analyzeContent 开头
/// 向主队列投递心跳再 sleep 300ms——
/// - 同步捕获（旧实现）：分析阻塞主线程，心跳排在捕获之后，
///   onChange 触发时心跳未执行（红）；
/// - 后台捕获（目标实现）：主线程空闲，心跳先于 onChange 送达（绿）。
/// 主队列 FIFO 保证两种情形下判定均确定。
@MainActor
final class ClipboardMonitorCapturePipelineTests: XCTestCase {

    private final class MainThreadFlag: @unchecked Sendable {
        var value = false
    }

    private final class SlowAnalyzingEngine: NookClipHistoryEngine, @unchecked Sendable {
        let heartbeat = MainThreadFlag()

        required public init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
            super.init(unsafeFromRawPointer: pointer)
        }

        init(cloneOf base: NookClipHistoryEngine) {
            super.init(unsafeFromRawPointer: base.uniffiClonePointer())
        }

        override func ingestClipboardSnapshot(
            snapshot: RawClipboardSnapshot,
            config: IngestConfig,
            lastPastedSummary: String?,
            lastPastedTime: Double?,
            nowTs: Double
        ) throws -> IngestOutcome {
            DispatchQueue.main.async { [heartbeat] in heartbeat.value = true }
            Thread.sleep(forTimeInterval: 0.3)
            return try super.ingestClipboardSnapshot(
                snapshot: snapshot,
                config: config,
                lastPastedSummary: lastPastedSummary,
                lastPastedTime: lastPastedTime,
                nowTs: nowTs
            )
        }
    }

    func test_captureProcessingDoesNotBlockMainThread() async throws {
        let baseEngine = try NookClipHistoryEngine(
            dbPath: ":memory:",
            masterKey: Data(repeating: 0x42, count: 32)
        )
        let slowEngine = SlowAnalyzingEngine(cloneOf: baseEngine)
        let monitor = ClipboardMonitor(rustEngine: slowEngine)
        var heartbeatAtDelivery: Bool?
        monitor.onChange = { _ in
            heartbeatAtDelivery = slowEngine.heartbeat.value
        }
        monitor.start()
        defer { monitor.stop() }

        try await withPasteboardLock {
            let pb = PasteboardAccess.general
            pb.clearContents()
            XCTAssertTrue(pb.setString("heartbeat needle content", forType: .string))
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }

        XCTAssertNotNil(heartbeatAtDelivery, "前置：捕获确实发生并送达 onChange")
        XCTAssertEqual(heartbeatAtDelivery, true, "捕获分析期间主线程必须保持响应（后台执行）")
    }
}
