import AppKit
import OSLog
import Foundation
import Observation

public struct ExcludedApp: Codable, Identifiable, Hashable, Sendable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let name: String

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }

    @MainActor
    public var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}

@MainActor
@Observable
public final class ExcludedAppsManager {
    public static let shared = ExcludedAppsManager()
    /// 常见密码管理器与钥匙串预设（PRD §4.4.1）
    public static let presetPasswordManagers: [ExcludedApp] = [
        ExcludedApp(bundleIdentifier: "com.1password.1password", name: "1Password"),
        ExcludedApp(bundleIdentifier: "com.agilebits.onepassword7", name: "1Password 7"),
        ExcludedApp(bundleIdentifier: "com.bitwarden.desktop", name: "Bitwarden"),
        ExcludedApp(bundleIdentifier: "org.keepassxc.keepassxc", name: "KeePassXC"),
        ExcludedApp(bundleIdentifier: "in.sinew.Enpass-Desktop", name: "Enpass"),
        ExcludedApp(bundleIdentifier: "com.apple.keychainaccess", name: "Keychain Access")
    ]

    /// 排除列表持久化失败留痕（FR-011a）
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.lx3xun.nookclip", category: "ExcludedAppsManager")

    private let userDefaultsKey = "excludedApplications"
    public private(set) var apps: [ExcludedApp] = []
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            return false
        }
        return apps.contains { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    public func add(bundleIdentifier: String, name: String) {
        let trimmedId = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        if !apps.contains(where: { $0.bundleIdentifier.caseInsensitiveCompare(trimmedId) == .orderedSame }) {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = ExcludedApp(bundleIdentifier: trimmedId, name: cleanName.isEmpty ? trimmedId : cleanName)
            apps.append(app)
            save()
        }
    }

    public func remove(bundleIdentifier: String) {
        apps.removeAll { $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
        save()
    }

    public func removeAll() {
        apps.removeAll()
        save()
    }

    public func addPresetPasswordManagers() {
        for preset in Self.presetPasswordManagers {
            add(bundleIdentifier: preset.bundleIdentifier, name: preset.name)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: userDefaultsKey) else {
            apps = []
            return
        }
        // decode 失败留痕但不中断：apps 置空行为不变（FR-011a）
        do {
            apps = try JSONDecoder().decode([ExcludedApp].self, from: data)
        } catch {
            Self.logger.error("Excluded apps decode failed, resetting list: \(error.localizedDescription, privacy: .public)")
            apps = []
        }
    }

    private func save() {
        // encode 失败留痕：静默丢弃会让排除列表悄悄失效（FR-011a）
        do {
            defaults.set(try JSONEncoder().encode(apps), forKey: userDefaultsKey)
        } catch {
            Self.logger.error("Excluded apps encode failed, list not persisted: \(error.localizedDescription, privacy: .public)")
        }
    }
}
