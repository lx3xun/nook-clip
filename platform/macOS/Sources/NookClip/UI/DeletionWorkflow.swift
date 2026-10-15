import SwiftUI

/// 软删除与回收站恢复能力协议（剪贴板/未来笔记/待办 Store 均可接入同一套 10s 撤销流）
@MainActor
protocol SoftDeletableStore: AnyObject {
    func delete(_ id: UUID)
    func deleteMultiple(_ ids: Set<UUID>)
    func restoreFromTrash(_ ids: Set<UUID>)
    func scheduleExpiredTrashPurge()
}

extension InMemoryHistoryStore: SoftDeletableStore {}

/// 删除用户流程：单条/批量软删除、撤销窗口计时与恢复后的选中回落数据。
/// toast 渲染留在 View；窗口状态（待撤销集合、截止时间）与超时清理调度在此。
@MainActor
@Observable
final class DeletionWorkflow {
    /// 撤销 toast 展示时长（秒）；过期后软删除条目再活
    /// TrashPurgeWindow.grace 即彻底清除（须小于该宽限）
    static let undoWindow: TimeInterval = 10

    private let store: any SoftDeletableStore

    /// 待撤销的软删除 id（撤销窗口内累计；窗口关闭后清空并安排兜底清除）
    private(set) var pendingUndoIDs: Set<UUID> = []
    /// 撤销窗口截止时间（倒计时进度条数据源；窗口重开时更新）
    private(set) var undoToastDeadline: Date = .distantPast

    @ObservationIgnored private var undoToastTask: Task<Void, Never>?

    init(store: any SoftDeletableStore) {
        self.store = store
    }

    /// 删除统一入口：软删除后进入撤销窗口（toast 按钮 / ⌘Z 可整体撤销）
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if ids.count == 1, let only = ids.first {
            store.delete(only)
        } else {
            store.deleteMultiple(ids)
        }
        openUndoWindow(ids: ids)
    }

    /// 记录待撤销删除并（重）开撤销窗口：窗口内的新删除累计进同一批撤销
    func openUndoWindow(ids: Set<UUID>) {
        withAnimation(.easeOut(duration: 0.15)) {
            pendingUndoIDs.formUnion(ids)
        }
        undoToastTask?.cancel()
        undoToastDeadline = Date().addingTimeInterval(Self.undoWindow)
        undoToastTask = Task {
            try? await Task.sleep(for: .seconds(Self.undoWindow))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                pendingUndoIDs.removeAll()
            }
            // 撤销窗口关闭：软删除条目再保留兜底宽限后由 Store 彻底清除
            store.scheduleExpiredTrashPurge()
        }
    }

    /// 撤销最近一次删除（toast 按钮 / ⌘Z）。
    /// 返回被恢复的 id 集合：调用方据此把选中回落到恢复条目（列表顶部）——
    /// 不更新时选中停留在删除时的补位项，违背「恢复后选中回落到恢复条目」
    /// 的契约（审计 BUG-049）。
    func undoDelete() -> Set<UUID>? {
        guard !pendingUndoIDs.isEmpty else { return nil }
        undoToastTask?.cancel()
        undoToastTask = nil
        let ids = pendingUndoIDs
        withAnimation(.easeIn(duration: 0.15)) {
            pendingUndoIDs.removeAll()
        }
        store.restoreFromTrash(ids)
        return ids
    }
}
