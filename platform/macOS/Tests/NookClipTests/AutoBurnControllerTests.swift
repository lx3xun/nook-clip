import AppKit
import XCTest
@testable import NookClip

/// 粘完即焚（Auto-Burn Clipboard）行为测试。
///
/// 关注四件事，都是用户能直接感知的：
/// 1. 复制验证码时，系统剪贴板被换成纯码（⌘V 直接粘数字）；
/// 2. 敏感内容粘贴一次后，剪贴板被清空；
/// 3. 没粘贴时按倒计时擦除，且不会误擦用户后来复制的内容；
/// 4. 验证码记录按设置「粘完 5 秒」彻底销毁，用户点「保留」则不销毁。
@MainActor
final class AutoBurnControllerTests: XCTestCase {

    override func tearDown() {
        AutoBurnController.externalPasteMonitorInstaller = nil
        AutoBurnController.shared.cancelResident()
        PasteService.shared.defaults = .standard
        super.tearDown()
    }

    private func makeController(defaults: UserDefaults? = nil) -> AutoBurnController {
        let resolved = defaults ?? makeIsolatedDefaults()
        // 提纯走 PasteService，它的配置也必须指向隔离 defaults，
        // 否则会读真实用户设置、并留下跨用例的擦除定时器
        PasteService.shared.defaults = resolved
        let controller = AutoBurnController(defaults: resolved)
        // 测试里把延迟压到毫秒级，避免用例等真实 0.3s / 5s
        controller.pasteClearDelay = 0.05
        controller.historyBurnDelay = 0.05
        return controller
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 验证码提纯

    func testCapturedOtpIsPurifiedIntoPasteboard() {
        withPasteboardLock {
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString("【阿里云】您的验证码是 482910，5分钟内有效。", forType: .string)

            let controller = makeController()
            controller.handleCapturedText("【阿里云】您的验证码是 482910，5分钟内有效。", itemID: UUID())

            XCTAssertEqual(pasteboard.string(forType: .string), "482910")
            XCTAssertEqual(controller.resident?.kind, .otp)
            controller.cancelResident()
        }
    }

    func testCapturedOtpKeepsOriginalTextWhenPurifyDisabled() {
        withPasteboardLock {
            let defaults = makeIsolatedDefaults()
            defaults.set(false, forKey: UserDefaultsKey.autoBurnOtpEnabled.rawValue)
            let pasteboard = PasteboardAccess.general
            let original = "Your verification code is 913704."
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)

            let controller = makeController(defaults: defaults)
            controller.handleCapturedText(original, itemID: nil)

            // 提纯关闭：剪贴板保持原样，但仍按敏感内容登记驻留态
            XCTAssertEqual(pasteboard.string(forType: .string), original)
            XCTAssertEqual(controller.resident?.kind, .otp)
            controller.cancelResident()
        }
    }

    func testOrdinaryTextCancelsResident() {
        withPasteboardLock {
            let controller = makeController()
            controller.handleCapturedText("您的验证码是 482910", itemID: nil)
            XCTAssertNotNil(controller.resident)

            controller.handleCapturedText("今天下午三点开会", itemID: nil)
            XCTAssertNil(controller.resident, "复制普通内容后不该继续监听键盘")
        }
    }

    // MARK: - 粘贴后擦除

    func testPanelPasteClearsPasteboard() async {
        await withPasteboardLock {
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString("482910", forType: .string)

            let controller = makeController()
            controller.handlePanelPaste(itemID: UUID(), plainText: "482910", isSensitive: true)
            await wait(0.25)

            XCTAssertNil(pasteboard.string(forType: .string), "粘贴一次后剪贴板必须被清空")
        }
    }

    func testExternalPasteClearsPasteboard() async {
        await withPasteboardLock {
            // 用「赋值型密码」当高敏内容：Rust 侧 password_assignment 规则稳定命中
            let secret = "password = Tr0ub4dor&3"
            let controller = makeController()
            var fire: (() -> Void)?
            AutoBurnController.externalPasteMonitorInstaller = { handler in
                fire = handler
                return NSNull()
            }
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString(secret, forType: .string)

            controller.handleCapturedText(secret, itemID: nil)
            XCTAssertNotNil(fire, "驻留期间必须挂上外部粘贴监听")
            fire?()
            await wait(0.25)

            XCTAssertNil(pasteboard.string(forType: .string), "外部粘贴后剪贴板必须被清空")
        }
    }

