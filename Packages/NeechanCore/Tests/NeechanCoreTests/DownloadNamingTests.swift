import Foundation
import NeechanAPI
import NeechanTestSupport
import Testing
@testable import NeechanCore

/// Builds an attachment without hand-writing JSON, so a name containing quotes
/// or backslashes cannot break the literal.
private func attachment(
    path: String = "/b/src/123/17891583643470505794.jpg",
    fullName: String = "смешная картинка.jpg"
) throws -> NeechanAPI.Attachment {
    let object: [String: Any] = [
        "name": "17891583643470505794.jpg",
        "fullname": fullName,
        "displayname": fullName,
        "path": path,
        "thumbnail": "/b/thumb/123/17891583643470505794s.jpg",
        "type": 1, "size": 100, "width": 10, "height": 10,
        "tn_width": 5, "tn_height": 5,
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(NeechanAPI.Attachment.self, from: data)
}

@Suite("Download naming")
struct DownloadNamingTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 123)

    @Test("the original name is used when the reader asked for it")
    func originalName() throws {
        let name = DownloadNaming.fileName(
            for: try attachment(), in: key, style: .original
        )
        #expect(name == "смешная картинка.jpg")
    }

    @Test("the server name is used otherwise")
    func serverName() throws {
        let name = DownloadNaming.fileName(
            for: try attachment(), in: key, style: .serverName
        )
        #expect(name == "17891583643470505794.jpg")
    }

    @Test("the detailed name carries the board, thread and post")
    func detailedName() throws {
        let name = DownloadNaming.fileName(
            for: try attachment(), in: key, postNum: 456, style: .detailed
        )
        #expect(name.contains("b"))
        #expect(name.contains("123"))
        #expect(name.contains("456"))
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("characters a file system cannot hold are replaced")
    func sanitisesNames() throws {
        let hostile = try attachment(fullName: "a/b:c\\d*e?f\"g<h>i|j.jpg")
        let name = DownloadNaming.fileName(for: hostile, in: key, style: .original)

        for character in ["/", ":", "\\", "*", "?", "\"", "<", ">", "|"] {
            #expect(name.contains(character) == false, "\(character) survived sanitising")
        }
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("a name that is only separators falls back to the server name")
    func emptyNameFallsBack() throws {
        let hostile = try attachment(fullName: "///.jpg")
        let name = DownloadNaming.fileName(for: hostile, in: key, style: .original)
        #expect(name.isEmpty == false)
        #expect(name.hasPrefix("_") == false || name.count > 1)
    }

    @Test("a very long name is shortened but keeps its extension")
    func truncatesLongNames() throws {
        let long = String(repeating: "я", count: 400) + ".jpg"
        let name = DownloadNaming.fileName(for: try attachment(fullName: long), in: key, style: .original)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".jpg"))
    }

    @Test("a missing extension is taken from the server path")
    func recoversExtension() throws {
        let name = DownloadNaming.fileName(
            for: try attachment(fullName: "без расширения"), in: key, style: .original
        )
        #expect(name.hasSuffix(".jpg"))
    }
}

@Suite("Download path template")
struct DownloadPathTemplateTests {
    private let key = ThreadKey(site: .dvach, board: "b", threadNum: 123)

    @Test("the board and thread placeholders expand")
    func expandsPlaceholders() {
        let path = DownloadPathTemplate.expand("<board>/<thread>", for: key, threadTitle: "Тред")
        #expect(path == ["b", "123"])
    }

    @Test("the title placeholder expands and is sanitised")
    func expandsTitle() {
        let path = DownloadPathTemplate.expand("<board>/<title>", for: key, threadTitle: "a/b:c")
        #expect(path.count == 2)
        #expect(path[1].contains("/") == false)
        #expect(path[1].contains(":") == false)
    }

    @Test("an empty template means no subdirectories")
    func emptyTemplate() {
        #expect(DownloadPathTemplate.expand("", for: key, threadTitle: "x").isEmpty)
        #expect(DownloadPathTemplate.expand("   ", for: key, threadTitle: "x").isEmpty)
    }

    @Test("a traversal in the template cannot escape the download folder")
    func rejectsTraversal() {
        let path = DownloadPathTemplate.expand("../../etc/<board>", for: key, threadTitle: "x")
        #expect(path.contains("..") == false)
        #expect(path.contains("b"))
    }

    @Test("an unknown placeholder is dropped rather than left literal")
    func dropsUnknownPlaceholders() {
        let path = DownloadPathTemplate.expand("<board>/<nope>", for: key, threadTitle: "x")
        #expect(path == ["b"])
    }
}

@Suite("Download conflicts")
struct ConflictResolverTests {
    @Test("a free name is used as is")
    func freeName() {
        let resolved = ConflictResolver.resolve(
            fileName: "a.jpg", existing: [], action: .keepBoth
        )
        #expect(resolved == "a.jpg")
    }

    @Test("keeping both adds a counter before the extension")
    func keepBoth() {
        let resolved = ConflictResolver.resolve(
            fileName: "a.jpg", existing: ["a.jpg", "a 2.jpg"], action: .keepBoth
        )
        #expect(resolved == "a 3.jpg")
    }

    @Test("replacing reuses the name")
    func replace() {
        let resolved = ConflictResolver.resolve(
            fileName: "a.jpg", existing: ["a.jpg"], action: .replace
        )
        #expect(resolved == "a.jpg")
    }

    @Test("skipping yields nothing to write")
    func skip() {
        #expect(
            ConflictResolver.resolve(fileName: "a.jpg", existing: ["a.jpg"], action: .skip) == nil
        )
    }

    @Test("a name with no extension still gets a counter")
    func noExtension() {
        let resolved = ConflictResolver.resolve(
            fileName: "a", existing: ["a"], action: .keepBoth
        )
        #expect(resolved == "a 2")
    }
}
