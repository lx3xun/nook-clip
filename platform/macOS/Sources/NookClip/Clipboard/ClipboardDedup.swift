import Foundation
import CryptoKit

/// 剪贴板内容去重键辅助工具（独立自 SQLiteHistoryStore）
public enum ClipboardDedup {
    public static func dedupKey(_ item: ClipboardItem) -> String {
        if item.isSensitive {
            return "sensitive_\(item.id.uuidString)"
        }
        let digest = SHA256.hash(data: Data(item.summary.utf8))
        return "\(item.type.rawValue)_\(digest.map { String(format: "%02x", $0) }.joined())"
    }
}
