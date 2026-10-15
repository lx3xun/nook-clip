import Foundation
import Sparkle

// MARK: - 自动更新（Sparkle 2）
//
// 更新源双库并行：GitHub（海外）/ Gitee（国内），各自维护一份 appcast。
// 「自动」模式启动时后台探测 GitHub 可达性（约 3 秒超时），探测完成前
// 默认走 GitHub；探测失败则本次会话内回落 Gitee。用户也可在设置页锁定。

/// 更新源选择，rawValue 持久化到 UserDefaults（key: updateSource）
enum UpdateSource: String, CaseIterable, Identifiable {
    case auto
    case github
    case gitee

    var id: String { rawValue }

    var feedURL: URL {
        switch self {
        case .github, .auto:
            UpdateSource.githubFeedURL
        case .gitee:
            UpdateSource.giteeFeedURL
        }
    }

    /// 固定 tag `appcast` 上的更新清单，URL 永久稳定（发布时覆盖上传）
    static let githubFeedURL = URL(string: "https://github.com/lx3xun/nook-clip/releases/download/appcast/appcast.xml")!
    static let giteeFeedURL = URL(string: "https://gitee.com/lx3xun/nook-clip/releases/download/appcast/appcast.xml")!
}

@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()


    private var updaterController: SPUStandardUpdaterController!

    /// 自动模式下实际生效的源（探测结果，仅内存态；用户锁定时不参与）
    @Published private(set) var resolvedAutoSource: UpdateSource = .github

    private static let probeTimeout: TimeInterval = 3

    private override init() {
        super.init()
        // startingUpdater: false —— 先让更新源探测跑完再启动；
        // updaterDelegate 在此传入（Sparkle 官方模式，weak 引用）
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        // 默认值与设置页 @AppStorage 初值一致（首次启动自动检查更新、更新源=自动）
        UserDefaults.standard.register(defaults: [
            "SUEnableAutomaticChecks": true,
            "updateSource": UpdateSource.auto.rawValue
        ])
    }

    var updater: SPUUpdater { updaterController.updater }

    /// 应用启动时调用：探测更新源后启动 Sparkle
    func start() {
        probeAndUpdateResolvedSource()
        do {
            try updater.start()
        } catch {
            // 启动失败（如宿主 bundle 配置异常）不影响应用其余功能
            NSLog("Sparkle updater 启动失败: \(error)")
        }
    }

    /// 手动「检查更新」（菜单栏与设置页共用入口）
    func checkForUpdates() {
        // 手动检查前刷新一次探测结果，供本次（或紧随其后）的 feed 查询使用；
        // feedURLString 若在探测完成前被查询，沿用上次结果，不阻塞主线程
        probeAndUpdateResolvedSource()
        updater.checkForUpdates()
    }

    /// 当前设置源（读取用户偏好，auto 未探测完成时按 resolvedAutoSource 兜底）
    func effectiveFeedURL(for source: UpdateSource) -> URL {
        switch source {
        case .github: return UpdateSource.githubFeedURL
        case .gitee: return UpdateSource.giteeFeedURL
        case .auto: return resolvedAutoSource.feedURL
        }
    }

    /// 后台探测 GitHub feed 可达性，不可达则本会话回落 Gitee
    private func probeAndUpdateResolvedSource() {
        Task {
            var request = URLRequest(url: UpdateSource.githubFeedURL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = Self.probeTimeout
            let response = (try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse
            let reachable = response?.statusCode != nil
            self.resolvedAutoSource = reachable ? .github : .gitee
        }
    }
}

extension UpdateService: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        // 调试/冒烟入口：NOOK_UPDATE_FEED_URL 指向本地 appcast 验证更新链路（同 --show-panel 模式）
        if let override = ProcessInfo.processInfo.environment["NOOK_UPDATE_FEED_URL"], !override.isEmpty {
            return override
        }
        let source = UserDefaults.standard.string(forKey: UserDefaultsKey.updateSource.rawValue).flatMap(UpdateSource.init(rawValue:)) ?? .auto
        return MainActor.assumeIsolated {
            Self.shared.effectiveFeedURL(for: source).absoluteString
        }
    }
}
