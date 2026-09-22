import Foundation

/// Reading a thread from bytes that are already on this device.
///
/// Every public decode on ``DvachClient`` sends a request first, which is the
/// one thing a saved thread must not do: it is read with no network by
/// definition. This is the same per-site decode with the request taken out of
/// it, and it is the only reason ``SiteAdapter`` needs a door to the outside.
///
/// It exists because the shapes differ. 2ch's thread file *is* the neutral
/// model, so a bare `JSONDecoder` reads it; 4chan's carries `{"posts": […]}`
/// and nothing else, and has to go through its own mapping to become posts at
/// all. Handing stored bytes to the wrong one of those is silent: the decode
/// throws, and a caller that swallows the error reports a missing thread
/// rather than an unreadable one.
public enum StoredThread {
    /// Decodes a thread the way `selection`'s site writes them.
    ///
    /// - Parameter board: the board the thread belongs to. Required rather than
    ///   optional because 4chan's static files carry no board object and its
    ///   mapping refuses without one — and a board cannot be fetched while
    ///   offline, which is the only condition this is called under. A
    ///   placeholder is a reasonable thing to pass: `DvachClient` builds one
    ///   itself when a board's metadata is missing. 2ch ignores the argument
    ///   entirely, since its own board object is inside the bytes.
    public static func response(
        from data: Data,
        on selection: SiteSelection,
        board: Board,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> ThreadResponse {
        try selection.site.adapter.thread(
            from: data,
            board: board,
            endpoints: selection.endpoints,
            decoder: decoder
        )
    }
}
