//===----------------------------------------------------------------------===//
//
// This source file is part of the StateManagement package open source project
//
// Copyright (c) 2025-2035 Maxim Bazarov and the StateManagement package
// open source project authors
// Licensed under MIT
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: MIT
//
//===----------------------------------------------------------------------===//

import Foundation

/// What one sourced Address (or one entry of a Keyed one) is doing right now.
@MainActor
final class StrategyRecord {
    let handle: any AsyncStateHandle
    var sourcedID: ValueID?
    var statusID: ValueID?
    var dirty = false
    var didRead = false
    let key: AnyHashable?

    /// Every ValueID this record answers to: the sourced Address, the status Address, and the
    /// `$` Address. Inbound State notifies all of them, so a reader that subscribed through one
    /// of them still hears the change.
    var addresses: Set<ValueID> = []

    /// Awaitable `$` reads suspended on this Address. Keyed by token so Cancel releases
    /// only its own waiter.
    private var waiters: [UUID: (SourcedResume) -> Void] = [:]

    init(handle: any AsyncStateHandle, key: AnyHashable?) {
        self.handle = handle
        self.key = key
    }

    func addWaiter(_ token: UUID, _ resume: @escaping (SourcedResume) -> Void) {
        waiters[token] = resume
    }

    /// Resumes every waiter once. Drained before the callbacks run, so a second
    /// resume of the same token finds nothing.
    func resumeWaiters(with outcome: SourcedResume) {
        let pending = waiters
        waiters = [:]
        for resume in pending.values {
            resume(outcome)
        }
    }

    func resumeWaiter(_ token: UUID, with outcome: SourcedResume) {
        guard let resume = waiters.removeValue(forKey: token) else { return }
        resume(outcome)
    }
}

/// The seam the Environment plugs a Satellite into: strategy instances, per-Address records, and
/// the sourced branch of read and write.
///
/// ``SharedEnvironment`` keeps one `let` to this and forwards; everything the seam owns lives
/// here, so `strategyWarehouse`, `pendingHandle`, and the record table never become public API.
@MainActor
final class AsyncStateRuntime {

    /// The Environment this runtime serves. It owns the runtime, so the reference is unowned.
    unowned let environment: SharedEnvironment

    /// One instance per concrete strategy type. The type is the warehouse key.
    private var strategyWarehouse: [ObjectIdentifier: any AsyncStrategy] = [:]

    private var records: [ValueID: StrategyRecord] = [:]

    /// The wrapper the key-path walk in flight went through, if any.
    private var pendingHandle: (any AsyncStateHandle)?

    private var standingEnvironment: AsyncStrategyEnvironment?

    /// Addresses that carried no wrapper on their first read. A plain Value never grows one, so
    /// later reads skip the capture walk and cost one property access.
    private var plainAddresses: Set<AnyKeyPath> = []

    init(_ environment: SharedEnvironment) {
        self.environment = environment
    }

    // MARK: - Handle capture

    @MainActor
    private enum StrategyAccess {
        static var current: AsyncStateRuntime?
    }

    static func noteHandleRead(_ handle: any AsyncStateHandle) {
        StrategyAccess.current?.pendingHandle = handle
    }

    /// Runs `body` with handle capture armed, so a wrapper read inside it registers itself.
    private func capturingHandle(_ body: () -> Void) {
        let previous = StrategyAccess.current
        StrategyAccess.current = self
        body()
        StrategyAccess.current = previous
    }

    /// Reads a wrapper without arming capture, so an inbound verb does not disturb a walk in flight.
    private func wrapper<Storage: StateContainer, Wrapper>(
        at address: KeyPath<Storage, Wrapper>
    ) -> Wrapper {
        let previous = StrategyAccess.current
        StrategyAccess.current = nil
        defer { StrategyAccess.current = previous }
        return environment.getStorage(Storage.self)[keyPath: address]
    }

