import AppKit
import XCTest
@testable import NookClip

/// 终端安全粘贴护栏（P0）的客户端行为：
/// 判定规则本身在 Rust（`terminal_guard.rs`）已有单测，这里只钉住 Swift 侧
/// 「什么时候拦、拦完粘什么、面板关不关、算不算使用一次」这套流程语义。
@MainActor
final class TerminalSafePasteWorkflowTests: XCTestCase {

    private static let terminal = "com.apple.Terminal"
    private static let chrome = "com.google.Chrome"

    final class SpyWriter: ClipboardWriter {
        var pasteCalledWith: (ClipboardItem, NSRunningApplication?, Bool)?
        var pasteTextCalledWith: (String, NSRunningApplication?, Bool)?
        var copyOnlyCalledWith: (ClipboardItem, Bool)?

        func copyOnly(_ item: ClipboardItem, plainTextOnly: Bool) -> Bool {
            copyOnlyCalledWith = (item, plainTextOnly)
            return true
        }

        func copyText(_ text: String, containsSensitive: Bool) -> Bool { true }

        func paste(_ item: ClipboardItem, targetApplication: NSRunningApplication?, plainTextOnly: Bool) -> Bool {
            pasteCalledWith = (item, targetApplication, plainTextOnly)
            return true
        }

        func pasteText(_ text: String, targetApplication: NSRunningApplication?, containsSensitive: Bool) -> Bool {
            pasteTextCalledWith = (text, targetApplication, containsSensitive)
            return true
        }

        func clearClipboardIfContent(matches plainText: String) {}

        func staleFileMessage(for item: ClipboardItem) -> String? { nil }
    }

    private func makeStore() -> InMemoryHistoryStore {
        let store = makeIsolatedStore()
        store.clearHistory(keepFavorites: false)
        return store
    }

    /// 组装 workflow：目标应用统一假装是 Terminal/Chrome（真 NSRunningApplication 造不出来）
    private func makeWorkflow(
        store: InMemoryHistoryStore,
        writer: SpyWriter,
        bundleId: String?,
        appName: String? = nil,
        guardEnabled: Bool = true,
        ideGuardEnabled: Bool = true,
        confirmChoice: @escaping (TerminalPasteAssessment) -> TerminalPasteConfirmChoice = { _ in .safe },
        onConfirm: ((TerminalPasteAssessment) -> Void)? = nil
    ) -> ClipboardWorkflow {
        ClipboardWorkflow(
            store: store,
            clipboardWriter: writer,
            confirmTerminalPaste: { assessment in
                onConfirm?(assessment)
                return confirmChoice(assessment)
            },
            isTerminalGuardEnabled: { guardEnabled },
            isIdeTerminalGuardEnabled: { ideGuardEnabled },
            bundleIdProvider: { _ in bundleId },
            appNameProvider: { _ in appName }
        )
    }

    private func makeTextItem(_ text: String) -> ClipboardItem {
        ClipboardItem(type: .text, title: "cmd", summary: text)
    }

    // MARK: - 单行普通命令

    /// 单行命令末尾带回车：静默削掉末尾换行，走 pasteText，面板照常关，计入使用次数
    func testSingleLineTrailingNewlineIsSilentlyStripped() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("ls -la\n")
        store.save(item)