    func testClearIsSkippedWhenUserCopiedSomethingElse() async {
        await withPasteboardLock {
            let controller = makeController()
            var fire: (() -> Void)?
            AutoBurnController.externalPasteMonitorInstaller = { handler in
                fire = handler
                return NSNull()
            }
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString("482910", forType: .string)
            controller.handleCapturedText("您的验证码是 482910", itemID: nil)

            // 用户已经复制了别的内容：不能把新内容误擦掉
            pasteboard.clearContents()
            pasteboard.setString("新复制的内容", forType: .string)
            fire?()
            await wait(0.25)

            XCTAssertEqual(pasteboard.string(forType: .string), "新复制的内容")
        }
    }

    // MARK: - 历史销毁

    func testHistoryBurnFiresAfterOtpPanelPaste() async {
        await withPasteboardLock {
            let defaults = makeIsolatedDefaults()
            defaults.set(true, forKey: UserDefaultsKey.autoBurnHistoryBurnEnabled.rawValue)
            let controller = makeController(defaults: defaults)
            // 还原真实时序关系：剪贴板擦除比历史销毁先发生（0.03s < 0.10s），
            // 确保擦除剪贴板不会误取消排队中的历史销毁定时器。
            controller.pasteClearDelay = 0.03
            controller.historyBurnDelay = 0.10
            let itemID = UUID()
            var burned: [UUID] = []
            controller.onHistoryBurn = { burned.append($0) }

            // 真实流程：先复制（此时识别为验证码、剪贴板被提纯成纯码），再从面板粘贴
            controller.handleCapturedText("【阿里云】您的验证码是 482910，5分钟内有效。", itemID: itemID)
            controller.handlePanelPaste(itemID: itemID, plainText: "482910", isSensitive: true)
            await wait(0.25)

            XCTAssertEqual(burned, [itemID])
        }
    }

    func testHistoryBurnIsOffByDefault() async {
        await withPasteboardLock {
            let controller = makeController()
            var burned: [UUID] = []
            controller.onHistoryBurn = { burned.append($0) }

            controller.handleCapturedText("您的验证码是 482910", itemID: UUID())
            controller.handlePanelPaste(itemID: UUID(), plainText: "482910", isSensitive: true)
            await wait(0.25)

            XCTAssertTrue(burned.isEmpty, "默认不替用户删历史记录")
        }
    }

    func testKeepCancelsHistoryBurn() async {
        await withPasteboardLock {
            let defaults = makeIsolatedDefaults()
            defaults.set(true, forKey: UserDefaultsKey.autoBurnHistoryBurnEnabled.rawValue)
            let controller = makeController(defaults: defaults)
            let itemID = UUID()
            var burned: [UUID] = []
            controller.onHistoryBurn = { burned.append($0) }

            controller.handleCapturedText("您的验证码是 482910", itemID: itemID)
            controller.handlePanelPaste(itemID: itemID, plainText: "482910", isSensitive: true)
            controller.keep(itemID: itemID)
            await wait(0.25)

            XCTAssertTrue(burned.isEmpty, "用户点了保留就不该销毁")
        }
    }

    func testBurnNowDeletesImmediately() {
        withPasteboardLock {
            let controller = makeController()
            let itemID = UUID()
            var burned: [UUID] = []
            controller.onHistoryBurn = { burned.append($0) }
            let pasteboard = PasteboardAccess.general
            pasteboard.clearContents()
            pasteboard.setString("482910", forType: .string)
            controller.handleCapturedText("您的验证码是 482910", itemID: itemID)

            controller.burnNow(itemID: itemID)

            XCTAssertEqual(burned, [itemID])
            XCTAssertNil(pasteboard.string(forType: .string))
            XCTAssertNil(controller.resident)
        }
    }

    // MARK: - 倒计时展示

    func testRemainingSecondsCountsDown() {
        withPasteboardLock {
            let defaults = makeIsolatedDefaults()
            defaults.set(60, forKey: PasteService.sensitiveTimeoutKey)
            let controller = makeController(defaults: defaults)
            controller.handleCapturedText("您的验证码是 482910", itemID: nil)

            let remaining = controller.remainingSeconds()
            XCTAssertNotNil(remaining)
            XCTAssertTrue((58...60).contains(remaining ?? 0), "剩余秒数应接近 60，实际 \(String(describing: remaining))")
            controller.cancelResident()
        }
    }

    // MARK: - 历史库物理删除

    func testBurnImmediatelyRemovesItemFromStore() {
        let store = makeIsolatedStore()
        store.save(ClipboardItem(type: .text, title: "验证码", summary: "482910", isSensitive: true))
        let itemID = store.items[0].id
        XCTAssertNotNil(store.item(withID: itemID))

        store.burnImmediately(itemID)

        XCTAssertTrue(store.items.isEmpty, "焚毁后内存活跃列表 items 也必须立即移除该条目")
        XCTAssertNil(store.item(withID: itemID), "焚毁后条目不该再存在")
        XCTAssertTrue(store.trashItems.isEmpty, "焚毁不走回收站，撤销窗口里也不该留")
    }
}