    /// Walks `keyPath` twice around `onHandle`: once to find the wrapper, once to snapshot the
    /// Value an inbound `apply` inside the kick may have already changed.
    private func withHandle<Storage: StateContainer, Value>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, Value>,
        onHandle: (any AsyncStateHandle) -> Void
    ) -> Value {
        if plainAddresses.contains(keyPath) {
            return storage[keyPath: keyPath]
        }
        let previousAccess = StrategyAccess.current
        let previousHandle = pendingHandle
        StrategyAccess.current = self
        pendingHandle = nil
        _ = storage[keyPath: keyPath]
        let handle = pendingHandle
        if let handle {
            onHandle(handle)
        } else {
            plainAddresses.insert(keyPath)
        }
        let value = storage[keyPath: keyPath]
        pendingHandle = previousHandle
        StrategyAccess.current = previousAccess
        return value
    }

    // MARK: - The sourced branch of read

    /// A read of an Atomic Address, or of any Value that is not a dictionary.
    func accessSourced<Storage: StateContainer, Value>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, Value>
    ) -> Value {
        withHandle(storage, keyPath: keyPath) { handle in
            activate(handle, keyPath: keyPath, key: nil)
        }
    }

    /// A read of a dictionary Address. It names the whole dictionary, which is never a seam
    /// Address, so this binds the wrapper and kicks nothing.
    func accessSourced<Storage: StateContainer, Key: Hashable, Entry>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, [Key: Entry]>
    ) -> [Key: Entry] {
        withHandle(storage, keyPath: keyPath) { handle in
            handle.bind(environment: environment)
        }
    }

    /// A read of one entry of a dictionary Address. This one is a seam Address, so it kicks.
    func accessSourcedEntry<Storage: StateContainer, Key: Hashable, Entry>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, [Key: Entry]>,
        key: Key
    ) -> [Key: Entry] {
        withHandle(storage, keyPath: keyPath) { handle in
            activate(handle, keyPath: keyPath, key: AnyHashable(key))
        }
    }

    /// Activates a sourced Address through its `$` Address, with the key when Keyed.
    func sourcedWrapper<Storage: StateContainer, Wrapper>(
        keyPath: KeyPath<Storage, Wrapper>,
        key: AnyHashable?
    ) -> Wrapper {
        withHandle(environment.getStorage(Storage.self), keyPath: keyPath) { handle in
            activate(handle, keyPath: keyPath, key: key)
        }
    }

    private func activate<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) {
        // `refresh()` on the wrapper needs the Environment that bound it.
        handle.bind(environment: environment)
        let valueID = makeValueID(keyPath: keyPath, key: key)
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: key)
        handle.seedPendingStatus(key: key)
        if !record.didRead {
            record.didRead = true
            kickOnRead(record)
            return
        }
        if record.dirty {
            kickOnRead(record)
        }
    }

    // MARK: - The sourced branch of write

    /// Runs an app write with handle capture armed, then settles and kicks `onWrite` if the
    /// Address turned out to be sourced. A plain Address costs the capture and nothing else.
    func writing<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?,
        mutate: () -> Void
    ) {
        pendingHandle = nil
        capturingHandle(mutate)
        guard let handle = pendingHandle else { return }
        finishAppWrite(handle, keyPath: keyPath, key: key)
    }

    /// Runs an app `remove` the same way, evicting rather than telling the strategy.
    func removing<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>,
        key: AnyHashable,
        mutate: () -> Void
    ) {
        pendingHandle = nil
        capturingHandle(mutate)
        guard let handle = pendingHandle else { return }
        evict(handle, keyPath: keyPath, key: key)
    }

    private func finishAppWrite<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) {
        let valueID = makeValueID(keyPath: keyPath, key: key)
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: key)
        record.didRead = true
        record.dirty = false
        handle.settleAfterAppWrite(key: key)
        record.resumeWaiters(with: .inbound)
        if let statusID = record.statusID {
            environment.observation.invalidateValue(at: statusID)
        }
        handle.kickOnWrite(key: key, in: self)
    }

    /// `remove` on a sourced keyed Address evicts: the entry is already gone, the status goes back
    /// to `.pending`, that key's record is dropped and its waiters released, and nothing is kicked
    /// outward. The next read is a first read and reloads.
    private func evict<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable
    ) {
        handle.evictStatus(key: key)
        let valueID = makeValueID(keyPath: keyPath, key: key)
        guard let record = records[valueID] else { return }
        record.resumeWaiters(with: .released)
        for address in record.addresses {
            records[address] = nil
        }
    }

    // MARK: - Records

    private func makeValueID<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> ValueID {
        if let key {
            return ValueID(keyPath: keyPath, key: key)
        }
        return ValueID(keyPath: keyPath)
    }

    private func record<Storage: StateContainer, Value>(
        for handle: any AsyncStateHandle,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> StrategyRecord {
        if let existing = records[valueID] {
            existing.addresses.insert(valueID)
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        if let existing = uniqueRecords.first(where: {
            ObjectIdentifier($0.handle) == ObjectIdentifier(handle) && $0.key == key
        }) {
            records[valueID] = existing
            existing.addresses.insert(valueID)
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        let created = StrategyRecord(handle: handle, key: key)
        records[valueID] = created
        created.addresses.insert(valueID)
        classify(created, valueID: valueID, keyPath: keyPath, handle: handle)
        return created
    }

    private var uniqueRecords: [StrategyRecord] {
        var seen: [ObjectIdentifier: StrategyRecord] = [:]
        for record in records.values {
            seen[ObjectIdentifier(record)] = record
        }
        return Array(seen.values)
    }

    private func classify<Storage: StateContainer, Value>(
        _ record: StrategyRecord,
        valueID: ValueID,
        keyPath: KeyPath<Storage, Value>,
        handle: any AsyncStateHandle
    ) {
        if handle.statusKeyPath == keyPath {
            record.statusID = valueID
        }
        if handle.sourcedKeyPath == keyPath {
            record.sourcedID = valueID
        }
        if record.sourcedID == nil, record.statusID == nil {
            record.sourcedID = valueID
        }
    }

    func record(at valueID: ValueID) -> StrategyRecord? {
        records[valueID]
    }

    private func recordMatching<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> StrategyRecord? {
        let id = makeValueID(keyPath: keyPath, key: key)
        if let record = records[id] {
            return record
        }
        if let match = uniqueRecords.first(where: { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }) {
            records[id] = match
            match.addresses.insert(id)
            match.sourcedID = id
            return match
        }
        bindWrapper(keyPath: keyPath, key: key)
        if let record = records[id] {
            return record
        }
        return uniqueRecords.first { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }
    }

    /// Opens the record for an Address inbound reached before anyone read it — an `apply` from a
    /// push, say. It binds and records but does not activate: inbound is not a read, so it must
    /// not kick `onRead`, and `didRead` stays false so the first real read still does (R17).
    private func bindWrapper<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) {
        _ = withHandle(environment.getStorage(Storage.self), keyPath: keyPath) { handle in
            handle.bind(environment: environment)
            let valueID = makeValueID(keyPath: keyPath, key: key)
            _ = record(for: handle, valueID: valueID, keyPath: keyPath, key: key)
            handle.seedPendingStatus(key: key)
        }
    }

    private static func addressMatches(_ handle: any AsyncStateHandle, keyPath: AnyKeyPath) -> Bool {
        handle.sourcedKeyPath == keyPath
            || handle.storageValueKeyPath == keyPath
            || handle.dollarKeyPath == keyPath
            || handle.wrapperKeyPath == keyPath
    }

    // MARK: - Strategy instances

    func strategyEnvironment() -> AsyncStrategyEnvironment {
        if let existing = standingEnvironment {
            return existing
        }
        let created = AsyncStrategyEnvironment(environment)
        standingEnvironment = created
        return created
    }

    func install<Str: AsyncStrategy>(_ strategy: Str) {
        strategyWarehouse[ObjectIdentifier(Str.self)] = strategy
    }

    func strategyInstance<Str: AsyncStrategy>(_ type: Str.Type) -> Str {
        let id = ObjectIdentifier(Str.self)
        if let existing = strategyWarehouse[id] {
            // Type is keyed by ObjectIdentifier of Str.self.
            return unsafeDowncast(existing, to: Str.self)
        }
        let created = Str(env: strategyEnvironment())
        strategyWarehouse[id] = created
        return created
    }

    // MARK: - Kicks and notification

    func kickOnRead(_ record: StrategyRecord) {
        record.handle.kickOnRead(key: record.key, in: self)
    }

    private func notify(_ record: StrategyRecord?) {
        guard let record else { return }
        if let sourcedID = record.sourcedID {
            environment.observation.invalidateValue(at: sourcedID)
        }
        if let statusID = record.statusID {
            environment.observation.invalidateValue(at: statusID)
        }
        // The sourced Address can be learned after a `$`-first read, so a reader that
        // subscribed through the earlier ValueID must still be notified.
        for address in record.addresses {
            environment.observation.invalidateValue(at: address)
        }
    }

    // MARK: - Inbound

    func apply<Storage: StateContainer, Str: AsyncStrategy, Value>(
        _ value: Value,
        at address: KeyPath<Storage, AsyncState<Str, NoKey, Value, Value>>
    ) {
        let record = recordMatching(keyPath: address, key: nil)
        wrapper(at: address).applyInbound(value)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        notify(record)
    }

    func apply<Storage: StateContainer, Str: AsyncStrategy, Key: Hashable, Entry>(
        _ value: Entry?,
        at address: KeyPath<Storage, AsyncState<Str, Key, Entry, [Key: Entry]>>,
        key: Key
    ) {
        let record = recordMatching(keyPath: address, key: AnyHashable(key))
        wrapper(at: address).applyInbound(value, key: key)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        notify(record)
    }

    func fail<Storage: StateContainer, Str: AsyncStrategy, Value>(
        _ error: Str.Failure,
        at address: KeyPath<Storage, AsyncState<Str, NoKey, Value, Value>>
    ) {
        let record = recordMatching(keyPath: address, key: nil)
        wrapper(at: address).failInbound(error)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        if let statusID = record?.statusID {
            environment.observation.invalidateValue(at: statusID)
        }
    }

    func fail<Storage: StateContainer, Str: AsyncStrategy, Key: Hashable, Entry>(
        _ error: Str.Failure,
        at address: KeyPath<Storage, AsyncState<Str, Key, Entry, [Key: Entry]>>,
        key: Key
    ) {
        let record = recordMatching(keyPath: address, key: AnyHashable(key))
        wrapper(at: address).failInbound(error, key: key)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        if let statusID = record?.statusID {
            environment.observation.invalidateValue(at: statusID)
        }
    }

    func markStale<Storage: StateContainer, Value>(
        at keyPath: KeyPath<Storage, Value>,
        keys: [AnyHashable?]
    ) {
        for key in keys {
            let record = recordMatching(keyPath: keyPath, key: key)
            record?.dirty = true
            if let sourcedID = record?.sourcedID {
                environment.observation.invalidateValue(at: sourcedID)
            }
        }
    }

    // MARK: - Refresh

    /// `AsyncState.refresh()`: dirty plus kick `onRead`, one Operation for every key.
    /// The status is unchanged until `apply` or `fail`, so there is nothing to notify.
    func refresh(handle: any AsyncStateHandle, keys: [AnyHashable?]) {
        let matched = keys.compactMap { key in
            boundRecord(for: handle, key: key)
        }
        guard !matched.isEmpty else {
            asyncStateLogger.debug("refresh() before the Address was read: no-op")
            return
        }
        environment.perform(StrategyWrite { runtime in
            for record in matched {
                record.dirty = true
                runtime.kickOnRead(record)
            }
        })
    }

    /// `Watch.$property.refresh()`: same Operation, addressed by the ValueID the Watch reads.
    func refresh(at valueID: ValueID) {
        guard let record = records[valueID] else {
            asyncStateLogger.debug("refresh() of an Address with no AsyncStrategy: no-op")
            return
        }
        environment.perform(StrategyWrite { runtime in
            record.dirty = true
            runtime.kickOnRead(record)
        })
    }

    private func boundRecord(
        for handle: any AsyncStateHandle,
        key: AnyHashable?
    ) -> StrategyRecord? {
        records.values.first { record in
            ObjectIdentifier(record.handle) == ObjectIdentifier(handle) && record.key == key
        }
    }

    // MARK: - Lifecycle

    func resetAll() {
        dropAllRecords()
        strategyWarehouse.removeAll()
    }

    func dropAllRecords() {
        for record in uniqueRecords {
            endRecord(record)
        }
        records.removeAll()
    }

    func dropRecords<Storage: StateContainer>(in type: Storage.Type) {
        var kept: [ValueID: StrategyRecord] = [:]
        var ended: Set<ObjectIdentifier> = []
        for (id, record) in records {
            if recordBelongs(record, to: type) {
                let token = ObjectIdentifier(record)
                if ended.insert(token).inserted {
                    endRecord(record)
                }
            } else {
                kept[id] = record
            }
        }
        records = kept
    }

    private func recordBelongs<Storage: StateContainer>(
        _ record: StrategyRecord,
        to type: Storage.Type
    ) -> Bool {
        record.handle.sourcedKeyPath is PartialKeyPath<Storage>
            || record.handle.statusKeyPath is PartialKeyPath<Storage>
            || record.handle.storageValueKeyPath is PartialKeyPath<Storage>
            || record.handle.dollarKeyPath is PartialKeyPath<Storage>
            || record.handle.wrapperKeyPath is PartialKeyPath<Storage>
    }

    private func endRecord(_ record: StrategyRecord) {
        // Cancel is not a throw: a hanging awaitable read returns the current Value.
        record.resumeWaiters(with: .released)
        record.handle.kickOnDrop(key: record.key, in: self)
    }
}
