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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("excluded.title"))
                    .font(.nookClipSectionTitle)
                    .foregroundStyle(NookClip.textPrimary)
                Text(L10n.tr("excluded.description"))
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.textSecondary)
            }

            // 排除应用列表卡片
            VStack(spacing: 0) {
                if manager.apps.isEmpty {
                    VStack(spacing: 10) {
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
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(manager.apps) { app in
                                ExcludedAppRow(app: app) {
                                    manager.remove(bundleIdentifier: app.bundleIdentifier)
                                    refreshRunningApps()
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .frame(height: 240)
            .background(NookClip.bgContent)
            .clipShape(RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: NookClip.radiusPanel, style: .continuous)
                    .strokeBorder(NookClip.separator, lineWidth: 0.5)
            )

            // 操作栏
            HStack(spacing: 10) {
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
                .menuStyle(.borderedButton)

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
                Spacer()

                if !manager.apps.isEmpty {
                    Button(role: .destructive) {
                        manager.removeAll()
                        refreshRunningApps()
                    } label: {
                        Text(L10n.tr("excluded.clear_all"))
                    }
                    .buttonStyle(.plain)
                    .font(.nookClipMeta)
                    .foregroundStyle(NookClip.colorDanger)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            refreshRunningApps()
        }
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
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
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
                    .foregroundStyle(NookClip.textTertiary)
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: NookClipIcon.Excluded.remove)
                    .font(.system(size: NookClipIconSize.regularMedium))
                    .foregroundStyle(isHovering ? NookClip.colorDanger : NookClip.textTertiary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("excluded.remove_tooltip"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isHovering ? NookClip.bgRowHover : Color.clear,
            in: RoundedRectangle(cornerRadius: NookClip.radiusControl, style: .continuous)
        )
        .onHover { hovering in
            withAnimation(NookClip.animHover) {
                isHovering = hovering
            }
        }
    }
}
