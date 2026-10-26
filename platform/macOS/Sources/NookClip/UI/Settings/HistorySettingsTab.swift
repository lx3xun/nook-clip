import AppKit
import SwiftUI

// MARK: - Tab 2: 历史与同步 (History & Sync) —— 存多久、放哪里

@MainActor
struct HistorySettingsTab: View {
    var historyStore: InMemoryHistoryStore?
    @AppStorage("historyMaxItemCount") private var historyMaxItemCount = HistoryMaxItemsPolicy.defaultMaxItems
    @AppStorage("historyDiskLimitMB") private var historyDiskLimitMB = DiskLimitPolicy.defaultLimitMB
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
    @State private var syncMode: CloudSyncMode = .iCloudDrive
    @State private var webDavUrl: String = ""
    @State private var webDavUsername: String = ""
    @State private var webDavPassword: String = ""
    @State private var showWebDavPassword: Bool = false
    @State private var isTestingWebDav = false
    @State private var webDavTestResult: (success: Bool, message: String)?
    @State private var isE2EEEnabled: Bool = false
    @State private var e2eePassphrase: String = ""
    @State private var showE2eePassphrase: Bool = false
    @State private var showResetPassphraseAlert: Bool = false
    @State private var isResettingPassphrase: Bool = false
    @State private var syncSensitiveItems: Bool = false
    /// 首次启用 E2EE 后的一次性询问：是否把敏感条目也纳入端到端加密同步
    @State private var showSensitiveSyncPrompt = false
    /// 与 `ICloudDriveSyncEngine.isE2EESensitiveSyncActive` 同源的「当前是否真正加密同步敏感条目」判定，
    /// 供同步规则文案与引导使用（避免只勾了 E2EE 但无口令时仍显示「受加密保护」）
    private var isSensitiveSyncActive: Bool {
        let hasPass = !e2eePassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return isE2EEEnabled && hasPass && syncSensitiveItems
    }
    var body: some View {
        SettingsPage(
            title: L10n.tr("settings.tab.history"),
            subtitle: L10n.tr("settings.subtitle.history"),
            status: [
                (L10n.tr("settings.status.records"), "\(historyStore?.totalCount ?? 0)"),
                (L10n.tr("settings.status.favorites"), "\(historyStore?.favoriteCount ?? 0)"),
                (L10n.tr("settings.status.sync"), L10n.stateWord(enableICloudSync)),
            ]
        ) {
            // 1. 历史记录保留与存储限制
            SettingsFoldGroup(
                index: 0,
                title: L10n.tr("settings.history.management"),
                // 摘要要读起来像「这一组现在的状态」而不是一个标签：
                // 条数上限 + 磁盘上限，两个都是会变的值，所以都放在这里
                summary: L10n.tr("clipboard.items_count", HistoryMaxItemsPolicy.clamp(historyMaxItemCount))
                    + " · " + Self.diskLimitLabel(historyDiskLimitMB)
            ) {
                if let store = historyStore {
                    SettingsRow(title: L10n.tr("settings.history.stats"), showDivider: true) {
                        HStack(spacing: 8) {
                            statBadge(
                                icon: NookClipIcon.Status.tray,
                                text: L10n.tr("clipboard.items_count", store.totalCount)
                            )

                            statBadge(
                                icon: NookClipIcon.Action.favoriteFilled,
                                text: L10n.tr("settings.history.favorite_count", store.favoriteCount)
                            )
                        }
                    }
                }
                SettingsRow(title: L10n.tr("settings.general.history_max_items"), showDivider: true) {
                    Picker("", selection: $historyMaxItemCount) {
                        ForEach(HistoryMaxItemsPolicy.presets, id: \.self) { count in
                            Text(L10n.tr("clipboard.items_count", count)).tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: historyMaxItemCount) { _, count in
                        // 「无限制」已退役：越界值（旧版 0/超上限）收敛后再写回并裁剪
                        let limit = HistoryMaxItemsPolicy.clamp(count)
                        if limit != count { historyMaxItemCount = limit }
                        historyStore?.pruneToMaxItems(limit)
                    }
                }

                SettingsRow(title: L10n.tr("settings.general.disk_limit"), showDivider: true) {
                    Picker("", selection: $historyDiskLimitMB) {
                        ForEach(DiskLimitPolicy.presets, id: \.self) { mb in
                            Text(Self.diskLimitLabel(mb)).tag(mb)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: historyDiskLimitMB) { _, mb in
                        // 「无限制」已退役：越界值（旧版 0/超上限）收敛后再写回并触发淘汰
                        let limit = DiskLimitPolicy.clamp(mb)
                        if limit != mb { historyDiskLimitMB = limit }
                        historyStore?.enforceDiskLimit()
                    }
                }

                SettingsRow(
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

            // 2. iCloud 同步
            SettingsFoldGroup(
                index: 1,
                title: L10n.tr("settings.sync.section"),
                summary: L10n.stateWord(enableICloudSync)
            ) {
                SettingsRow(
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
                    // 同步通道选择：当前只开放 iCloud（本地目录映射 / WebDAV 入口暂时关闭）。
                    // 只剩一个可选通道时不再渲染下拉菜单（菜单里只有一项没有意义），
                    // 改为只读展示当前通道；重新放开时把 case 加回
                    // CloudSyncMode.userSelectableModes，这里会自动恢复成 Picker。
                    if CloudSyncMode.userSelectableModes.count > 1 {
                        SettingsRow(title: L10n.tr("settings.sync.mode_label"), showDivider: true) {
                            Picker("", selection: $syncMode) {
                                ForEach(CloudSyncMode.userSelectableModes) { mode in
                                    Text(Self.syncModeLabel(mode)).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 320)
                            .onChange(of: syncMode) { _, newMode in
                                guard let engine = historyStore?.syncEngine else { return }
                                engine.syncMode = newMode
                                // 切换同步方式时，按需载入对应通道专属的配置（未开启加密或非 WebDAV 时不触碰 Keychain）
                                isE2EEEnabled = engine.isE2EEEnabled
                                e2eePassphrase = isE2EEEnabled ? engine.e2eePassphrase : ""
                                syncSensitiveItems = engine.syncSensitiveItems
                                if newMode == .webdav {
                                    webDavPassword = engine.webDavPassword
                                }
                            }
                        }
                    } else {
                        SettingsRow(title: L10n.tr("settings.sync.mode_label"), showDivider: true) {
                            Text(Self.syncModeLabel(syncMode))
                                .font(.nookClipBody)
                                .foregroundStyle(NookClip.textSecondary)
                                .frame(width: 320, alignment: .trailing)
                        }
                    }

                    // 本地目录映射模式配置（仅本地目录映射需要指定与修改本地路径）。
                    // 当前版本该通道不在 userSelectableModes 内，syncMode 恒为 iCloud，
                    // 这段 UI 因此不可达；保留它是为了重新放开时无需重写（引擎侧能力与
                    // 配置读写都还在），并且仍然参与编译检查，不会悄悄腐坏。
                    if syncMode == .localDirectory {
                        SettingsRow(showDivider: true) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.tr("settings.sync.dir_label"))
                                    .font(.nookClipBody)
                                    .foregroundStyle(NookClip.textPrimary)
                                Text(historyStore?.syncEngine.baseDirectoryURL.path ?? "Documents/NookClipSync")
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
                    }

                    // WebDAV 模式配置（地址 / 用户名 / 口令 / 连通性测试）。
                    // 与上一段同理：该通道当前不在 userSelectableModes 内，这段不可达，
                    // 保留是为了重新放开时配置项与测试按钮都还在。
                    if syncMode == .webdav {
                        SettingsRow(title: L10n.tr("settings.sync.webdav_url"), showDivider: true) {
                            TextField("https://...", text: $webDavUrl)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .onChange(of: webDavUrl) { _, val in
                                    webDavTestResult = nil
                                    historyStore?.syncEngine.webDavURL = val
                                    if historyStore?.syncEngine.isEnabled == true && syncMode == .webdav {
                                        historyStore?.syncEngine.setupSyncTriggers()
                                    }
                                }
                        }
                        SettingsRow(title: L10n.tr("settings.sync.webdav_username"), showDivider: true) {
                            TextField("Username", text: $webDavUsername)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .onChange(of: webDavUsername) { _, val in
                                    webDavTestResult = nil
                                    historyStore?.syncEngine.webDavUsername = val
                                }
                        }
                        SettingsRow(title: L10n.tr("settings.sync.webdav_password"), showDivider: true) {
                            SettingsPasswordField(
                                placeholder: "Password",
                                text: $webDavPassword,
                                isRevealed: $showWebDavPassword,
                                width: 260
                            ) { val in
                                webDavTestResult = nil
                                historyStore?.syncEngine.webDavPassword = val
                            }
                        }
                        SettingsRow(showDivider: true) {
                            if let res = webDavTestResult {
                                Text(res.message)
                                    .font(.nookClipMeta)
                                    .foregroundStyle(res.success ? NookClip.colorSuccess : NookClip.colorDanger)
                            } else {
                                Spacer()
                            }
                        } trailing: {
                            Button(isTestingWebDav ? L10n.tr("settings.sync.btn_syncing") : L10n.tr("settings.sync.btn_test_conn")) {
                                testWebDav()
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingWebDav || webDavUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    // 端到端加密 (E2EE)
                    SettingsRow(
                        title: L10n.tr("settings.sync.e2ee_title"),
                        subtitle: L10n.tr("settings.sync.e2ee_desc"),
                        showDivider: true
                    ) {
                        Toggle("", isOn: $isE2EEEnabled)
                            .toggleStyle(.nookSwitch)
                            .labelsHidden()
                            .onChange(of: isE2EEEnabled) { _, enabled in
                                historyStore?.syncEngine.isE2EEEnabled = enabled
                                if enabled, let engine = historyStore?.syncEngine {
                                    e2eePassphrase = engine.e2eePassphrase
                                    syncSensitiveItems = engine.syncSensitiveItems
                                    // 仅在整个账号生命周期首次开启 E2EE 时询问一次；
                                    // 已决策过的通道不再打扰，用户可随时在本页 Toggle 中修改。
                                    if !engine.hasDecidedSensitiveSync(for: engine.syncMode) {
                                        showSensitiveSyncPrompt = true
                                    }
                                }
                            }
                    }
                    .alert(
                        L10n.tr("settings.sync.sensitive_prompt_title"),
                        isPresented: $showSensitiveSyncPrompt
                    ) {
                        Button(L10n.tr("settings.sync.sensitive_prompt_enable")) {
                            guard let engine = historyStore?.syncEngine else { return }
                            syncSensitiveItems = true
                            engine.syncSensitiveItems = true
                            engine.markSensitiveSyncDecided(for: engine.syncMode)
                        }
                        Button(L10n.tr("settings.sync.sensitive_prompt_keep_local"), role: .cancel) {
                            guard let engine = historyStore?.syncEngine else { return }
                            // 显式选择「仅本机」也算完成决策：保持安全默认，记录后不再重复询问
                            syncSensitiveItems = false
                            engine.syncSensitiveItems = false
                            engine.markSensitiveSyncDecided(for: engine.syncMode)
                        }
                    } message: {
                        Text(L10n.tr("settings.sync.sensitive_prompt_message"))
                    }

                    if isE2EEEnabled {
                        SettingsRow(
                            title: L10n.tr("settings.sync.e2ee_passphrase"),
                            subtitle: L10n.tr("settings.sync.e2ee_passphrase_desc"),
                            showDivider: true
                        ) {
                            SettingsPasswordField(
                                placeholder: L10n.tr("settings.sync.e2ee_passphrase_placeholder"),
                                text: $e2eePassphrase,
                                isRevealed: $showE2eePassphrase,
                                width: 260
                            ) { val in
                                historyStore?.syncEngine.e2eePassphrase = val
                            }
                        }

                        SettingsRow(
                            title: L10n.tr("settings.sync.e2ee_reset_title"),
                            subtitle: L10n.tr("settings.sync.e2ee_reset_subtitle"),
                            showDivider: true
                        ) {
                            Button(isResettingPassphrase ? L10n.tr("settings.sync.btn_syncing") : L10n.tr("settings.sync.e2ee_reset_btn")) {
                                showResetPassphraseAlert = true
                            }
                            .buttonStyle(.bordered)
                            .disabled(isResettingPassphrase || e2eePassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        SettingsRow(
                            title: L10n.tr("settings.sync.e2ee_sync_sensitive"),
                            subtitle: L10n.tr("settings.sync.e2ee_sync_sensitive_desc"),
                            showDivider: true
                        ) {
                            Toggle("", isOn: $syncSensitiveItems)
                                .toggleStyle(.nookSwitch)
                                .labelsHidden()
                                .onChange(of: syncSensitiveItems) { _, enabled in
                                    historyStore?.syncEngine.syncSensitiveItems = enabled
                                }
                        }
                    }
                    SettingsRow(showDivider: syncStatusMessage != nil) {
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
                        SettingsRow(showDivider: true) {
                            HStack {
                                Text(message)
                                    .font(.nookClipMeta)
                                    .foregroundStyle(syncStatusIsError ? NookClip.colorDanger : NookClip.colorSuccess)
                                Spacer()
                            }
                        } trailing: { EmptyView() }
                    }
                }
            }

            // 3. 同步规则说明（仅在开启同步后出现）
            if enableICloudSync {
                SettingsFoldGroup(
                    index: 2,
                    title: L10n.tr("settings.sync.rules_section"),
                    summary: L10n.tr("settings.sync.e2ee_title") + " · " + L10n.stateWord(isE2EEEnabled)
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        // 未开启 E2EE 时走的是 iCloud 自带加密（传输与存储均已加密），
                        // 属于正常的默认状态而非警告，因此两种状态都用中性色与锁图标。
                        Label(
                            L10n.tr(isE2EEEnabled ? "settings.sync.rule_e2ee_on" : "settings.sync.rule_e2ee_off"),
                            systemImage: isE2EEEnabled ? NookClipIcon.Sensitive.shieldOk : NookClipIcon.Sensitive.lock
                        )
                        .foregroundStyle(NookClip.textSecondary)
                        .font(.nookClipMeta)

                        Label(
                            L10n.tr(isSensitiveSyncActive ? "settings.sync.rule_sensitive_on" : "settings.sync.rule_sensitive_off"),
                            systemImage: isSensitiveSyncActive ? NookClipIcon.Sensitive.lock : NookClipIcon.Status.sensitiveSync
                        )
                        .foregroundStyle(NookClip.textSecondary)
                        .font(.nookClipMeta)

                        Label(
                            L10n.tr("settings.sync.rule_assets_and_delete"),
                            systemImage: NookClipIcon.Status.success
                        )
                        .foregroundStyle(NookClip.textSecondary)
                        .font(.nookClipMeta)
                    }
                    .padding(14)
                }
            }

            // 4. 本地数据备份与恢复
            SettingsFoldGroup(
                index: 3,
                title: L10n.tr("settings.general.backup_section"),
                summary: Self.exportModeLabel(exportMode)
            ) {
                SettingsRow(title: L10n.tr("settings.export.mode_label"), showDivider: true) {
                    Picker("", selection: $exportMode) {
                        Text(L10n.tr("settings.export.mode_exclude")).tag(SensitiveExportMode.exclude)
                        Text(L10n.tr("settings.export.mode_masked")).tag(SensitiveExportMode.masked)
                        Text(L10n.tr("settings.export.mode_plaintext")).tag(SensitiveExportMode.plaintext)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 180)
                }
                SettingsRow(title: L10n.tr("settings.general.export_backup"), showDivider: true) {
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
                SettingsRow(title: L10n.tr("settings.general.import_backup"), showDivider: true) {
                    Button(L10n.tr("settings.general.import_backup")) {
                        importBackup()
                    }
                }
                SettingsRow(title: L10n.tr("settings.general.restore_demo"), showDivider: backupStatusMessage != nil) {
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
                // 清空历史是阻塞型大批量删除（万级历史约数十毫秒 + 整页重查），
                // 放到后台任务执行，避免设置面板卡顿。
                Task { await historyStore?.clearHistoryInBackground(keepFavorites: true) }
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
        .alert(
            L10n.tr("settings.sync.e2ee_reset_confirm_title"),
            isPresented: $showResetPassphraseAlert
        ) {
            Button(L10n.tr("settings.sync.e2ee_reset_confirm_action"), role: .destructive) {
                performResetPassphrase()
            }
            Button(L10n.tr("settings.general.cancel_button"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.sync.e2ee_reset_confirm_desc"))
        }
        .onAppear {
            if let engine = historyStore?.syncEngine {
                syncMode = engine.syncMode
                webDavUrl = engine.webDavURL
                webDavUsername = engine.webDavUsername
                webDavPassword = (engine.syncMode == .webdav) ? engine.webDavPassword : ""
                isE2EEEnabled = engine.isE2EEEnabled
                e2eePassphrase = engine.isE2EEEnabled ? engine.e2eePassphrase : ""
                syncSensitiveItems = engine.syncSensitiveItems
            }
            // 迁移与收敛：「无限制」已退役，Picker 只提供有限档位，因此旧版遗留的
            // 字面量（0/负数 = 无限制、超过硬上限的历史档位）必须回写为收敛后的档位，
            // 否则 Picker 选中项落在档位之外会显示空白。
            if let stored = UserDefaults.standard.object(forKey: HistoryMaxItemsPolicy.defaultsKey) as? Int {
                let clamped = HistoryMaxItemsPolicy.clamp(stored)
                if clamped != stored { historyMaxItemCount = clamped }
            } else if let legacyDays = UserDefaults.standard.object(forKey: HistoryMaxItemsPolicy.legacyRetentionDaysKey) as? Int,
                      legacyDays <= 0 {
                // 旧版保留期显式为 0 = 从不清理：条数维度已无无限制，迁移到硬上限
                // （而非默认 500），使这批用户被裁剪的幅度最小。
                historyMaxItemCount = HistoryMaxItemsPolicy.hardCap
            }
            if let storedDisk = UserDefaults.standard.object(forKey: DiskLimitPolicy.defaultsKey) as? Int {
                let clampedDisk = DiskLimitPolicy.clamp(storedDisk)
                if clampedDisk != storedDisk { historyDiskLimitMB = clampedDisk }
            }
        }
    }

    @ViewBuilder
    /// 计数徽标只做「这两个数字是同一行的补充信息」，不着色：
    /// 设置页里唯一的颜色留给真正在变化的那一个数据，其余一律中性
    private func statBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: NookClipIconSize.micro, weight: .semibold))
            Text(text)
                .font(.nookClipMono(11, .medium))
                .monospacedDigit()
        }
        .foregroundStyle(NookClip.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(NookClip.bgRaised, in: Capsule())
        .overlay(Capsule().stroke(NookClip.borderPanel, lineWidth: 1))
    }

    private func testWebDav() {
        isTestingWebDav = true
        webDavTestResult = nil
        let url = webDavUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = webDavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = webDavPassword
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try testWebdavConnection(baseUrl: url, username: user, password: pass, timeoutSecs: 10)
                }.value
                await MainActor.run {
                    webDavTestResult = (true, L10n.tr("settings.sync.conn_success"))
                    isTestingWebDav = false
                }
            } catch {
                await MainActor.run {
                    webDavTestResult = (false, L10n.tr("settings.sync.conn_failed", error.localizedDescription))
                    isTestingWebDav = false
                }
            }
        }
    }

    private static func diskLimitLabel(_ mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : "\(mb) MB"
    }

    /// 折叠摘要用：把「敏感内容处理」当前档位翻成一句短话。
    /// 摘要读的是同一个枚举，所以改档位时摘要不会和面板里的选中项脱节。
    private static func exportModeLabel(_ mode: SensitiveExportMode) -> String {
        switch mode {
        case .exclude:
            return L10n.tr("settings.export.mode_exclude")
        case .masked:
            return L10n.tr("settings.export.mode_masked")
        case .plaintext:
            return L10n.tr("settings.export.mode_plaintext")
        }
    }

    private static func syncModeLabel(_ mode: CloudSyncMode) -> String {
        switch mode {
        case .iCloudDrive:
            return L10n.tr("settings.sync.mode_icloud")
        case .localDirectory:
            return L10n.tr("settings.sync.mode_local_dir")
        case .webdav:
            return L10n.tr("settings.sync.mode_webdav")
        }
    }

    private var syncStatusColor: Color {
        guard let engine = historyStore?.syncEngine else { return NookClip.textTertiary }
        switch engine.state {
        case .idle:
            if engine.lastSyncDate != nil {
                return NookClip.colorSuccess
            }
            return NookClip.textTertiary
        case .syncing:
            return NookClip.controlPrimary
        case .success:
            return NookClip.colorSuccess
        case .failed:
            return NookClip.colorDanger
        }
    }

    private var syncStatusText: String {
        guard let store = historyStore else {
            return L10n.tr("settings.sync.status_not_enabled")
        }
        let engine = store.syncEngine
        switch engine.state {
        case .syncing:
            return L10n.tr("settings.sync.status_syncing")
        case .failed(let msg):
            return L10n.tr("settings.sync.status_error", msg)
        case .idle, .success:
            if let date = engine.lastSyncDate {
                return L10n.tr("settings.sync.status_success", L10n.relativeTime(for: date))
            }
            return L10n.tr("settings.sync.status_idle")
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
    private func performResetPassphrase() {
        guard let store = historyStore else { return }
        let trimmed = e2eePassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isResettingPassphrase = true
        syncStatusMessage = nil
        Task {
            do {
                try await store.resetSyncPassphrase()
                await MainActor.run {
                    isResettingPassphrase = false
                    syncStatusIsError = false
                    syncStatusMessage = L10n.tr("settings.sync.e2ee_reset_success")
                }
            } catch {
                await MainActor.run {
                    isResettingPassphrase = false
                    syncStatusIsError = true
                    syncStatusMessage = L10n.tr("settings.sync.msg_failed", error.localizedDescription)
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
// MARK: - 密码输入框组件（明文切换按钮内嵌右侧，统一对齐与宽度）
private struct SettingsPasswordField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isRevealed: Bool
    var width: CGFloat = 260
    var onChange: (String) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.trailing, 26)
            .frame(width: width)
            .onChange(of: text) { _, val in
                onChange(val)
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? NookClipIcon.Sensitive.remask : NookClipIcon.Sensitive.reveal)
                    .font(.system(size: 12))
                    .foregroundStyle(NookClip.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(isRevealed ? L10n.tr("preview.mask.remask") : L10n.tr("preview.mask.reveal"))
        }
        .frame(width: width)
    }
}
