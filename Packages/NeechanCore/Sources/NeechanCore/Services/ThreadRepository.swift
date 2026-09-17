import Foundation
import NeechanAPI

/// Holds and refreshes one open thread.
///
/// One instance per thread being read. It owns the merge, the reply index and
/// the "which posts are mine" overlay, and publishes a new snapshot whenever
/// any of them changes, so the view never has to reconstruct derived state.
public actor ThreadRepository {
    public let key: ThreadKey

    private let client: DvachClient
    private var snapshot: ThreadSnapshot
    private var index: ReplyIndex
    private var deletedPostNums: Set<Int> = []
    private var ownPostNums: Set<Int> = []
    private var keepDeletedPosts = true
    /// Counts the snapshots built, so the view can recognise one it already has.
    private var generation = 0

    private let stream: AsyncStream<ThreadUpdate>
    private let continuation: AsyncStream<ThreadUpdate>.Continuation

    public init(key: ThreadKey, client: DvachClient) {
        self.key = key
        self.client = client
        self.index = ReplyIndex(thread: key)
        self.snapshot = .empty(key: key)
        (stream, continuation) = AsyncStream<ThreadUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    deinit {
        continuation.finish()
    }

    /// Every change to the thread, for a view to observe.
    public var updates: AsyncStream<ThreadUpdate> { stream }

    public var currentSnapshot: ThreadSnapshot { snapshot }

    /// Whether posts the server deleted stay visible. Turning this off backs
    /// the "clear deleted" action.
    public func setKeepDeletedPosts(_ keep: Bool) {
        keepDeletedPosts = keep
    }

    /// Marks which posts were written from this device.
    ///
    /// Does nothing when the set is unchanged. This is read from the store
    /// before every refresh, and rebuilding the snapshot for an answer that had
    /// not moved was one of the two redundant re-renders each refresh caused.
    public func setOwnPostNums(_ nums: Set<Int>) {
        guard nums != ownPostNums else { return }
        ownPostNums = nums
        rebuildSnapshot()
        continuation.yield(.metaChanged(snapshot))
    }

    // MARK: Loading

    /// Fetches the whole thread, replacing whatever is held.
    @discardableResult
    public func load() async throws(DvachError) -> ThreadSnapshot {
        let response = try await client.thread(board: key.board, num: key.threadNum)
        applyFullLoad(response)
        continuation.yield(.replaced(snapshot))
        return snapshot
    }

    /// Takes a thread that is already in hand, such as one saved to the device,
    /// without going near the network.
    @discardableResult
    public func adopt(_ response: ThreadResponse) -> ThreadSnapshot {
        applyFullLoad(response)
        continuation.yield(.replaced(snapshot))
        return snapshot
    }

    /// Fetches only what is new, falling back to a full load when the
    /// incremental reply cannot be lined up with what is held.
    @discardableResult
    public func refresh() async -> ThreadUpdate {
        guard !snapshot.isEmpty else {
            // Nothing to refresh against; this is really a first load.
            do {
                return .replaced(try await load())
            } catch {
                return .failed(snapshot, error: error)
            }
        }

        // A site with no incremental endpoint reloads instead — a path this
        // already takes whenever the incremental reply cannot be lined up. The
        // cost is paid back by the site's own cache headers, which answer an
        // unchanged thread without sending the body again.
        guard SiteCapabilities.of(key.site).incrementalThreadRefresh else {
            return await reloadFully()
        }

        let anchor = snapshot.meta.maxNum
        do {
            let response = try await client.after(
                board: key.board, thread: key.threadNum, sinceNum: anchor
            )
            let result = ThreadMerger.merge(
                existing: snapshot.posts,
                incoming: response.posts,
                mode: .incremental(anchor: anchor),
                isEndless: snapshot.meta.isEndless,
                keepDeletedPosts: keepDeletedPosts
            )
            if result.needsFullReload {
                return await reloadFully()
            }
            return applyIncremental(result, uniquePosters: response.uniquePosters)
        } catch {
            // The thread may simply be gone. Confirm with a full load rather
            // than trusting one failed incremental call.
            if error.code?.meansMissing == true || isNotFound(error) {
                return await reloadFully()
            }
            return .failed(snapshot, error: error)
        }
    }

    /// Fetches the whole thread again, keeping the reader's overlays.
    @discardableResult
    public func reloadFully() async -> ThreadUpdate {
        do {
            let response = try await client.thread(board: key.board, num: key.threadNum)
            let result = ThreadMerger.merge(
                existing: snapshot.posts,
                incoming: response.posts,
                mode: .full,
                isEndless: response.posts.first?.isEndless ?? snapshot.meta.isEndless,
                keepDeletedPosts: keepDeletedPosts
            )
            deletedPostNums.formUnion(result.deletedPostNums)
            deletedPostNums.subtract(result.trimmedPostNums)

            index = ReplyIndex(posts: result.posts, thread: key)
            var meta = ThreadMeta(response: response)
            meta.isDeleted = false
            rebuildSnapshot(posts: result.posts, meta: meta)

            let update: ThreadUpdate = result.newPostNums.isEmpty
                ? .replaced(snapshot)
                : .appended(snapshot, newPostNums: result.newPostNums)
            continuation.yield(update)
            return update
        } catch {
            if error.code?.meansMissing == true || isNotFound(error) {
                var meta = snapshot.meta
                meta.isDeleted = true
                rebuildSnapshot(meta: meta)
                continuation.yield(.metaChanged(snapshot))
                return .metaChanged(snapshot)
            }
            continuation.yield(.failed(snapshot, error: error))
            return .failed(snapshot, error: error)
        }
    }

    // MARK: Applying

    private func applyFullLoad(_ response: ThreadResponse) {
        deletedPostNums = []
        index = ReplyIndex(posts: response.posts, thread: key)
        rebuildSnapshot(posts: response.posts, meta: ThreadMeta(response: response))
    }

    private func applyIncremental(
        _ result: ThreadMerger.Result,
        uniquePosters: Int
    ) -> ThreadUpdate {
        // A set, because both lists are a whole refresh long and this asks about
        // every post in the thread.
        let changed = Set(result.newPostNums).union(result.updatedPostNums)
        index.append(result.posts.filter { changed.contains($0.num) })

        var meta = snapshot.meta
        meta.maxNum = result.posts.last?.num ?? meta.maxNum
        meta.postsCount = result.posts.count
        meta.filesCount = result.posts.reduce(0) { $0 + $1.files.count }
        if uniquePosters > 0 { meta.uniquePosters = uniquePosters }
        if let op = result.posts.first(where: \.isOriginalPost) {
            meta.isClosed = meta.isClosed || op.isClosed
            meta.isEndless = op.isEndless
        }

        // A poll that found nothing publishes the snapshot it already had.
        // Building an identical one would hand the view a new generation, and
        // the view would redraw every visible post for no change at all — which
        // is exactly what an auto-refresh on a quiet thread does, repeatedly.
        guard changed.isEmpty, meta == snapshot.meta else {
            rebuildSnapshot(posts: result.posts, meta: meta)
            let update: ThreadUpdate = result.newPostNums.isEmpty
                ? .metaChanged(snapshot)
                : .appended(snapshot, newPostNums: result.newPostNums)
            continuation.yield(update)
            return update
        }
        let update = ThreadUpdate.metaChanged(snapshot)
        continuation.yield(update)
        return update
    }

    private func rebuildSnapshot(posts: [Post]? = nil, meta: ThreadMeta? = nil) {
        generation += 1
        snapshot = ThreadSnapshot(
            key: key,
            posts: posts ?? snapshot.posts,
            meta: meta ?? snapshot.meta,
            index: index,
            deletedPostNums: deletedPostNums,
            ownPostNums: ownPostNums,
            generation: generation
        )
    }

    private func isNotFound(_ error: DvachError) -> Bool {
        if case .http(let status, _) = error { return status == 404 }
        return false
    }
}
