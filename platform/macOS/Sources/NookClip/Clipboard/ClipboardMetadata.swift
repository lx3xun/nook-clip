import Foundation

public struct ClipboardMetadata: Codable, Equatable {
    public var language: String?
    public var url: String?
    public var fileInfo: String?
    public var hasEmail: Bool?

    public init(
        language: String? = nil,
        url: String? = nil,
        fileInfo: String? = nil,
        hasEmail: Bool? = nil
    ) {
        self.language = language
        self.url = url
        self.fileInfo = fileInfo
        self.hasEmail = hasEmail
    }
}
