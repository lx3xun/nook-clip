import AppKit
import Foundation
import Observation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system:
            return L10n.tr("settings.general.lang_system")
        case .zhHans:
            return "简体中文"
        case .zhHant:
            return "繁體中文"
        case .en:
            return "English"
        }
    }
}

@Observable
public final class LocalizationManager: @unchecked Sendable {
    public static let shared = LocalizationManager()

    private let userDefaultsKey = "app_language"
    private let lock = NSLock()

    public var selectedLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: userDefaultsKey)
            updateEffectiveLanguage()
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .languageDidChange, object: self.selectedLanguage)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .languageDidChange, object: self.selectedLanguage)
                }
            }
        }
    }
    public private(set) var effectiveLanguageCode: String = "en"
    public private(set) var locale: Locale = Locale(identifier: "en")
    public private(set) var activeBundle: Bundle = Bundle.main

    private init() {
        let savedRaw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? AppLanguage.system.rawValue
        self.selectedLanguage = AppLanguage(rawValue: savedRaw) ?? .system
        updateEffectiveLanguage()
    }

    private func updateEffectiveLanguage() {
        let code: String
        switch selectedLanguage {
        case .zhHans:
            code = "zh-Hans"
        case .zhHant:
            code = "zh-Hant"
        case .en:
            code = "en"
        case .system:
            code = Self.resolveSystemLanguage()
        }

        let foundBundle = Self.findBundle(for: code)
        let newLocale = Locale(identifier: code)

        lock.lock()
        self.effectiveLanguageCode = code
        self.locale = newLocale
        self.activeBundle = foundBundle
        lock.unlock()
    }

    private static func resolveSystemLanguage() -> String {
        let preferred = Locale.preferredLanguages
        for lang in preferred {
            let lower = lang.lowercased()
            if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") || lower.hasPrefix("zh-mo") {
                return "zh-Hant"
            }
            if lower.hasPrefix("zh") {
                return "zh-Hans"
            }
            if lower.hasPrefix("en") {
                return "en"
            }
        }
        return "en"
    }

    private static func findBundle(for languageCode: String) -> Bundle {
        if let modulePath = Bundle.module.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: modulePath) {
            return bundle
        }

        if let mainPath = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: mainPath) {
            return bundle
        }

        return Bundle.module
    }

    public func tr(_ key: String, _ args: CVarArg...) -> String {
        lock.lock()
        let b = activeBundle
        let loc = locale
        lock.unlock()

        let format = b.localizedString(forKey: key, value: nil, table: nil)
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: loc, arguments: args)
    }

    public func relativeTime(for date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        let seconds = Int(interval)

        if seconds < 60 {
            return tr("time.just_now")
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return tr("time.minutes_ago", minutes)
        }

        lock.lock()
        let loc = locale
        lock.unlock()

        let calendar = Calendar.current
        let timeFormatter = Self.cachedFormatter(locale: loc, dateStyle: .none, timeStyle: .short)
        let timeString = timeFormatter.string(from: date)

        if calendar.isDateInToday(date) {
            return tr("time.today", timeString)
        }

        if calendar.isDateInYesterday(date) {
            return tr("time.yesterday", timeString)
        }

        let fullFormatter = Self.cachedFormatter(locale: loc, dateStyle: .short, timeStyle: .short)
        return fullFormatter.string(from: date)
    }

    /// relativeTime 的 DateFormatter 静态缓存（FR-010）：按 locale.identifier 作 key，
    /// 语言切换后 identifier 变化即新建，避免每次调用重建（线程安全：与实例同锁保护）
    private static var formatterCache: [String: DateFormatter] = [:]
    private static let formatterCacheLock = NSLock()

    private static func cachedFormatter(locale: Locale, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> DateFormatter {
        let key = "\(locale.identifier)-\(dateStyle.rawValue)-\(timeStyle.rawValue)"
        formatterCacheLock.lock()
        defer { formatterCacheLock.unlock() }
        if let cached = formatterCache[key] {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        formatterCache[key] = formatter
        return formatter
    }
}

public enum L10n {
    public static var manager: LocalizationManager {
        LocalizationManager.shared
    }

    public static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = manager.tr(key)
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: manager.locale, arguments: args)
    }

    public static func relativeTime(for date: Date) -> String {
        manager.relativeTime(for: date)
    }
}

public struct LocalizedViewModifier: ViewModifier {
    @State private var changeId = UUID()

    public func body(content: Content) -> some View {
        content
            .environment(\.locale, LocalizationManager.shared.locale)
            .id(changeId)
            .onReceive(NotificationCenter.default.publisher(for: .languageDidChange)) { _ in
                changeId = UUID()
            }
    }
}
public extension View {
    func nookClipLocalized() -> some View {
        modifier(LocalizedViewModifier())
    }
}
