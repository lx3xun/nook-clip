import AppKit
import SwiftUI

// MARK: - 鼠标拖拽多选（框选 · 拆自 MainView）
//
// 交互语义（对齐 Finder / 备忘录）：
// - 在列表里按住鼠标上下拖动 → 从按下那一行起、到指针所在行整段选中；
// - 往回拖会同步收窄选区，松手后选区保留，可直接 ⏎ 合并粘贴 / ⌘⌫ 批量删除 / ⌥⏎ 顺序粘贴；
// - 按住 ⇧ 拖拽 → 在已有勾选上追加，不会清掉之前选好的条目；
// - 拖到列表上下边缘之外会自动滚动，一次能选到当前看不到的条目；
// - 位移超过 `DragSelection.minimumDistance` 才算拖拽，单击选中、双击粘贴、
//   滚动、面板整体拖动与缩放都不受影响。
//
// 实现要点：行点击（选中 / 双击粘贴）仍留在行内手势里，本文件的拖拽手势以
// simultaneousGesture 挂在列表滚动视图上，两者同时识别、互不抢占；行命中靠
// RowFramesBox 上报的实时行坐标（nookListColumn 坐标系，与手势坐标同源）。

/// 拖拽期指针纵向位置：边缘自动滚动循环要持续读最新值，
/// 放进 @State 会以帧率触发整树重求值，故用引用容器承载
@MainActor
final class DragPointerBox {
    var y: CGFloat?
}

extension MainView {
    /// 拖拽手势（坐标空间与行坐标同为 nookListColumn）
    var rowDragSelectionGesture: some Gesture {
        DragGesture(minimumDistance: DragSelection.minimumDistance, coordinateSpace: .named("nookListColumn"))
            .onChanged { value in
                handleRowDragChanged(value)
            }
            .onEnded { _ in
                handleRowDragEnded()
            }
    }

    /// 拖拽进行中：首次越过阈值时钉下锚点行，之后按指针纵向位置整段重算选区
    func handleRowDragChanged(_ value: DragGesture.Value) {
        dragPointerBox.y = value.location.y
        let frames = rowFramesBox.snapshot
        if dragSelectionAnchorID == nil {
            // 起点必须落在列表滚动区内**且确实压在某一行上**：
            // 搜索框、底栏、预览区、列表末尾空白处的拖动都不接管，
            // 避免「在空白处按下」也被算成选中了最后一行
            // 行内正在重命名时不接管：会抢走输入框里的拖拽选字
            guard renamingItemID == nil,
                  listScrollAreaFrame.contains(value.startLocation),
                  let anchor = rowID(atY: value.startLocation.y, frames: frames, insideOnly: true) else { return }
            let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // ⇧ 拖拽 = 在既有勾选上追加（单选态下把当前 selectedID 纳入基线）；普通拖拽覆盖原选区
            let currentSelection = listState.selectionIDs.isEmpty
                ? Set([listState.selectedID].compactMap { $0 })
                : listState.selectionIDs
            dragSelectionBaseline = modifiers.contains(.shift) ? currentSelection : []
            dragSelectionAnchorID = anchor
            searchFieldFocused = false
        }
        applyDragSelection(toY: value.location.y)
        updateDragAutoScroll()
    }

    /// 按指针位置把勾选更新为「锚点行 … 指针所在行」整段
    func applyDragSelection(toY y: CGFloat) {
        guard let anchorID = dragSelectionAnchorID,
              let targetID = rowID(atY: y, frames: rowFramesBox.snapshot) else { return }
        listState.selectRange(from: anchorID, to: targetID, addingTo: dragSelectionBaseline)
    }

    /// 拖拽结束：停掉自动滚动、清掉锚点，并短暂屏蔽紧随其后的点击
    /// （松手时系统仍可能补一次单击，放行会把整段选区又收窄回单条）
    func handleRowDragEnded() {
        stopDragAutoScroll()
        dragPointerBox.y = nil
        guard dragSelectionAnchorID != nil else { return }
        dragSelectionAnchorID = nil
        dragSelectionBaseline = []
        dragSelectionEndedAt = Date()
    }

