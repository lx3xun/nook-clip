import XCTest
@testable import NookClip

final class NookClipIconTests: XCTestCase {

    func testIconScaleTokensAscendingAndValid() {
        XCTAssertEqual(NookClipIconSize.micro, 9)
        XCTAssertEqual(NookClipIconSize.microSmall, 8)
        XCTAssertEqual(NookClipIconSize.microChevron, 7)
        XCTAssertEqual(NookClipIconSize.compact, 11)
        XCTAssertEqual(NookClipIconSize.compactMedium, 12)
        XCTAssertEqual(NookClipIconSize.regular, 13.5)
        XCTAssertEqual(NookClipIconSize.regularMedium, 14)
        XCTAssertEqual(NookClipIconSize.title, 17)
        XCTAssertEqual(NookClipIconSize.titleLarge, 20)
        XCTAssertEqual(NookClipIconSize.titleDisplay, 21)
        XCTAssertEqual(NookClipIconSize.hero, 28)
        XCTAssertEqual(NookClipIconSize.heroMedium, 30)
        XCTAssertEqual(NookClipIconSize.heroLarge, 40)

        // 验证阶梯单调性约束
        XCTAssertLessThan(NookClipIconSize.micro, NookClipIconSize.compact)
        XCTAssertLessThan(NookClipIconSize.compact, NookClipIconSize.regular)
        XCTAssertLessThan(NookClipIconSize.regular, NookClipIconSize.title)
        XCTAssertLessThan(NookClipIconSize.title, NookClipIconSize.hero)
    }

    func testSourceAppFallbacksMatchDesignSpec() {
        XCTAssertEqual(SourceAppModel.resolve(name: "Safari").symbol, NookClipIcon.SourceAppFallback.safari)
        XCTAssertEqual(SourceAppModel.resolve(name: "Xcode").symbol, NookClipIcon.SourceAppFallback.xcode)
        XCTAssertEqual(SourceAppModel.resolve(name: "微信").symbol, NookClipIcon.SourceAppFallback.wechat)
        XCTAssertEqual(SourceAppModel.resolve(name: "Figma").symbol, NookClipIcon.SourceAppFallback.figma)
        XCTAssertEqual(SourceAppModel.resolve(name: "Finder").symbol, NookClipIcon.SourceAppFallback.finder)
        XCTAssertEqual(SourceAppModel.resolve(name: "Terminal").symbol, NookClipIcon.SourceAppFallback.terminal)
        XCTAssertEqual(SourceAppModel.resolve(name: "Notes").symbol, NookClipIcon.SourceAppFallback.notes)
        XCTAssertEqual(SourceAppModel.resolve(name: "截图").symbol, NookClipIcon.SourceAppFallback.screenshot)
        XCTAssertEqual(SourceAppModel.resolve(name: "UnknownApp").symbol, NookClipIcon.SourceAppFallback.fallback)
    }


    func testAllIconsAreNonEmpty() {
        let allTokens = [
            NookClipIcon.Frame.sidebarTrailing, NookClipIcon.Frame.sidebarLeading,
            NookClipIcon.Search.magnify, NookClipIcon.Search.clear,
            NookClipIcon.Nav.chevronDown, NookClipIcon.Nav.chevronUpDown, NookClipIcon.Nav.checkmark, NookClipIcon.Nav.reorder,
            NookClipIcon.Nav.arrowUp, NookClipIcon.Nav.arrowDown,
            NookClipIcon.Nav.resetOrder, NookClipIcon.Nav.clock,
            NookClipIcon.Action.favorite, NookClipIcon.Action.favoriteFilled,
            NookClipIcon.Action.delete, NookClipIcon.Action.deleteFilled,
            NookClipIcon.Action.openExternal, NookClipIcon.Action.revealInFinder, NookClipIcon.Action.qrcode,
            NookClipIcon.Action.copy, NookClipIcon.Action.copied, NookClipIcon.Action.ocr,
            NookClipIcon.Badge.favorite,
            NookClipIcon.Sensitive.lock, NookClipIcon.Sensitive.shieldOk,
            NookClipIcon.Sensitive.reveal, NookClipIcon.Sensitive.remask,
            NookClipIcon.Feedback.warning, NookClipIcon.Feedback.link, NookClipIcon.Feedback.doc,
            NookClipIcon.Empty.preview, NookClipIcon.Empty.qrcode, NookClipIcon.Empty.excluded,
            NookClipIcon.Excluded.empty, NookClipIcon.Excluded.addRunning,
            NookClipIcon.Excluded.chooseFinder, NookClipIcon.Excluded.remove,
            NookClipIcon.Status.success, NookClipIcon.Status.error, NookClipIcon.Status.sensitiveSync,
            NookClipIcon.Status.tombstoneSync, NookClipIcon.Status.plaintextNotice,
            NookClipIcon.TCC.trusted, NookClipIcon.TCC.untrusted,
            NookClipIcon.Control.radioSelected, NookClipIcon.Control.checkmark,
            NookClipIcon.Control.keyboard, NookClipIcon.Control.resetHotkey,
            NookClipIcon.Context.copy, NookClipIcon.Context.rename, NookClipIcon.Context.paste,
            NookClipIcon.Context.favorite, NookClipIcon.Context.favoriteFilled, NookClipIcon.Context.delete
        ]

        for token in allTokens {
            XCTAssertFalse(token.isEmpty, "Icon token should not be empty")
        }
    }
}
