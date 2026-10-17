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
    case custom(String)
    case unknown

    var localizedDescription: String {
        switch self {
        case .network: return L10n.tr("sync.fail.network")
        case .credential: return L10n.tr("sync.fail.credential")
        case .custom(let message): return message
        case .unknown: return L10n.tr("sync.fail.unknown")
        }
    }

    static func from(error: Error, syncMode: CloudSyncMode? = nil) -> SyncFailureReason {
        if let nookErr = error as? NookClipError {
            switch nookErr {
            case .SyncTransportError(let msg):
                let lower = msg.lowercased()
                if lower.contains("401") || lower.contains("unauthorized") {
                    return syncMode == .webdav ? .custom(L10n.tr("sync.fail.webdav_auth")) : .credential
                } else if lower.contains("403") || lower.contains("forbidden") {
                    return syncMode == .webdav ? .custom(L10n.tr("sync.fail.webdav_forbidden")) : .credential
                } else if lower.contains("404") || lower.contains("not found") {
                    return .custom(L10n.tr("sync.fail.not_found"))
                } else if lower.contains("timeout") || lower.contains("timed out") {
                    return .custom(L10n.tr("sync.fail.timeout"))
                } else if lower.contains("connection refused") || lower.contains("failed to lookup") || lower.contains("dns") {
                    return .custom(L10n.tr("sync.fail.cannot_connect"))
                } else {
                    return .custom(msg)
                }
            case .CryptoError(let msg):
                let lower = msg.lowercased()
                if lower.contains("passphrase") || lower.contains("decryption") || lower.contains("password") {
                    return .custom(L10n.tr("sync.fail.passphrase_mismatch"))
                }
                return .custom(msg)
            case .DatabaseError(let msg):
                return .custom(L10n.tr("sync.fail.database", msg))
            default:
                let desc = error.localizedDescription
                return desc.isEmpty ? .unknown : .custom(desc)
            }
        }

        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            return .network
        }

        let desc = error.localizedDescription
        return desc.isEmpty ? .unknown : .custom(desc)
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
