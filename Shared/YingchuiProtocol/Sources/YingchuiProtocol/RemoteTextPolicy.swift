import Foundation

public enum RemoteTextPolicy {
    public static let maximumInputCharacters = 4_096
    public static let maximumClipboardBytes = 65_536

    public static func chunks(_ text: String) throws -> [String] {
        guard !text.isEmpty else { throw RemoteTextError.empty }
        guard text.count <= maximumInputCharacters else { throw RemoteTextError.tooLong }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: 128, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }

    public static func validateClipboard(_ text: String?) throws -> String {
        guard let text, !text.isEmpty else { throw RemoteTextError.empty }
        guard text.utf8.count <= maximumClipboardBytes else { throw RemoteTextError.tooLong }
        return text
    }
}

public enum RemoteTextError: LocalizedError {
    case empty, tooLong
    public var errorDescription: String? {
        switch self {
        case .empty: "没有可发送的文字"
        case .tooLong: "文字超过允许长度，请缩短后重试"
        }
    }
}
