import Foundation
import NeechanAPI

/// How a saved file is named.
public enum DownloadNameStyle: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The name the uploader gave the file.
    case original
    /// The name 2ch stored it under, which is unique.
    case serverName
    /// Board, thread and post, so a file is traceable back to where it came from.
    case detailed

    public var id: String { rawValue }
}

/// Builds file names for downloads.
public enum DownloadNaming {
    /// Characters a name must not contain, on any file system the app writes to.
    private static let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
    /// Leaves room for a conflict suffix inside the 255-byte limit.
    private static let maxNameBytes = 200

    public static func fileName(
        for attachment: NeechanAPI.Attachment,
        in thread: ThreadKey,
        postNum: Int? = nil,
        style: DownloadNameStyle
    ) -> String {
        let fileExtension = resolvedExtension(for: attachment)

        let base: String = switch style {
        case .original:
            stem(of: attachment.fullName)
        case .serverName:
            stem(of: attachment.name)
        case .detailed:
            "\(thread.board)-\(thread.threadNum)-\(postNum ?? thread.threadNum)-\(stem(of: attachment.name))"
        }

        var sanitised = sanitise(base)
        if sanitised.isEmpty {
            // The original name was nothing but separators; the server's name is
            // always usable.
            sanitised = sanitise(stem(of: attachment.name))
        }
        if sanitised.isEmpty {
            sanitised = "\(thread.board)-\(thread.threadNum)"
        }
        sanitised = truncate(sanitised, toBytes: maxNameBytes)

        return fileExtension.isEmpty ? sanitised : "\(sanitised).\(fileExtension)"
    }

    /// Strips a directory-unsafe character set without collapsing the name.
    public static func sanitise(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would hide the file; a name of only dots is unusable.
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "._"))
    }

    private static func stem(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    /// The uploader's name may have lost its extension; the server path always
    /// has one.
    private static func resolvedExtension(for attachment: NeechanAPI.Attachment) -> String {
        let fromFullName = (attachment.fullName as NSString).pathExtension
        return fromFullName.isEmpty ? attachment.fileExtension : fromFullName.lowercased()
    }

    /// Truncates on a character boundary so a multi-byte name stays valid.
    private static func truncate(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        var result = name
        while result.utf8.count > limit, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}

/// Expands the subdirectory pattern a reader configures.
public enum DownloadPathTemplate {
    public static let defaultTemplate = "<board>/<thread>"

    /// Turns a template into path components, dropping anything unsafe.
    ///
    /// The result can only ever go deeper: a template containing `..` cannot
    /// write outside the chosen download folder.
    public static func expand(
        _ template: String,
        for thread: ThreadKey,
        threadTitle: String
    ) -> [String] {
        template
            .split(separator: "/")
            .map(String.init)
            .compactMap { component -> String? in
                let expanded: String
                switch component.trimmingCharacters(in: .whitespaces) {
                case "<board>": expanded = thread.board
                case "<thread>": expanded = String(thread.threadNum)
                case "<title>": expanded = threadTitle
                case let literal where literal.hasPrefix("<") && literal.hasSuffix(">"):
                    // An unknown placeholder would otherwise appear literally in
                    // the path, which is never what the reader meant.
                    return nil
                case let literal: expanded = literal
                }
                let safe = DownloadNaming.sanitise(expanded)
                return safe.isEmpty ? nil : safe
            }
    }
}
