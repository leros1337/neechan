import Synchronization
import Foundation
import Testing
@testable import NeechanMedia

/// A stand-in for a packet or a frame.
private struct Chunk: QueuedMedia {
    var mediaDuration: Double
    var byteCount: Int

    init(_ duration: Double, bytes: Int = 1_000) {
        mediaDuration = duration
        byteCount = bytes
    }
}

/// The handover between the thread that reads and the thread that decodes.
///
/// Every wait here has to end, whatever happens to the file or the network: a
/// thread still waiting on this queue is a player that cannot be torn down,
/// and a gallery paging through clips tears one down for every page.
@Suite("Buffering between threads")
struct BoundedQueueTests {
    /// Runs `work` on another thread and waits for it, so a blocking call can
    /// be watched without hanging the test when it misbehaves.
    private func onAnotherThread(
        timeout: TimeInterval = 5, _ work: @escaping @Sendable () -> Void
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }

    @Test("what goes in comes out, in order")
    func itemsComeBackInOrder() {
        let queue = BoundedQueue<Chunk>(durationLimit: 10)
        queue.push(Chunk(0.1), generation: 0)
        queue.push(Chunk(0.2), generation: 0)

        guard case .item(let first) = queue.pop(), case .item(let second) = queue.pop() else {
            Issue.record("the queue gave back something other than the items pushed")
            return
        }
        #expect(first.mediaDuration == 0.1)
        #expect(second.mediaDuration == 0.2)
        #expect(queue.isEmpty)
    }

    @Test("the queue knows how much playing time it holds")
    func bufferedTimeIsTracked() {
        let queue = BoundedQueue<Chunk>(durationLimit: 10)
        queue.push(Chunk(0.5), generation: 0)
        queue.push(Chunk(0.25), generation: 0)
        #expect(queue.buffered == 0.75)

        _ = queue.pop()
        #expect(queue.buffered == 0.25)
    }

    /// The point of the whole class: the reader must not run away with the
    /// file while the decoder is still on the first second of it.
    @Test("a push waits while the queue is full, and the pop lets it through")
    func pushWaitsWhileFull() {
        let queue = BoundedQueue<Chunk>(durationLimit: 1)
        queue.push(Chunk(2), generation: 0)

        let pushed = Mutex(false)
        let started = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            queue.push(Chunk(0.1), generation: 0)
            pushed.withLock { $0 = true }
        }
        _ = started.wait(timeout: .now() + 1)
        // Long enough that a push which was not going to wait would have run.
        Thread.sleep(forTimeInterval: 0.1)
        #expect(pushed.withLock { $0 } == false, "the queue took more than its limit")

