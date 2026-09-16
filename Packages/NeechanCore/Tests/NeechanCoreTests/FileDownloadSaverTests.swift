import Foundation
import NeechanSettings
import Testing
@testable import NeechanCore

@Suite("Saving a download to a folder")
struct FileDownloadSaverTests {
    /// A folder of its own per test, since these all touch the file system.
    private func makeFolder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSourceFile(_ contents: String = "x") throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).bin")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test("the file lands under the folders the pattern asked for")
    func createsSubdirectories() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let saved = try FileDownloadSaver.save(
            fileAt: try makeSourceFile(),
            named: "picture.jpg",
            in: folder,
            subpath: ["b", "12345"],
            conflict: .keepBoth
        )

        #expect(saved.path.hasSuffix("b/12345/picture.jpg"))
        #expect(FileManager.default.fileExists(atPath: saved.path))
    }

    @Test("keeping both leaves the first file where it was")
    func keepBoth() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try FileDownloadSaver.save(
            fileAt: try makeSourceFile("first"),
            named: "a.jpg", in: folder, subpath: [], conflict: .keepBoth
        )
        let second = try FileDownloadSaver.save(
            fileAt: try makeSourceFile("second"),
            named: "a.jpg", in: folder, subpath: [], conflict: .keepBoth
        )

        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
    }

    @Test("replacing overwrites, which moving a file refuses to do on its own")
    func replace() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try FileDownloadSaver.save(
            fileAt: try makeSourceFile("first"),
            named: "a.jpg", in: folder, subpath: [], conflict: .replace
        )
        let second = try FileDownloadSaver.save(
            fileAt: try makeSourceFile("second"),
            named: "a.jpg", in: folder, subpath: [], conflict: .replace
        )

        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test("skipping writes nothing and says so")
    func skip() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try FileDownloadSaver.save(
            fileAt: try makeSourceFile("first"),
            named: "a.jpg", in: folder, subpath: [], conflict: .skip
        )
        #expect(throws: FileDownloadSaver.SaveError.skipped) {
            try FileDownloadSaver.save(
                fileAt: try makeSourceFile("second"),
                named: "a.jpg", in: folder, subpath: [], conflict: .skip
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test("a bookmark that no longer resolves is reported, not crashed on")
    func brokenBookmark() throws {
        #expect(throws: FileDownloadSaver.SaveError.destinationUnavailable) {
            try FileDownloadSaver.save(
                fileAt: try makeSourceFile(),
                named: "a.jpg",
                bookmark: Data([0, 1, 2, 3]),
                subpath: [],
                conflict: .keepBoth
            )
        }
    }

    @Test("a folder can be bookmarked and used again")
    func bookmarkRoundTrip() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let bookmark = try FileDownloadSaver.bookmark(for: folder)
        let saved = try FileDownloadSaver.save(
            fileAt: try makeSourceFile(),
            named: "a.jpg",
            bookmark: bookmark,
            subpath: ["b"],
            conflict: .keepBoth
        )

        #expect(FileManager.default.fileExists(atPath: saved.path))
    }
}