    /// 本次拖拽是否刚刚结束（用于吞掉松手瞬间的那次点击）
    var didJustFinishDragSelection: Bool {
        guard let endedAt = dragSelectionEndedAt else { return false }
        return Date().timeIntervalSince(endedAt) < DragSelection.tapSuppressWindow
    }

    // MARK: 边缘自动滚动（拖到列表上下边缘外时持续滚动，选中范围随之延伸）

    private func updateDragAutoScroll() {
        guard let y = dragPointerBox.y, dragAutoScrollDirection(atY: y) != nil else {
            stopDragAutoScroll()
            return
        }
        guard dragAutoScrollTask == nil else { return }
        dragAutoScrollTask = Task { @MainActor in
            // 滚动游标：记住上一拍滚到的行，每拍**只前进一行**。
            // 不从指针重新推导：scrollTo 带滚动动画，指针在视口外时
            // 「指针最近的一行」会追着动画跑，容易一拍跳好几行，拖快一点就选过头。
            var cursor: Int?
            var direction = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(DragSelection.autoScrollIntervalMs))
                guard !Task.isCancelled, let pointerY = dragPointerBox.y else { break }
                let rows = listState.flatRows
                guard !rows.isEmpty else { break }
                guard let nextDirection = dragAutoScrollDirection(atY: pointerY) else { break }
                // 指针从下边缘甩到上边缘时方向反转，游标作废、以指针位置重新定位
                if nextDirection != direction {
                    direction = nextDirection
                    cursor = nearestRowIndex(atY: pointerY)
                }
                let base = cursor ?? nearestRowIndex(atY: pointerY) ?? (nextDirection > 0 ? -1 : rows.count)
                let next = base + direction
                guard next >= 0, next < rows.count else { break }
                let targetID = rows[next].id
                scrollProxy?.scrollTo(targetID, anchor: .center)
                if let anchorID = dragSelectionAnchorID {
                    listState.selectRange(from: anchorID, to: targetID, addingTo: dragSelectionBaseline)
                }
                cursor = next
            }
            dragAutoScrollTask = nil
        }
    }

    private func stopDragAutoScroll() {
        dragAutoScrollTask?.cancel()
        dragAutoScrollTask = nil
    }

    /// 指针在内容安全区的哪一侧边缘外：-1 = 上边缘、+1 = 下边缘、nil = 中间区域
    private func dragAutoScrollDirection(atY y: CGFloat) -> Int? {
        let bounds = listContentSafeBoundsY
        let margin = DragSelection.autoScrollEdgeMargin
        if y < bounds.top + margin { return -1 }
        if y > bounds.bottom - margin { return 1 }
        return nil
    }

    /// 指针最近的一行在 flatRows 里的下标（拖拽期用；视口外时自然落到首/末可见行）
    private func nearestRowIndex(atY y: CGFloat) -> Int? {
        guard let key = DragSelectionGeometry.rowKey(atY: y, frames: rowFramesBox.snapshot),
              let id = UUID(uuidString: key) else { return nil }
        return listState.flatRows.firstIndex { $0.id == id }
    }

    /// 指针命中的行 id。`insideOnly` = 只认「落在行矩形内」（拖拽起点用）；
    /// 拖拽终点用就近命中，这样拖出列表底边也能一路扩到末行
    private func rowID(atY y: CGFloat, frames: [String: CGRect], insideOnly: Bool = false) -> UUID? {
        if insideOnly {
            // 与 DragSelectionGeometry 一致用半开区间，行接缝处只归属下一行
            return frames.first { $0.value.minY <= y && y < $0.value.maxY }
                .flatMap { UUID(uuidString: $0.key) }
        }
        return DragSelectionGeometry.rowKey(atY: y, frames: frames).flatMap { UUID(uuidString: $0) }
    }
}
