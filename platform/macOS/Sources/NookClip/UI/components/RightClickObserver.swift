import AppKit
import SwiftUI

/// 右键按下观察器：在 contextMenu 弹出前先回调（super 传递事件，菜单照常弹出）。
/// 用于右键选择同步——右键点在选区外先把该行设为选中（Finder 语义），
/// 菜单动作恒作用于当前选区
struct RightClickObserver: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.handler = onRightClick
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? ObserverView)?.handler = onRightClick
    }

    private final class ObserverView: NSView {
        var handler: (() -> Void)?

        override func rightMouseDown(with event: NSEvent) {
            handler?()
            super.rightMouseDown(with: event)
        }
    }
}
