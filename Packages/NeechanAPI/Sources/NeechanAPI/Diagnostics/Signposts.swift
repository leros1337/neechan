import Foundation
import os

/// Signpost emitters for the work worth timing in Instruments.
///
/// Lives in NeechanAPI because every other package imports it, and signposts are
/// wanted in all of them. Recording is off unless Instruments is attached, so
/// these stay in release builds: an interval that nobody is listening to costs a
/// predictable branch.
public enum Signposts {
    public static let subsystem = "com.lain.neechan"

    /// One pass of the favourites watcher.
    public static let watcher = OSSignposter(subsystem: subsystem, category: "watcher")
    /// Loading, refreshing and merging a thread.
    public static let thread = OSSignposter(subsystem: subsystem, category: "thread")
    /// Turning comment HTML into `PostContent`.
    public static let parse = OSSignposter(subsystem: subsystem, category: "parse")
    /// Turning `PostContent` into an `AttributedString`.
    public static let render = OSSignposter(subsystem: subsystem, category: "render")
    /// Fetching and decoding images.
    public static let image = OSSignposter(subsystem: subsystem, category: "image")
    /// Autohide rules and search.
    public static let filter = OSSignposter(subsystem: subsystem, category: "filter")
}

extension OSSignposter {
    /// Runs `body` inside a signposted interval.
    ///
    /// The name must be a literal: signpost names are interned at compile time,
    /// which is what keeps an unrecorded interval cheap.
    @inline(__always)
    public func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try body()
    }

    /// Runs an async `body` inside a signposted interval.
    @inline(__always)
    public func measure<T>(
        _ name: StaticString,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let state = beginInterval(name)
        defer { endInterval(name, state) }
        return try await body()
    }
}