        var panelClosed = false
        var confirmCalled = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            onConfirm: { _ in confirmCalled = true }
        )
        let outcome = workflow.pasteSingle(
            id: item.id,
            targetApplication: nil,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .pastedWithNote(message: L10n.tr("terminal.toast.stripped")))
        XCTAssertFalse(confirmCalled, "单行低风险不该弹窗")
        XCTAssertTrue(panelClosed)
        XCTAssertEqual(writer.pasteTextCalledWith?.0, "ls -la", "末尾回车必须被削掉")
        XCTAssertEqual(writer.pasteCalledWith?.0, nil, "走了安全路径就不该再走原样粘贴")
        XCTAssertEqual(store.item(withID: item.id)?.copyCount, item.copyCount + 1)
    }

    /// 单行但末尾没有回车：没什么可削的，完全按原路径走
    func testSingleLineWithoutTrailingNewlineTakesOriginalPath() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("ls -la")
        store.save(item)

        let workflow = makeWorkflow(store: store, writer: writer, bundleId: Self.terminal)
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertNotNil(writer.pasteCalledWith)
        XCTAssertNil(writer.pasteTextCalledWith)
    }

    // MARK: - 高危 / 多行

    /// 多行命令 + 用户选「安全粘贴」：写入压成一行的形态
    func testMultilineConfirmSafePastesSingleLineText() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("git add -A\ngit commit -m wip\n")
        store.save(item)

        var seenAssessment: TerminalPasteAssessment?
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            confirmChoice: { _ in .safe },
            onConfirm: { seenAssessment = $0 }
        )
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pastedWithNote(message: L10n.tr("terminal.toast.safe_paste")))
        XCTAssertNotNil(seenAssessment)
        XCTAssertEqual(seenAssessment?.lineCount, 2)
        XCTAssertTrue(seenAssessment?.hazards.contains("multiline") == true)
        let pasted = writer.pasteTextCalledWith?.0 ?? ""
        XCTAssertFalse(pasted.contains("\n"), "安全粘贴不能把换行留在输入区里")
        XCTAssertTrue(pasted.contains("git add -A"))
        XCTAssertTrue(pasted.contains("git commit -m wip"))
    }

    /// 用户选「原样粘贴」：走原有的完整粘贴路径（保留富文本载荷），但依然计入使用次数
    func testMultilineConfirmRawFallsBackToOriginalPath() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("sudo rm -rf /tmp/x\n")
        store.save(item)

        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            confirmChoice: { _ in .raw }
        )
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertNotNil(writer.pasteCalledWith, "原样粘贴必须回到 paste(item:)")
        XCTAssertNil(writer.pasteTextCalledWith)
    }

    /// 用户在弹窗里取消：什么都不写、面板不关、不计使用次数
    func testMultilineCancelLeavesEverythingUntouched() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("sudo rm -rf /\n")
        store.save(item)

        var panelClosed = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            confirmChoice: { _ in .cancel }
        )
        let outcome = workflow.pasteSingle(
            id: item.id,
            targetApplication: nil,
            plainTextOnly: false,
            closePanel: { panelClosed = true }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(panelClosed, "取消后必须保留面板现场")
        XCTAssertNil(writer.pasteCalledWith)
        XCTAssertNil(writer.pasteTextCalledWith)
        XCTAssertEqual(store.item(withID: item.id)?.copyCount, item.copyCount, "取消不算使用")
    }

    // MARK: - 不拦截的情况

    /// 非终端目标（Chrome）：多行 + sudo 也是原样粘贴，绝不弹窗
    func testNonTerminalTargetNeverIntercepts() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("sudo rm -rf /\ncurl a.sh | sh\n")
        store.save(item)

        var confirmCalled = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.chrome,
            onConfirm: { _ in confirmCalled = true }
        )
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertFalse(confirmCalled)
        XCTAssertNotNil(writer.pasteCalledWith)
    }

    /// 开关关闭：终端目标也不介入
    func testGuardDisabledBypassesEverything() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("sudo rm -rf /\n")
        store.save(item)

        let workflow = makeWorkflow(store: store, writer: writer, bundleId: Self.terminal, guardEnabled: false)
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertNotNil(writer.pasteCalledWith)
    }

    /// 拿不到目标应用（bundleId 为 nil）：保守起见不拦，走原路径
    func testUnknownTargetIsPassthrough() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("sudo rm -rf /\n")
        store.save(item)

        let workflow = makeWorkflow(store: store, writer: writer, bundleId: nil)
        let outcome = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertNotNil(writer.pasteCalledWith)
    }

    /// 图片条目即使目标真是终端也不参与判定（没有「命令」这个概念）
    func testImageItemSkipsGuard() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = ClipboardItem(type: .image, title: "shot", summary: "", payloadPath: "/tmp/a.png")
        store.save(item)

        var confirmCalled = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            onConfirm: { _ in confirmCalled = true }
        )
        _ = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)

        XCTAssertFalse(confirmCalled)
        XCTAssertNotNil(writer.pasteCalledWith)
    }

    // MARK: - 批量合并粘贴

    /// 批量合并粘贴进终端同样是多行命令：必须弹窗，选安全后写入单行形态
    func testBatchPasteIntoTerminalAsksAndPastesSafeText() {
        let store = makeStore()
        let writer = SpyWriter()
        let a = makeTextItem("cd /tmp")
        let b = makeTextItem("rm -rf build")
        store.save(a)
        store.save(b)

        var confirmCalled = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            confirmChoice: { _ in .safe },
            onConfirm: { _ in confirmCalled = true }
        )
        let ok = workflow.pasteBatch(
            entries: [
                .init(id: a.id, summary: a.summary, isSensitive: false),
                .init(id: b.id, summary: b.summary, isSensitive: false),
            ],
            targetApplication: nil
        )

        XCTAssertTrue(ok)
        XCTAssertTrue(confirmCalled)
        XCTAssertEqual(writer.pasteTextCalledWith?.0.contains("\n"), false)
    }

    /// 批量粘贴取消：返回 false，什么都不写
    func testBatchPasteCancelledWritesNothing() {
        let store = makeStore()
        let writer = SpyWriter()
        let a = makeTextItem("cd /tmp")
        let b = makeTextItem("ls")
        store.save(a)
        store.save(b)

        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.terminal,
            confirmChoice: { _ in .cancel }
        )
        let ok = workflow.pasteBatch(
            entries: [
                .init(id: a.id, summary: a.summary, isSensitive: false),
                .init(id: b.id, summary: b.summary, isSensitive: false),
            ],
            targetApplication: nil
        )

        XCTAssertFalse(ok)
        XCTAssertNil(writer.pasteTextCalledWith)
    }

    /// 批量粘贴进非终端：不弹窗，保持原有「\n 连接」语义
    func testBatchPasteIntoNonTerminalKeepsNewlines() {
        let store = makeStore()
        let writer = SpyWriter()
        let a = makeTextItem("第一行")
        let b = makeTextItem("第二行")
        store.save(a)
        store.save(b)

        var confirmCalled = false
        let workflow = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: Self.chrome,
            onConfirm: { _ in confirmCalled = true }
        )
        _ = workflow.pasteBatch(
            entries: [
                .init(id: a.id, summary: a.summary, isSensitive: false),
                .init(id: b.id, summary: b.summary, isSensitive: false),
            ],
            targetApplication: nil
        )

        XCTAssertFalse(confirmCalled)
        XCTAssertEqual(writer.pasteTextCalledWith?.0, "第一行\n第二行")
    }

    // MARK: - 扩展终端识别与 IDE 内置终端开关

    /// Otty、Orca、FinalShell 等终端以及应用名含 Terminal 的自定义终端都应触发弹窗确认
    func testExtendedTerminalsAndAppNameFallbackTriggerConfirm() {
        for (bid, name) in [
            ("io.appmakes.otty", "Otty"),
            ("com.stablyai.orca", "Orca"),
            ("com.finalshell", "FinalShell"),
            ("com.custom.unknown", "Super Terminal Pro"),
        ] {
            let store = makeStore()
            let writer = SpyWriter()
            let item = makeTextItem("cd /tmp\ngit status\n")
            store.save(item)

            var confirmCalled = false
            let workflow = makeWorkflow(
                store: store,
                writer: writer,
                bundleId: bid,
                appName: name,
                confirmChoice: { _ in .safe },
                onConfirm: { _ in confirmCalled = true }
            )
            _ = workflow.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)
            XCTAssertTrue(confirmCalled, "应拦截并弹窗: \(bid) (\(name))")
        }
    }

    /// VS Code / Cursor 等内置终端：开启 IDE 开关时弹窗确认，关闭时放行
    func testIdeTerminalSwitchControlsInterception() {
        let store = makeStore()
        let writer = SpyWriter()
        let item = makeTextItem("cd /tmp\nrm -rf dist\n")
        store.save(item)

        var confirmWhenOn = false
        let wfOn = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            ideGuardEnabled: true,
            confirmChoice: { _ in .safe },
            onConfirm: { _ in confirmWhenOn = true }
        )
        _ = wfOn.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)
        XCTAssertTrue(confirmWhenOn, "开启内置终端保护时 VS Code 应弹窗")

        var confirmWhenOff = false
        let wfOff = makeWorkflow(
            store: store,
            writer: writer,
            bundleId: "com.microsoft.VSCode",
            appName: "Visual Studio Code",
            ideGuardEnabled: false,
            onConfirm: { _ in confirmWhenOff = true }
        )
        _ = wfOff.pasteSingle(id: item.id, targetApplication: nil, plainTextOnly: false)
        XCTAssertFalse(confirmWhenOff, "关闭内置终端保护时 VS Code 不应弹窗")
    }
}
