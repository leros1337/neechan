import CoreGraphics
import Foundation
import NeechanAPI
import Testing
@testable import NeechanMedia

/// Every video in a live thread, played through the real player.
///
/// For chasing a report that a thread's videos will not play: pointed at the
/// thread, it says file by file what each one is and what the player made of
/// it. The thread is read with the app's own parser, videos are picked by the
/// gallery's own rule, and the bytes come through the same reader the gallery
/// uses, so a file that fails here fails there.
///
/// Off unless asked for, since it needs the network and a thread that still
/// exists:
///
///     NEECHAN_SWEEP_THREAD=https://2ch.su/test/res/237957.html \
///         swift test --filter LiveThreadSweep
///
/// `NEECHAN_SWEEP_POSTS=238117,238123` narrows it to those posts' files.
///
/// On the simulator, `xcodebuild test` hands the variable over when it is
/// given as `TEST_RUNNER_NEECHAN_SWEEP_THREAD`. Run it in both places: the Mac
/// decodes VP9 in hardware, the simulator in software.
@Suite("Every video in a live thread", .serialized)
@MainActor
struct LiveThreadSweepTests {
    nonisolated static let threadPage = ProcessInfo.processInfo.environment["NEECHAN_SWEEP_THREAD"]
    /// Post numbers to keep, comma-separated, for going back over the few
    /// that failed rather than the whole thread.
    nonisolated static let onlyPosts: Set<Int> = Set(
        (ProcessInfo.processInfo.environment["NEECHAN_SWEEP_POSTS"] ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    )

    @Test(
        "every video in the thread plays, keeps playing, seeks, and is heard",
        .enabled(if: threadPage != nil, "set NEECHAN_SWEEP_THREAD to a thread's page"),
        .timeLimit(.minutes(30))
    )
    func everyVideoPlays() async throws {
        // One playback test at a time; see PlayerTestGate.
        await PlayerTestGate.shared.enter()
        defer { PlayerTestGate.shared.leave() }

        let page = try #require(Self.threadPage.flatMap(URL.init(string:)))
        let root = try #require(URL(string: "\(page.scheme ?? "https")://\(page.host() ?? "")"))
        let thread = try await Self.fetchThread(page)

        let videos = thread.posts.flatMap { post in
            post.files.map { (post: post.num, file: $0) }
        }.filter {
            Self.kind(of: $0.file).isVideo
                && (Self.onlyPosts.isEmpty || Self.onlyPosts.contains($0.post))
        }
        try #require(!videos.isEmpty, "\(page) has no videos")
        print("sweep: \(videos.count) videos in \(page)")

        var failed: [String] = []
        for (index, video) in videos.enumerated() {
            let url = try #require(URL(string: video.file.path, relativeTo: root)?.absoluteURL)
            let report = await PlaybackDiagnostics.open(
                url,
                options: MediaPlayerOptions(
                    kind: Self.kind(of: video.file),
                    referer: root,
                    userAgent: UserAgent.current
                ),
                timeout: .seconds(30),
                playFor: 2,
                seekTo: 0.5
            )
            let problems = Self.problems(
                in: report,
                expectedSize: CGSize(width: video.file.width, height: video.file.height)
            )
            let line = Self.row(index + 1, of: videos.count, post: video.post, file: video.file,
                                report: report, problems: problems)
            print(line)
            if !problems.isEmpty { failed.append(line) }
            #expect(
                problems.isEmpty,
                "\(video.post) \(video.file.name): \(problems.joined(separator: "; ")) \(report.events)"
            )
        }

        print("sweep: \(videos.count - failed.count) of \(videos.count) played")
        for line in failed { print("sweep FAILED \(line)") }
    }

    // MARK: - Reading the thread

    /// The thread's JSON, which sits beside its page with the other extension.
    private static func fetchThread(_ page: URL) async throws -> ThreadResponse {
        let json = page.pathExtension == "json"
            ? page
            : page.deletingPathExtension().appendingPathExtension("json")
        var request = URLRequest(url: json)
        request.setValue(UserAgent.current, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        try #require(status == 200, "\(json) answered \(status)")
        return try JSONDecoder().decode(ThreadResponse.self, from: data)
    }

    /// What the gallery would make of the file.
    private static func kind(of file: NeechanAPI.Attachment) -> MediaKind {
        MediaKind.resolve(fileName: file.path, declaredTypeCode: file.declaredType.rawValue)
    }

    // MARK: - Judging

    /// Everything wrong with how a file played, or nothing.
    private static func problems(in report: PlaybackDiagnostics.Report, expectedSize: CGSize) -> [String] {
        guard report.isPlayable else {
            return ["never played: \(report.error ?? "no error")"]
        }
        var problems: [String] = []

        // Turned either way: the thread gives the size as shown, the player as
        // stored, and a phone's clip is stored on its side.
        let size = report.naturalSize
        let turned = CGSize(width: size.height, height: size.width)
        if expectedSize != .zero, size != expectedSize, turned != expectedSize {
            problems.append(
                "is \(Int(size.width))x\(Int(size.height)), the thread says "
                    + "\(Int(expectedSize.width))x\(Int(expectedSize.height))"
            )
        }
        if report.soundDecoded == false {
            problems.append("silent: no \(report.audioCodec ?? "sound") came out of the decoder")
        }
        let shouldReach = report.duration > 0 ? min(1.5, report.duration * 0.8) : 1.5
        if report.furthest < shouldReach {
            problems.append("stopped at \(String(format: "%.2f", report.furthest))s")
        }
        if report.seekLanded == false, !report.seekEnded {
            problems.append("did not carry on after a seek halfway")
        }
        if let error = report.error {
            problems.append("failed: \(error)")
        }
        return problems
    }

    private static func row(
        _ number: Int, of total: Int, post: Int, file: NeechanAPI.Attachment,
        report: PlaybackDiagnostics.Report, problems: [String]
    ) -> String {
        let codecs = [report.videoCodec, report.audioCodec].compactMap(\.self).joined(separator: "+")
        let sound = switch report.soundDecoded {
        case nil: "no sound"
        case true?: "sound"
        case false?: "SILENT"
        }
        let fields = [
            "[\(number)/\(total)]",
            "\(post)",
            file.name,
            report.container ?? "-",
            codecs.isEmpty ? "-" : codecs,
            report.usedHardwareDecode ? "HW" : "SW",
            "\(Int(report.naturalSize.width))x\(Int(report.naturalSize.height))",
            sound,
            "played \(String(format: "%.1f", report.furthest))s of \(String(format: "%.0f", report.duration))s",
            report.seekLanded.map { $0 ? "seek ok" : report.seekEnded ? "seek -> ended (file holds less than it says)" : "seek STUCK" } ?? "no seek",
            problems.isEmpty ? "PASS" : "FAIL: \(problems.joined(separator: "; "))"
        ]
        return fields.joined(separator: " | ")
    }
}
