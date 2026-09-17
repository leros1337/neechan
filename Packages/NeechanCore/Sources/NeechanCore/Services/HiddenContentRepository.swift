import Foundation
import NeechanAPI
import SwiftData

/// A thread the reader hid, as a value.
public struct HiddenThreadItem: Sendable, Hashable, Identifiable {
    public let key: ThreadKey
    public let title: String
    public let hiddenAt: Date

    public var id: ThreadKey { key }

    public init(key: ThreadKey, title: String, hiddenAt: Date) {
        self.key = key
        self.title = title
        self.hiddenAt = hiddenAt
    }
}

/// Threads and posts the reader has hidden, and the rules that hide them.
@ModelActor
public actor HiddenContentRepository {

    /// What the reader is willing to be shown. Read per query, so turning a
    /// restriction on takes effect without rebuilding this actor.
    private nonisolated let policyPort = ContentPolicyPort()

    /// - Parameter policy: read on every listing, never stored as a value.
    public init(modelContainer: ModelContainer, policy: @escaping ContentPolicyProvider) {
        self.init(modelContainer: modelContainer)
        policyPort.use(policy)
    }
    // MARK: Threads

    public func hideThread(_ key: ThreadKey, title: String) throws {
        guard try storedHiddenThread(key) == nil else { return }
        modelContext.insert(HiddenThread(key: key, title: title))
        try modelContext.save()
    }

    public func unhideThread(_ key: ThreadKey) throws {
        guard let stored = try storedHiddenThread(key) else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    /// Thread numbers hidden on one board.
    public func hiddenThreadNums(on board: BoardRef) throws -> Set<Int> {
        let site = board.site.rawValue
        let code = board.code
        let descriptor = FetchDescriptor<HiddenThread>(
            predicate: #Predicate { $0.siteRaw == site && $0.board == code }
        )
        return Set(try modelContext.fetch(descriptor).map(\.threadNum))
    }

    /// Everything hidden on one imageboard, most recently hidden first.
    public func hiddenThreads(site: Imageboard) throws -> [HiddenThreadItem] {
        let siteRaw = site.rawValue
        return try modelContext.fetch(
            FetchDescriptor<HiddenThread>(
                predicate: #Predicate { $0.siteRaw == siteRaw },
                sortBy: [SortDescriptor(\.hiddenAt, order: .reverse)]
            )
        )
        .filter { policyPort.policy.allows(code: $0.board, on: site) }
        .map { HiddenThreadItem(key: $0.key, title: $0.title, hiddenAt: $0.hiddenAt) }
    }

    /// Unhides everything on one imageboard.
    ///
    /// Scoped, because the screen offering it lists one site: unhiding threads
    /// the reader cannot see is not what the button says.
    public func unhideAllThreads(site: Imageboard) throws {
        let siteRaw = site.rawValue
        try modelContext.delete(
            model: HiddenThread.self,
            where: #Predicate { $0.siteRaw == siteRaw }
        )
        try modelContext.save()
    }

    // MARK: Per-thread post rules

    public func addLocalRule(_ rule: LocalHideRule, in thread: ThreadKey) throws {
        modelContext.insert(HiddenPostRule(key: thread, rule: rule))
        try modelContext.save()
    }

    public func localRules(in thread: ThreadKey) throws -> [LocalHideRule] {
        try storedLocalRules(in: thread).compactMap(\.rule)
    }

    /// Rules with the identity needed to remove one from the hidden-posts list.
    public func localRuleEntries(
        in thread: ThreadKey
    ) throws -> [(id: PersistentIdentifier, rule: LocalHideRule)] {
        try storedLocalRules(in: thread).compactMap { stored in
            stored.rule.map { (stored.persistentModelID, $0) }
        }
    }

    public func removeLocalRule(id: PersistentIdentifier) throws {
        guard let stored = modelContext.model(for: id) as? HiddenPostRule else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    public func clearLocalRules(in thread: ThreadKey) throws {
        for stored in try storedLocalRules(in: thread) {
            modelContext.delete(stored)
        }
        try modelContext.save()
    }

    // MARK: Autohide rules

    public func addRule(_ value: AutohideRuleValue) throws {
        let count = try modelContext.fetchCount(FetchDescriptor<AutohideRule>())
        modelContext.insert(AutohideRule(value: value, sortOrder: count))
        try modelContext.save()
    }

    public func updateRule(_ value: AutohideRuleValue) throws {
        guard let stored = try storedRule(id: value.id) else { return }
        stored.apply(value)
        try modelContext.save()
    }

    public func removeRule(id: UUID) throws {
        guard let stored = try storedRule(id: id) else { return }
        modelContext.delete(stored)
        try modelContext.save()
    }

    /// Every autohide rule, on every imageboard.
    ///
    /// Site-blind on purpose. A rule carries its own scope, and the editor
    /// shows that scope: a list that hid half the reader's rules depending on
    /// which site was selected would be the wrong screen. `FilterEngine` does
    /// the filtering, through `AutohideRuleValue.appliesTo(thread:)`.
    public func rules() throws -> [AutohideRuleValue] {
        try modelContext.fetch(
            FetchDescriptor<AutohideRule>(sortBy: [SortDescriptor(\.sortOrder)])
        )
        .map(\.value)
    }

    // MARK: Internals

    private func storedHiddenThread(_ key: ThreadKey) throws -> HiddenThread? {
        let site = key.site.rawValue
        let board = key.board
        let threadNum = key.threadNum
        var descriptor = FetchDescriptor<HiddenThread>(
            predicate: #Predicate {
                $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func storedLocalRules(in thread: ThreadKey) throws -> [HiddenPostRule] {
        let site = thread.site.rawValue
        let board = thread.board
        let threadNum = thread.threadNum
        return try modelContext.fetch(
            FetchDescriptor<HiddenPostRule>(
                predicate: #Predicate {
                    $0.siteRaw == site && $0.board == board && $0.threadNum == threadNum
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
    }

    private func storedRule(id: UUID) throws -> AutohideRule? {
        var descriptor = FetchDescriptor<AutohideRule>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
