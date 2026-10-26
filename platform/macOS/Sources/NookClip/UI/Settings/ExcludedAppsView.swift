import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ExcludedAppsView: View {
    @State private var manager = ExcludedAppsManager.shared
    @State private var runningApps: [RunningAppInfo] = []

    struct RunningAppInfo: Identifiable {
        var id: String { bundleIdentifier }
        let name: String
        let bundleIdentifier: String
        let icon: NSImage
    }

    var body: some View {
        // 这一段是折叠分组「排除应用程序」的内容，外层已经是白面板：
        // 分组标题在折叠标题行上、白底在 SettingsPanel 上，所以这里
        // 不再重复写标题，也不再套一层卡片 —— 两层卡片叠在一起会让人
        // 以为里面是另一个可点的区域，边框也会和面板边框打架。
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("excluded.description"))
                .font(.nookClipSubhead)
                .foregroundStyle(NookClip.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            if manager.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: NookClipIcon.Excluded.empty)
                        .font(.system(size: NookClipIconSize.heroMedium))
                        .foregroundStyle(NookClip.textTertiary)
                    Text(L10n.tr("excluded.empty_title"))
                        .font(.nookClipBodyMedium)
                        .foregroundStyle(NookClip.textSecondary)
                    Text(L10n.tr("excluded.empty_subtitle"))
                        .font(.nookClipMeta)
                        .foregroundStyle(NookClip.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else if manager.apps.count <= Self.maxVisibleRows {
                // 少量应用时直接铺开，不套 ScrollView：滚动区里只有 3 条反而
                // 让人觉得「还有更多没显示」
                appList
            } else {
                // 列表本身可以滚：列表旁边没有滚动条，光看第 4 行贴着下沿
                // 不一定知道下面还有内容，所以在下面补一句说明
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView {
                        appList
                    }
                    // 高度取整行数 × 行高，滚到底时最后一行是完整的
                    .frame(height: Self.scrollHeight)

                    Text(L10n.tr(
                        "excluded.more_hint",
                        manager.apps.count,
                        manager.apps.count - Self.maxVisibleRows
                    ))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textTertiary)
                    .padding(.horizontal, 14)
                }
            }

            actionBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshRunningApps()
        }
    }

    // MARK: - 列表

    /// 列表最多露出这么多整行，超出的部分进滚动区。
    ///
    /// 关键是「整行」：行高 44，可视高度就取 44 的整数倍，这样最后一行
    /// 永远是完整的。之前不管几条都塞进固定 220pt 的滚动区，5 条时最后一
    /// 行只剩半截，看起来就像样式塌了。
    private static let maxVisibleRows = 4
    private static let rowHeight: CGFloat = 44
    private static let scrollHeight: CGFloat = rowHeight * CGFloat(maxVisibleRows)

    private var appList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(manager.apps.enumerated()), id: \.element.id) { offset, app in
                ExcludedAppRow(
                    app: app,
                    showDivider: offset < manager.apps.count - 1
                ) {
                    manager.remove(bundleIdentifier: app.bundleIdentifier)
                    refreshRunningApps()
                }
            }
        }
    }

    // MARK: - 操作栏

    private var actionBar: some View {
        HStack(spacing: 8) {
            Menu {
                if runningApps.isEmpty {
                    Text(L10n.tr("excluded.no_running"))
                } else {
                    ForEach(runningApps) { app in
                        Button {
                            manager.add(bundleIdentifier: app.bundleIdentifier, name: app.name)
                            refreshRunningApps()
                        } label: {
                            Text(app.name)
                        }
                    }
                }
            } label: {
                Label(L10n.tr("excluded.add_running"), systemImage: NookClipIcon.Excluded.addRunning)
            }
            // 用 .button + .bordered，让它和右边两个按钮长得一样；
            // 系统给 Menu 画的菜单箭头是个强调色实心圆块，在这一排平淡的
            // 描边按钮里格外刺眼，所以连箭头一起去掉（点按钮本身仍会弹菜单）
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .menuIndicator(.hidden)
            // 不加 fixedSize 时 Menu 会把整行剩余宽度吃掉，把后面两个按钮挤到右边
            .fixedSize()

            Button {
                selectAppFromFinder()
            } label: {
                Label(L10n.tr("excluded.choose_from_finder"), systemImage: NookClipIcon.Excluded.chooseFinder)
            }
            .buttonStyle(.bordered)

            Button {
                manager.addPresetPasswordManagers()
                refreshRunningApps()
            } label: {
                Text(L10n.tr("excluded.add_presets"))
            }
            .buttonStyle(.bordered)

            Spacer(minLength: 8)

            if !manager.apps.isEmpty {
                Button(role: .destructive) {
                    manager.removeAll()
                    refreshRunningApps()
                } label: {
                    Text(L10n.tr("excluded.clear_all"))
                }
                .buttonStyle(.plain)
                .font(.nookClipSubheadMedium)
                .foregroundStyle(NookClip.colorDanger)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func refreshRunningApps() {
        let currentExcluded = Set(manager.apps.map { $0.bundleIdentifier.lowercased() })
        runningApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                app.bundleIdentifier != Bundle.main.bundleIdentifier &&
                !(app.bundleIdentifier.map { currentExcluded.contains($0.lowercased()) } ?? false)
            }
            .compactMap { app in
                guard let bid = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bid
                let icon = app.icon ?? NSWorkspace.shared.icon(for: .application)
                return RunningAppInfo(name: name, bundleIdentifier: bid, icon: icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func selectAppFromFinder() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = L10n.tr("excluded.open_panel_prompt")
        panel.message = L10n.tr("excluded.open_panel_message")

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                    let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                        ?? url.deletingPathExtension().lastPathComponent
                    manager.add(bundleIdentifier: bid, name: name)
                } else {
                    let name = url.deletingPathExtension().lastPathComponent
                    manager.add(bundleIdentifier: "app.\(name.lowercased())", name: name)
                }
            }
            refreshRunningApps()
        }
    }
}

@MainActor
private struct ExcludedAppRow: View {
    let app: ExcludedApp
    var showDivider: Bool = false
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.nookClipBodyMedium)
                        .foregroundStyle(NookClip.textPrimary)
                    Text(app.bundleIdentifier)
                        .font(.nookClipMono(11))
                        .foregroundStyle(NookClip.textSecondary)
                }

                Spacer()

                Button {
                    onRemove()
                } label: {
                    Image(systemName: NookClipIcon.Excluded.remove)
                        .font(.system(size: NookClipIconSize.regularMedium))
                        .foregroundStyle(isHovering ? NookClip.colorDanger : NookClip.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("excluded.remove_tooltip"))
                .accessibilityLabel(L10n.tr("excluded.remove_tooltip"))
            }
            // 与 SettingsRow 同一套度量：横向 14、最小行高 44，
            // 这样排除列表和上下其它行看起来是同一个列表，而不是夹了块外来内容
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(
                isHovering ? NookClip.bgRowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
            )
            .onHover { hovering in
                withAnimation(NookClip.animHover) {
                    isHovering = hovering
                }
            }

            if showDivider {
                Rectangle()
                    .fill(NookClip.ruleSubtle)
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}
