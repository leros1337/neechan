import Foundation

/// Something a `BoundedQueue` can hold.
protocol QueuedMedia {
    /// How much playing time this holds, in seconds. Zero when unknown.
    var mediaDuration: Double { get }
    /// Roughly what it costs to keep, in bytes.
    var byteCount: Int { get }
}

/// What a caller asking for the next item gets back.
enum QueuePop<Element> {
    case item(Element)
    /// The source ran out and everything queued has been handed over.
    case endOfStream
    /// The queue was closed while waiting, so stop.
    case closed
}

/// The handover between the thread that reads and the thread that decodes.
///
/// Bounded by playing time rather than by a count of items, because that is
/// what decides both how long the reader waits before the first frame and how
/// far ahead the app fetches. Two seconds of a still shot and two seconds of a
/// busy one are worth the same to a viewer and cost wildly different amounts
/// of memory, so there is a byte bound underneath it.
///
/// A push waits while the queue is full and a pop waits while it is empty,
/// exactly as a pipe would, so neither thread spins and neither runs away with
/// the file.
///
/// Every wait ends: closing the queue wakes everybody, which is how a player
/// being torn down stops its threads without waiting for the network.
final class BoundedQueue<Element: QueuedMedia>: @unchecked Sendable {
    /// How much playing time to keep ahead of the renderer.
    let durationLimit: Double
    /// The ceiling underneath it, for streams whose bitrate makes a nonsense
    /// of counting seconds.
    let byteLimit: Int

    private let condition = NSCondition()
    private var items: [Element] = []
    private var queuedDuration: Double = 0
    private var queuedBytes = 0
    /// Bumped by every flush, so work in flight for the old position can be
    /// recognised and dropped rather than shown after a seek.
    private var generation = 0

    /// Told, outside the lock, whenever something lands here.
    ///
    /// The consumer is a renderer that pulls: it asks for media when it has
    /// room and does not ask again until it has taken some. Handed an empty
    /// queue it simply stops asking, and nothing starts it again, so the
    /// picture stops with the file still arriving.
    ///
    /// Told on every push rather than only on the first. A queue that filled
    /// while the renderer was not asking never went empty, so it never said
    /// anything again, and both sides waited for the other.
    var onItemQueued: (@Sendable () -> Void)?
    private var hasEnded = false
    private var isClosed = false

    init(durationLimit: Double = 2, byteLimit: Int = 16 << 20) {
        self.durationLimit = durationLimit
        self.byteLimit = byteLimit
    }

    /// The generation a producer should stamp its work with.
    var currentGeneration: Int {
        condition.lock()
        defer { condition.unlock() }
        return generation
    }

    /// How much playing time is queued.
    var buffered: Double {
        condition.lock()
        defer { condition.unlock() }
        return queuedDuration
    }

    var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return items.isEmpty
    }

    /// Whether everything that will ever arrive has arrived and been taken.
    var isDrained: Bool {
        condition.lock()
        defer { condition.unlock() }
        return hasEnded && items.isEmpty
    }

    /// Adds an item, waiting while the queue is full.
    ///
    /// - Parameter generation: what the producer read before it started this
    ///   piece of work. A push from before a flush is dropped.
    /// - Returns: false when the queue closed or moved on, so the producer can
    ///   stop rather than carry on filling a queue nobody is reading.
    @discardableResult
    func push(_ item: Element, generation pushGeneration: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }

        while !isClosed, generation == pushGeneration, isFullLocked {
            condition.wait()
        }
        guard !isClosed, generation == pushGeneration else { return false }

        items.append(item)
        queuedDuration += max(0, item.mediaDuration)
        queuedBytes += max(0, item.byteCount)
        condition.broadcast()

        if let onItemQueued {
            // Outside the lock: whatever this wakes comes straight back here
            // to take the item.
            condition.unlock()
            onItemQueued()
            condition.lock()
        }
        return true
    }

    /// The next item, waiting while there is none.
    func pop() -> QueuePop<Element> {
        condition.lock()
        defer { condition.unlock() }

        while !isClosed, items.isEmpty, !hasEnded {
            condition.wait()
        }
        guard !isClosed else { return .closed }
        guard let item = takeLocked() else { return .endOfStream }
        return .item(item)
    }

    /// The next item without taking it, for deciding what to do about it.
    func peek() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        return items.first
    }

    /// The next item if one is ready, without waiting.
    ///
    /// For a consumer that is asked for media rather than asking: the
    /// renderer's own callback must never block.
    func take() -> Element? {
        condition.lock()
        defer { condition.unlock() }
        guard !isClosed else { return nil }
        return takeLocked()
    }

    /// Throws away everything queued and moves to a new generation.
    ///
    /// - Returns: the generation producers should use from now on.
    @discardableResult
    func flush() -> Int {
        condition.lock()
        defer { condition.unlock() }
        items.removeAll()
        queuedDuration = 0
        queuedBytes = 0
        hasEnded = false
        generation += 1
        condition.broadcast()
        return generation
    }

    /// Waits until the queue is flushed past `generation`, or closed.
    ///
    /// For a producer that has reached the end of the file. Returning instead
    /// would end its thread, and then nothing is left to answer a reader who
    /// scrubs back into the clip or plays it again.
    ///
    /// - Returns: false when the queue was closed, so the caller should stop.
    func waitForFlush(after generation: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !isClosed, self.generation == generation {
            condition.wait()
        }
        return !isClosed
    }

    /// Says that nothing more will be pushed, so a waiting consumer can stop
    /// waiting once it has taken what is left.
    func finish() {
        condition.lock()
        defer { condition.unlock() }
        hasEnded = true
        condition.broadcast()
    }

    /// Ends every wait, now and in future.
    func close() {
        condition.lock()
        defer { condition.unlock() }
        isClosed = true
        items.removeAll()
        queuedDuration = 0
        queuedBytes = 0
        condition.broadcast()
    }

    private var isFullLocked: Bool {
        !items.isEmpty && (queuedDuration >= durationLimit || queuedBytes >= byteLimit)
    }

    private func takeLocked() -> Element? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        queuedDuration = max(0, queuedDuration - max(0, item.mediaDuration))
        queuedBytes = max(0, queuedBytes - max(0, item.byteCount))
        condition.broadcast()
        return item
    }
}
