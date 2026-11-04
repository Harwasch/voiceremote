import Foundation
import Router
import Policy

/// App-owned disk retention. Replay tombstones contain hashes only; task text
/// and immutable previews expire together. Audit checkpoints are never erased.
public final class RetainedTaskStore: TaskQueueStore, @unchecked Sendable {
    private let store: FileTaskQueueStore
    private let tombstoneURL: URL
    private let accountID: String
    private let now: @Sendable () -> Int64
    private let lock = NSLock()
    private var visible: [QueuedTask] = []
    private var disk: [QueuedTask] = []
    private var tombstones: Set<String>
    public init(url: URL, accountID: String, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        store = try FileTaskQueueStore(url: url); self.accountID = accountID; self.now = now
        tombstoneURL = url.appendingPathExtension("retired")
        tombstones = FileManager.default.fileExists(atPath: tombstoneURL.path)
            ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: tombstoneURL)) : []
        disk = try store.load()
        guard disk.allSatisfy({ $0.command.account_id == accountID }) else { throw RouterError.invalidAuthorization }
        visible = disk
        try maintain()
    }
    private func keys(_ task: QueuedTask) -> Set<String> {
        ["command", "idempotency"].map { kind in
            let value = kind == "command" ? task.command.command_id : task.command.idempotency_key
            return PayloadDigest.sha256(try! JSONEncoder().encode([accountID, kind, value]))
        }.reduce(into: Set<String>()) { $0.insert($1) }
    }
    private func live(_ task: QueuedTask) -> Bool {
        let start = task.command.created_at, time = now()
        return start >= 0 && start <= time && time - start < 604_800_000
    }
    private func persist(_ tasks: [QueuedTask]) throws {
        let expired = tasks.filter { !live($0) || !keys($0).isDisjoint(with: tombstones) }
        let retained = tasks.filter { live($0) && keys($0).isDisjoint(with: tombstones) }
        let next = expired.reduce(into: tombstones) { $0.formUnion(keys($1)) }
        // Tombstone first: a crash must never resurrect an expired command.
        try PrivateJSONFile.write(JSONEncoder().encode(next), to: tombstoneURL)
        tombstones = next
        try store.save(retained, replacing: disk); disk = retained
    }
    public func retainedTasks(_ tasks: [QueuedTask]) -> [QueuedTask] {
        lock.lock(); defer { lock.unlock() }
        return tasks.filter { $0.command.account_id == accountID && live($0) && keys($0).isDisjoint(with: tombstones) }
    }
    public func maintain() throws {
        lock.lock(); defer { lock.unlock() }
        try persist(disk)
    }
    public func load() throws -> [QueuedTask] {
        lock.lock(); defer { lock.unlock() }
        try persist(disk); visible = disk; return visible
    }
    public func save(_ tasks: [QueuedTask], replacing previous: [QueuedTask]) throws {
        lock.lock(); defer { lock.unlock() }
        guard previous == visible, tasks.allSatisfy({ $0.command.account_id == accountID }) else { throw RouterError.persistence }
        for task in tasks where !previous.contains(where: { $0.command == task.command }) {
            guard live(task), keys(task).isDisjoint(with: tombstones) else { throw RouterError.invalidAuthorization }
        }
        try persist(tasks); visible = tasks
    }
}
