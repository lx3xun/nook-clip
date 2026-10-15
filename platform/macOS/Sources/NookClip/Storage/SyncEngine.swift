import Foundation

/// 同步状态机（引擎与设置页共用展示）
enum SyncState: Equatable {
    case idle
    case syncing
    case failed(String)
    case success(Date)
}

enum SyncFailureReason: Equatable {
    case network
    case credential
    case unknown

    var localizedDescription: String {
        switch self {
        case .network: return L10n.tr("sync.fail.network")
        case .credential: return L10n.tr("sync.fail.credential")
        case .unknown: return L10n.tr("sync.fail.unknown")
        }
    }
}

struct SyncResult: Equatable {
    enum Outcome: Equatable {
        case success(Date)
        case failure(SyncFailureReason, Date)
        case idle
    }

    let outcome: Outcome

    static let idle = SyncResult(outcome: .idle)
    static func success(_ date: Date) -> SyncResult { SyncResult(outcome: .success(date)) }
    static func failure(_ reason: SyncFailureReason, at date: Date) -> SyncResult { SyncResult(outcome: .failure(reason, date)) }
}