        _ = queue.pop()
        var landed = false
        for _ in 0..<100 where !landed {
            landed = pushed.withLock { $0 }
            if !landed { Thread.sleep(forTimeInterval: 0.02) }
        }
        #expect(landed, "the waiting push was never let through")
    }

    @Test("the byte ceiling holds even when the durations are tiny")
    func byteLimitAlsoBounds() {
        let queue = BoundedQueue<Chunk>(durationLimit: 1_000, byteLimit: 1_000)
        queue.push(Chunk(0.001, bytes: 2_000), generation: 0)

        let secondLanded = onAnotherThread(timeout: 0.3) {
            queue.push(Chunk(0.001, bytes: 10), generation: 0)
        }
        #expect(!secondLanded, "the queue went past its byte ceiling")
        queue.close()
    }

    @Test("a pop waits for an item rather than returning nothing")
    func popWaitsWhenEmpty() {
        let queue = BoundedQueue<Chunk>()
        let returned = onAnotherThread(timeout: 0.3) { _ = queue.pop() }
        #expect(!returned, "an empty queue answered instead of waiting")
        queue.close()
    }

    @Test("asking without waiting gives nothing when there is nothing")
    func takeDoesNotWait() {
        let queue = BoundedQueue<Chunk>()
        #expect(queue.take() == nil)
        queue.push(Chunk(0.1), generation: 0)
        #expect(queue.take()?.mediaDuration == 0.1)
    }

    /// What a seek does. Work already in flight for the old position must not
    /// be shown at the new one.
    @Test("a flush empties the queue and refuses work from before it")
    func flushDropsStaleWork() {
        let queue = BoundedQueue<Chunk>(durationLimit: 10)
        queue.push(Chunk(0.1), generation: 0)

        let generation = queue.flush()
        #expect(generation == 1)
        #expect(queue.isEmpty)
        #expect(queue.buffered == 0)

        #expect(queue.push(Chunk(0.1), generation: 0) == false, "a stale push was accepted")
        #expect(queue.isEmpty)
        #expect(queue.push(Chunk(0.1), generation: generation))
    }

    /// The renderers are fed from the queues on a thread of their own, and a
    /// seek empties the queues a moment before it gives the renderers a fresh
    /// start. What the decoders produce for the new position in that moment
    /// went into the renderers about to be thrown away, and the sound after a
    /// seek began late, or not until the clock caught up with it.
    @Test("taking for a generation leaves a newer one's items where they are")
    func takeForAGenerationWaitsForTheConsumer() {
        let queue = BoundedQueue<Chunk>()
        let before = queue.currentGeneration
        queue.push(Chunk(0.1), generation: before)
        #expect(queue.take(inGeneration: before) != nil)

        let after = queue.flush()
        queue.push(Chunk(0.2), generation: after)
        #expect(queue.take(inGeneration: before) == nil, "an item from after the flush went to a consumer that had not caught up")
        #expect(queue.buffered == 0.2, "the item was lost rather than left")
        #expect(queue.take(inGeneration: after)?.mediaDuration == 0.2)
    }

    /// A decoder asked for the generation, then waited for a packet. A seek in
    /// between handed it the new position's keyframe under the old
    /// generation, so what it decoded was thrown away; on its next turn it saw
    /// the new generation and reset itself, throwing away the keyframe too.
    /// Nothing then decoded until the next keyframe, seconds away.
    @Test("a pop says which generation it belongs to, even when a flush came while it waited")
    func popCarriesItsGeneration() {
        let queue = BoundedQueue<Chunk>()
        let before = queue.currentGeneration

        let popped = Mutex<Int?>(nil)
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let (next, generation) = queue.popStamped()
            if case .item = next { popped.withLock { $0 = generation } }
            returned.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        let after = queue.flush()
        queue.push(Chunk(0.1), generation: after)

        #expect(returned.wait(timeout: .now() + 2) == .success, "the pop never returned")
        #expect(after != before)
        #expect(popped.withLock { $0 } == after, "the item came back stamped \(String(describing: popped.withLock { $0 }))")
    }

    /// A seek flushes the packet queues a moment before the queues of decoded
    /// media. A decoder that was idle wakes on the first flush, and the sound
    /// decoder could get through every packet left in the file before the
    /// second: each run was stamped with a generation its queue had not
    /// reached yet, refused as if it were stale, and the clip played silent
    /// until some later seek won the race.
    @Test("a push from a generation the queue has not reached yet waits for it")
    func pushFromAheadWaitsForTheFlush() {
        let queue = BoundedQueue<Chunk>()
        let ahead = queue.currentGeneration + 1

        let accepted = Mutex<Bool?>(nil)
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let result = queue.push(Chunk(0.1), generation: ahead)
            accepted.withLock { $0 = result }
            returned.signal()
        }
        #expect(returned.wait(timeout: .now() + 0.2) == .timedOut, "the push gave up instead of waiting")

        #expect(queue.flush() == ahead)
        #expect(returned.wait(timeout: .now() + 2) == .success, "the flush did not release the push")
        #expect(accepted.withLock { $0 } == true, "the push was refused once the queue caught up")
        #expect(queue.buffered == 0.1)
    }

    @Test("a push from ahead is released when the queue closes")
    func pushFromAheadEndsOnClose() {
        let queue = BoundedQueue<Chunk>()
        let ahead = queue.currentGeneration + 1
        let accepted = Mutex<Bool?>(nil)
        let returned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let result = queue.push(Chunk(0.1), generation: ahead)
            accepted.withLock { $0 = result }
            returned.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        queue.close()

        #expect(returned.wait(timeout: .now() + 2) == .success, "closing did not release the push")
        #expect(accepted.withLock { $0 } == false)
    }

    @Test("a producer waiting on a full queue is released by a flush")
    func flushReleasesAWaitingPush() {
        let queue = BoundedQueue<Chunk>(durationLimit: 1)
        queue.push(Chunk(2), generation: 0)

        let released = DispatchSemaphore(value: 0)
        let accepted = Mutex(true)
        Thread.detachNewThread {
            let result = queue.push(Chunk(0.1), generation: 0)
            accepted.withLock { $0 = result }
            released.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        _ = queue.flush()

        #expect(released.wait(timeout: .now() + 2) == .success, "the push was never released")
        #expect(accepted.withLock { $0 } == false, "a push from before the flush was accepted")
    }

    @Test("the end of the file reaches a waiting consumer")
    func finishEndsTheWait() {
        let queue = BoundedQueue<Chunk>()
        let answered = DispatchSemaphore(value: 0)
        let result = Mutex("")
        Thread.detachNewThread {
            if case .endOfStream = queue.pop() { result.withLock { $0 = "end" } }
            answered.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        queue.finish()

        #expect(answered.wait(timeout: .now() + 2) == .success)
        #expect(result.withLock { $0 } == "end")
    }

    @Test("everything queued is handed over before the end is reported")
    func finishDrainsFirst() {
        let queue = BoundedQueue<Chunk>(durationLimit: 10)
        queue.push(Chunk(0.1), generation: 0)
        queue.finish()

        guard case .item = queue.pop() else {
            Issue.record("the queue reported the end while it still held an item")
            return
        }
        guard case .endOfStream = queue.pop() else {
            Issue.record("the queue did not report the end once it was empty")
            return
        }
        #expect(queue.isDrained)
    }

    /// Tearing a player down must not wait for the network.
    @Test("closing releases everyone waiting, on both sides")
    func closeReleasesEveryone() {
        let queue = BoundedQueue<Chunk>(durationLimit: 1)
        queue.push(Chunk(2), generation: 0)

        let bothReturned = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = queue.push(Chunk(0.1), generation: 0)
            bothReturned.signal()
        }
        Thread.detachNewThread {
            _ = queue.pop()
            _ = queue.pop()
            bothReturned.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        queue.close()

        #expect(bothReturned.wait(timeout: .now() + 2) == .success, "a waiting thread was left waiting")
        #expect(bothReturned.wait(timeout: .now() + 2) == .success, "a waiting thread was left waiting")

        if case .closed = queue.pop() {} else {
            Issue.record("a closed queue did not say so")
        }
        #expect(queue.push(Chunk(0.1), generation: queue.currentGeneration) == false)
    }
}
