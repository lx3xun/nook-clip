import AppKit
import SwiftUI

// MARK: - 现代化悬浮滚动条 (Force Overlay Scroller)

/// 强制限定为 macOS 现代悬浮风格的 NSScroller：
/// 1. 彻底隐藏灰色凹槽背景 (drawKnobSlot 为空)
/// 2. 宽度锁定为 3~4px 微型胶囊 (controlSize = .small)
/// 3. 仅在滚动时浮现，静止时自动淡出消失 (scrollerStyle = .overlay, autohidesScrollers = true)
final class ForceOverlayScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool {
        return true
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.controlSize = .small
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.controlSize = .small
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // 彻底隐藏任何轨道与背景槽位，实现 100% 透明悬浮
    }
}

// MARK: - AppKit 全局滚动条拦截

extension NSScrollView {
    private static var hasSwizzled = false

    /// 在应用启动时调用，强制全应用所有滚动条使用现代 .overlay 悬浮风格，隐藏灰色槽道
    @MainActor
    static func enableOverlayScrollersGlobally() {
        guard !hasSwizzled else { return }
        hasSwizzled = true

        let originalSelector = #selector(tile)
        let swizzledSelector = #selector(nookclip_tile)
        guard let originalMethod = class_getInstanceMethod(NSScrollView.self, originalSelector),
              let swizzledMethod = class_getInstanceMethod(NSScrollView.self, swizzledSelector) else { return }
        method_exchangeImplementations(originalMethod, swizzledMethod)
    }

    @objc private func nookclip_tile() {
        if !(self is CodeScrollView) {
            self.scrollerStyle = .overlay
            self.autohidesScrollers = true
            if self.hasVerticalScroller, !(self.verticalScroller is ForceOverlayScroller) {
                let scroller = ForceOverlayScroller()
                scroller.controlSize = .small
                self.verticalScroller = scroller
            }
            if self.hasHorizontalScroller, !(self.horizontalScroller is ForceOverlayScroller) {
                let scroller = ForceOverlayScroller()
                scroller.controlSize = .small
                self.horizontalScroller = scroller
            }
        }
        self.nookclip_tile()
    }
}

