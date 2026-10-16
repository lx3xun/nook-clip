import AppKit
import SwiftUI

// MARK: - Tab 2: 历史与同步 (History & Sync) —— 存多久、放哪里

@MainActor
struct HistorySettingsTab: View {
    var historyStore: InMemoryHistoryStore?
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 30
    @AppStorage("historyDiskLimitMB") private var historyDiskLimitMB = 0
    @AppStorage("enableICloudSync") private var enableICloudSync = false
    @State private var showClearConfirmation = false
    @State private var isSyncingManual = false
    @State private var syncStatusMessage: String?
    @State private var syncStatusIsError = false
    @State private var backupStatusMessage: String?
    @State private var backupStatusIsError: Bool = false
    @State private var exportMode: SensitiveExportMode = .masked
    @State private var showPlaintextExportConfirm = false
    @State private var pendingPlaintextExport: (asJSON: Bool, mode: SensitiveExportMode)?

    var body: some View {
        VStack(spacing: 16) {
            // 历史记录保留与存储限制
            SettingsSectionView(title: L10n.tr("settings.history.management")) {
                if let store = historyStore {
                    SettingsRowView(title: L10n.tr("settings.history.stats"), showDivider: true) {

                        HStack(spacing: 8) {
                            statBadge(
                                icon: NookClipIcon.Status.tray,
                                text: L10n.tr("clipboard.items_count", store.totalCount),
                                color: NookClip.accent,
                                background: NookClip.bgAccentSubtle
                            )

                            statBadge(
                                icon: NookClipIcon.Action.favoriteFilled,
                                text: L10n.tr("settings.history.favorite_count", store.favoriteCount),
                                color: NookClip.colorFavorite,
                                background: NookClip.bgFavoriteActive
                            )
                        }
                    }
                }
                SettingsRowView(title: L10n.tr("settings.general.history_retention"), showDivider: true) {

                    Picker("", selection: $historyRetentionDays) {
                        Text(L10n.tr("settings.retention.day")).tag(1)
                        Text(L10n.tr("settings.retention.week")).tag(7)
                        Text(L10n.tr("settings.retention.month")).tag(30)
                        Text(L10n.tr("settings.retention.quarter")).tag(90)
                        Text(L10n.tr("settings.retention.half_year")).tag(180)
                        Text(L10n.tr("settings.retention.year")).tag(365)
                        Text(L10n.tr("settings.retention.unlimited")).tag(0)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: historyRetentionDays) { _, days in
                        historyStore?.pruneExpiredItems(days: days)
                    }
                }

                SettingsRowView(title: L10n.tr("settings.general.disk_limit"), showDivider: true) {

                    Picker("", selection: $historyDiskLimitMB) {
                        Text(L10n.tr("settings.retention.unlimited")).tag(0)
                        ForEach([512, 1024, 2048, 3072, 4096, 5120, 10240, 20480, 30720, 40960, 51200], id: \.self) { mb in
                            Text(Self.diskLimitLabel(mb)).tag(mb)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: historyDiskLimitMB) { _, _ in
                        historyStore?.enforceDiskLimit()
                    }
                }

                SettingsRowView(
                    title: L10n.tr("settings.history.clear_unflagged"),
                    subtitle: L10n.tr("settings.history.clear_unflagged_desc")
                ) {

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Text(L10n.tr("settings.history.clear_unflagged_button"))
                    }
                    .disabled((historyStore?.unflaggedCount ?? 0) == 0)
                }
            }

            // iCloud Drive 同步
            SettingsSectionView(title: L10n.tr("settings.sync.section")) {
                SettingsRowView(
                    title: L10n.tr("settings.sync.enable"),
                    subtitle: L10n.tr("settings.sync.enable_desc"),
                    showDivider: enableICloudSync
                ) {

                    Toggle("", isOn: $enableICloudSync)
                        .toggleStyle(.nookSwitch)
                        .labelsHidden()
                        .onChange(of: enableICloudSync) { _, enabled in
                            historyStore?.syncEngine.isEnabled = enabled
                            if enabled {
                                Task {
                                    await historyStore?.syncNow()
                                }
                            }
                        }
                }
                if enableICloudSync {
                    SettingsRowView(showDivider: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("settings.sync.dir_label"))
                                .font(.nookClipBody)
                                .foregroundStyle(NookClip.textPrimary)
                            Text(historyStore?.syncEngine.baseDirectoryURL.path ?? "iCloud Drive/NookClip")
                                .font(.nookClipMeta)
                                .foregroundStyle(NookClip.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } trailing: {
                        Button(L10n.tr("settings.sync.change_dir")) {
                            chooseCustomSyncDirectory()
                        }
                        .buttonStyle(.bordered)
                    }
                    SettingsRowView(showDivider: syncStatusMessage != nil) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("settings.sync.status_label"))
                                .font(.nookClipBody)
                                .foregroundStyle(NookClip.textPrimary)
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(syncStatusColor)
                                    .frame(width: 8, height: 8)
                                Text(syncStatusText)
                                    .font(.nookClipMeta)
                                    .foregroundStyle(NookClip.textSecondary)
                            }
                        }
                    } trailing: {
                        Button(isSyncingManual ? L10n.tr("settings.sync.btn_syncing") : L10n.tr("settings.sync.btn_sync_now")) {
                            triggerManualSync()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSyncingManual)
                    }
                    if let message = syncStatusMessage {
                        SettingsRowView(showDivider: true) {
                            HStack {
                                Text(message)
                                    .font(.nookClipMeta)
                                    .foregroundStyle(syncStatusIsError ? NookClip.colorDanger : NookClip.colorSuccess)
                                Spacer()
                            }
                        } trailing: { EmptyView() }
                    }
                    if historyStore?.lastSyncResult.outcome != .idle {
                        // 最近同步结果（FR-011b）：与同步状态同卡片展示，避免状态信息分裂
                        SettingsRowView(showDivider: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("settings.sync.last_result_label"))
                                    .font(.nookClipBody)
                                    .foregroundStyle(NookClip.textPrimary)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(lastSyncResultColor)
                                        .frame(width: 8, height: 8)
                                    Text(lastSyncResultText)
                                        .font(.nookClipMeta)
                                        .foregroundStyle(NookClip.textSecondary)
                                }
                            }
                        } trailing: { EmptyView() }
                    }
                    // 披露文案：iCloud 同步内容为明文，敏感条目不上云（FR-023）
                    HStack(spacing: 5) {
                        Image(systemName: NookClipIcon.Status.plaintextNotice)
                            .foregroundStyle(NookClip.textSecondary)
                        Text(L10n.tr("settings.sync.plaintext_disclosure"))
                            .font(.nookClipMeta)
                            .foregroundStyle(NookClip.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            // 同步规则说明
            if enableICloudSync {
                SettingsSectionView(title: L10n.tr("settings.sync.rules_section")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.tr("settings.sync.rule_realtime"), systemImage: NookClipIcon.Status.success)
                            .foregroundStyle(NookClip.textSecondary)
                            .font(.nookClipMeta)
                        Label(L10n.tr("settings.sync.rule_assets"), systemImage: NookClipIcon.Status.success)
                            .foregroundStyle(NookClip.textSecondary)
                            .font(.nookClipMeta)
                        Label(L10n.tr("settings.sync.rule_sensitive"), systemImage: NookClipIcon.Status.sensitiveSync)
                            .foregroundStyle(NookClip.textSecondary)
                            .font(.nookClipMeta)
                        Label(L10n.tr("settings.sync.rule_tombstone"), systemImage: NookClipIcon.Status.tombstoneSync)
                            .foregroundStyle(NookClip.textSecondary)
                            .font(.nookClipMeta)
                    }
                    .padding(14)
                }
            }

            // 本地数据备份与恢复
            SettingsSectionView(title: L10n.tr("settings.general.backup_section")) {
                SettingsRowView(title: L10n.tr("settings.export.mode_label"), showDivider: true) {
                    Picker("", selection: $exportMode) {
                        Text(L10n.tr("settings.export.mode_exclude")).tag(SensitiveExportMode.exclude)
                        Text(L10n.tr("settings.export.mode_masked")).tag(SensitiveExportMode.masked)
                        Text(L10n.tr("settings.export.mode_plaintext")).tag(SensitiveExportMode.plaintext)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRowView(title: L10n.tr("settings.general.export_backup"), showDivider: true) {

                    // T042⑤：按钮文案补三语 L10n（原先硬编码英文）
                    Menu(L10n.tr("settings.general.export_backup")) {
                        Button(L10n.tr("settings.general.export_json")) {
                            exportBackup(asJSON: true, mode: exportMode)
                        }
                        Button(L10n.tr("settings.general.export_markdown")) {
                            exportBackup(asJSON: false, mode: exportMode)
                        }
                    }
                    .disabled((historyStore?.totalCount ?? 0) == 0)
                }
                SettingsRowView(title: L10n.tr("settings.general.import_backup"), showDivider: true) {
                    Button(L10n.tr("settings.general.import_backup")) {
                        importBackup()
                    }
                }
                SettingsRowView(title: L10n.tr("settings.general.restore_demo"), showDivider: backupStatusMessage != nil) {
                    Button(L10n.tr("settings.general.restore_demo_button")) {
                        historyStore?.seedDemoItemsIfNeeded(force: true)
                        backupStatusMessage = L10n.tr("settings.general.restore_demo_success")
                        backupStatusIsError = false
                    }
                }
                if let status = backupStatusMessage {
                    HStack(spacing: 5) {
                        Image(systemName: backupStatusIsError ? NookClipIcon.Status.error : NookClipIcon.Status.success)
                            .foregroundStyle(backupStatusIsError ? NookClip.colorDanger : NookClip.colorSuccess)
                        Text(status)
                            .font(.nookClipMeta)
                            .foregroundStyle(backupStatusIsError ? NookClip.colorDanger : NookClip.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }
            }
        }
        .confirmationDialog(
            L10n.tr("settings.general.clear_confirm_title"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("settings.general.clear_button"), role: .destructive) {
                historyStore?.clearHistory(keepFavorites: true)
            }
            Button(L10n.tr("settings.general.cancel_button"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.general.clear_confirm_desc"))
        }
        .alert(
            L10n.tr("settings.export.plaintext_confirm_title"),
            isPresented: $showPlaintextExportConfirm
        ) {
            Button(L10n.tr("settings.export.plaintext_confirm_ok"), role: .destructive) {
                if let pending = pendingPlaintextExport {
                    pendingPlaintextExport = nil
                    runExport(asJSON: pending.asJSON, mode: pending.mode)
                }
            }
            Button(L10n.tr("settings.general.cancel_button"), role: .cancel) {
                pendingPlaintextExport = nil
            }
        } message: {
            Text(L10n.tr("settings.export.plaintext_confirm_message"))
        }
    }

    @ViewBuilder
    private func statBadge(icon: String, text: String, color: Color, background: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: NookClipIconSize.micro, weight: .semibold))
            Text(text)
                .font(.nookClipRounded(11, .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(background, in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 0.5))
    }

    private static func diskLimitLabel(_ mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    private var syncStatusColor: Color {
        guard let engine = historyStore?.syncEngine else { return NookClip.textTertiary }
        switch engine.state {
        case .idle: return NookClip.textTertiary
        case .syncing: return NookClip.accent
        case .success: return NookClip.colorSuccess
        case .failed: return NookClip.colorDanger
        }
    }

    /// 最近同步结果颜色（FR-011b；SyncResult.outcome → 状态点）
    private var lastSyncResultColor: Color {
        switch historyStore?.lastSyncResult.outcome {
        case .success: return NookClip.colorSuccess
        case .failure: return NookClip.colorDanger
        default: return NookClip.textTertiary
        }
    }

    /// 最近同步结果文案（FR-011b；成功/失败时间走 LocalizationManager.relativeTime）
    private var lastSyncResultText: String {
        guard let store = historyStore else { return L10n.tr("settings.sync.status_not_enabled") }
        switch store.lastSyncResult.outcome {
        case .idle:
            return L10n.tr("settings.sync.last_result_idle")
        case .success(let date):
            return L10n.tr("settings.sync.last_result_success", L10n.relativeTime(for: date))
        case .failure(let reason, let date):
            let reasonKey: String
            switch reason {
            case .network: reasonKey = "settings.sync.last_result_failure_network"
            case .credential: reasonKey = "settings.sync.last_result_failure_credential"
            case .unknown: reasonKey = "settings.sync.last_result_failure_unknown"
            }
            return L10n.tr(reasonKey, L10n.relativeTime(for: date))
        }
    }

    private var syncStatusText: String {
        guard let engine = historyStore?.syncEngine else { return L10n.tr("settings.sync.status_not_enabled") }
        switch engine.state {
        case .idle:
            if let date = engine.lastSyncDate {
                return L10n.tr("settings.sync.status_success", date.formatted(date: .omitted, time: .standard))
            }
            return L10n.tr("settings.sync.status_idle")
        case .syncing:
            return L10n.tr("settings.sync.status_syncing")
        case .success(let date):
            return L10n.tr("settings.sync.status_success", date.formatted(date: .omitted, time: .standard))
        case .failed(let msg):
            return L10n.tr("settings.sync.status_error", msg)
        }
    }

    private func triggerManualSync() {
        guard let store = historyStore else { return }
        isSyncingManual = true
        syncStatusMessage = nil
        Task {
            await store.syncNow()
            await MainActor.run {
                isSyncingManual = false
                // syncNow 只更新 lastSyncResult（不改 syncEngine.state），
                // 误查 state 会让失败被吞、界面谎报「同步完成」
                switch store.lastSyncResult.outcome {
                case .failure(let reason, _):
                    syncStatusIsError = true
                    syncStatusMessage = L10n.tr("settings.sync.msg_failed", reason.localizedDescription)
                default:
                    syncStatusIsError = false
                    syncStatusMessage = L10n.tr("settings.sync.msg_done")
                }
            }
        }
    }

    private func chooseCustomSyncDirectory() {
        let openPanel = NSOpenPanel()
        openPanel.title = L10n.tr("settings.sync.panel_title")
        openPanel.prompt = L10n.tr("settings.sync.panel_prompt")
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let selectedURL = openPanel.url {
            do {
                try historyStore?.syncEngine.setCustomDirectory(url: selectedURL)
                syncStatusIsError = false
                syncStatusMessage = L10n.tr("settings.sync.dir_switched")
                Task {
                    await historyStore?.syncNow()
                }
            } catch {
                syncStatusIsError = true
                syncStatusMessage = L10n.tr("settings.sync.dir_failed", error.localizedDescription)
            }
        }
    }

    /// FR-006：导出前选择敏感模式；明文模式必须经确认弹窗（explicit safety confirmation）
    private func exportBackup(asJSON: Bool, mode: SensitiveExportMode) {
        if mode == .plaintext {
            pendingPlaintextExport = (asJSON, mode)
            showPlaintextExportConfirm = true
            return
        }
        runExport(asJSON: asJSON, mode: mode)
    }

    private func runExport(asJSON: Bool, mode: SensitiveExportMode) {
        guard let store = historyStore else { return }
        let savePanel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateStr = formatter.string(from: Date())
        savePanel.canCreateDirectories = true
        if asJSON {
            savePanel.nameFieldStringValue = "NookClip_Backup_\(dateStr).json"
            savePanel.allowedContentTypes = [.json]
        } else {
            savePanel.nameFieldStringValue = "NookClip_Export_\(dateStr).md"
            savePanel.allowedContentTypes = [.plainText]
        }

        savePanel.begin { @MainActor response in
            guard response == .OK, let targetURL = savePanel.url else { return }
            do {
                if asJSON {
                    let data = try store.exportToJSON(mode: mode)
                    try data.write(to: targetURL, options: .atomic)
                } else {
                    let md = try store.exportToMarkdown(mode: mode)
                    try md.write(to: targetURL, atomically: true, encoding: .utf8)
                }
                withAnimation {
                    backupStatusIsError = false
                    backupStatusMessage = L10n.tr("settings.backup.exported_success", store.totalCount, targetURL.lastPathComponent)
                }
            } catch {
                withAnimation {
                    backupStatusIsError = true
                    backupStatusMessage = L10n.tr("settings.backup.export_failed", error.localizedDescription)
                }
            }
        }
    }

    private func importBackup() {
        guard let store = historyStore else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = [.json]

        openPanel.begin { @MainActor response in
            guard response == .OK, let fileURL = openPanel.url else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                let importedCount = try store.importFromJSON(data)
                withAnimation {
                    backupStatusIsError = false
                    backupStatusMessage = L10n.tr("settings.backup.imported_success", importedCount)
                }
            } catch {
                withAnimation {
                    backupStatusIsError = true
                    backupStatusMessage = L10n.tr("settings.backup.import_failed", error.localizedDescription)
                }
            }
        }
    }
}
