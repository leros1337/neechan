/// Undo and redo over whole snapshots of a value.
///
/// An image edit is a few arrays of points, so keeping each step whole is
/// simpler than recording inverse operations, and a capped history keeps a
/// long session from growing without end.
public struct EditHistory<State: Equatable & Sendable>: Sendable {
    public private(set) var current: State
    public let capacity: Int
    private var past: [State] = []
    private var future: [State] = []

    public init(_ initial: State, capacity: Int = 50) {
        current = initial
        self.capacity = max(1, capacity)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }

    /// Makes `state` current as a new step, unless nothing changed.
    public mutating func record(_ state: State) {
        guard state != current else { return }
        past.append(current)
        if past.count > capacity {
            past.removeFirst(past.count - capacity)
        }
        current = state
        future.removeAll()
    }

    public mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(current)
        current = previous
    }

    public mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(current)
        current = next
    }
}
