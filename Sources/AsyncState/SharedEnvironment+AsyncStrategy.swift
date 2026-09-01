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

extension SharedEnvironment {
    @MainActor
    private enum StrategyAccess {
        static var current: SharedEnvironment?
    }

    static func noteHandleRead(_ handle: any AsyncStateHandle) {
        StrategyAccess.current?.pendingHandle = handle
    }

    func capturingHandle(_ body: () -> Void) {
        let previous = StrategyAccess.current
        StrategyAccess.current = self
        body()
        StrategyAccess.current = previous
    }

    func strategyEnvironment() -> AsyncStrategyEnvironment {
        if let existing = standingStrategyEnvironment {
            return existing
        }
        let created = AsyncStrategyEnvironment(self)
        standingStrategyEnvironment = created
        return created
    }

    func install<S: AsyncStrategy>(_ strategy: S) {
        strategyWarehouse[ObjectIdentifier(S.self)] = strategy
    }

    func strategyInstance<S: AsyncStrategy>(_ type: S.Type) -> S {
        let id = ObjectIdentifier(S.self)
        if let existing = strategyWarehouse[id] {
            // Type is keyed by ObjectIdentifier of S.self.
            return unsafeDowncast(existing, to: S.self)
        }
        let created = S(env: strategyEnvironment())
        strategyWarehouse[id] = created
        return created
    }

    /// Calls `onRead` for a sourced Address without a Watch. Same as first read.
    public func preheat<Storage: StateContainer, Value>(
        _ keyPath: KeyPath<Storage, Value>
    ) {
        _ = read(keyPath)
    }

    /// Calls `onRead` for a keyed sourced Address without a Watch. Same as first read.
    public func preheat<Storage: StateContainer, Key: Hashable, Value>(
        _ keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        _ = read(keyPath, key: key)
    }

    func accessSourced<Storage: StateContainer, Value>(
        _ storage: Storage,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> Value {
        let previousAccess = StrategyAccess.current
        let previousHandle = pendingHandle
        StrategyAccess.current = self
        pendingHandle = nil
        _ = storage[keyPath: keyPath]
        let handle = pendingHandle
        if let handle {
            activate(handle, keyPath: keyPath, key: key)
        }
        // First walk records the handle and may `onRead`. Nested `apply` writes before this snapshot.
        let value = storage[keyPath: keyPath]
        pendingHandle = previousHandle
        StrategyAccess.current = previousAccess
        return value
    }

    func activate<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) {
        // `refresh()` on the wrapper needs the Environment that bound it, even for a keyed
        // Address read without a key.
        handle.bind(environment: self)
        if handle.isKeyed, key == nil {
            return
        }
        let valueID = makeValueID(keyPath: keyPath, key: key)
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: key)
        handle.seedKeyedPending(key: key)
        if !record.didRead {
            record.didRead = true
            onRead(record)
            return
        }
        if record.dirty {
            onRead(record)
        }
    }

    func finishAppWrite<Storage: StateContainer, Value>(
        _ handle: any AsyncStateHandle,
        value: Value,
        keyPath: KeyPath<Storage, Value>
    ) {
        if handle.statusKeyPath == keyPath {
            return
        }
        let valueID = makeValueID(keyPath: keyPath, key: nil)
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: nil)
        record.didRead = true
        record.dirty = false
        handle.writeDeliver(value)
        record.resumeWaiters(with: .inbound)
        if let statusID = record.statusID {
            observation.invalidateValue(at: statusID)
        }
        let strategy = handle.resolveStrategy(in: self)
        handle.callOnWrite(strategy, value: value)
    }

    func finishAppWrite<Storage: StateContainer, Key: Hashable, Value>(
        _ handle: any AsyncStateHandle,
        value: Value,
        keyPath: KeyPath<Storage, [Key: Value]>,
        key: Key
    ) {
        if handle.statusKeyPath == keyPath {
            return
        }
        let anyKey = AnyHashable(key)
        let valueID = makeValueID(keyPath: keyPath, key: anyKey)
        let record = record(for: handle, valueID: valueID, keyPath: keyPath, key: anyKey)
        record.didRead = true
        record.dirty = false
        handle.writeDeliver(value, key: key)
        record.resumeWaiters(with: .inbound)
        if let statusID = record.statusID {
            observation.invalidateValue(at: statusID)
        }
        let strategy = handle.resolveStrategy(in: self)
        handle.callOnWrite(strategy, value: value, key: key)
    }

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
        if let existing = strategyRecords[valueID] {
            existing.addresses.insert(valueID)
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        if let existing = uniqueRecords.first(where: {
            ObjectIdentifier($0.handle) == ObjectIdentifier(handle) && $0.key == key
        }) {
            strategyRecords[valueID] = existing
            existing.addresses.insert(valueID)
            classify(existing, valueID: valueID, keyPath: keyPath, handle: handle)
            return existing
        }
        let created = StrategyRecord(handle: handle, key: key)
        strategyRecords[valueID] = created
        created.addresses.insert(valueID)
        classify(created, valueID: valueID, keyPath: keyPath, handle: handle)
        return created
    }

    private var uniqueRecords: [StrategyRecord] {
        var seen: [ObjectIdentifier: StrategyRecord] = [:]
        for record in strategyRecords.values {
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

    func callOnRead(_ record: StrategyRecord) {
        onRead(record)
    }

    private func onRead(_ record: StrategyRecord) {
        let strategy = record.handle.resolveStrategy(in: self)
        record.handle.callOnRead(strategy, key: record.key)
    }

    func applyStrategyApply<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        _ value: Value,
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.handle.writeDeliver(value)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        notifyStrategy(record)
    }

    func applyStrategyKeyedApply<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        _ value: Value?,
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        let record = recordMatching(keyPath: keyPath, key: AnyHashable(key))
        if let value {
            record?.handle.writeDeliver(value, key: key)
        } else {
            record?.handle.writeKeyedSettled(key: key)
        }
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        notifyStrategy(record)
    }

    func applyStrategyFail<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        _ error: any Error,
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.handle.writeFail(error, key: nil)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        if let statusID = record?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applyStrategyKeyedFail<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        _ error: any Error,
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        let anyKey = AnyHashable(key)
        let record = recordMatching(keyPath: keyPath, key: anyKey)
        record?.handle.writeFail(error, key: anyKey)
        record?.dirty = false
        record?.resumeWaiters(with: .inbound)
        if let statusID = record?.statusID {
            observation.invalidateValue(at: statusID)
        }
    }

    func applyStrategyMarkStale<Storage: StateContainer, S: AsyncStrategy, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, Value, Status>>
    ) {
        let record = recordMatching(keyPath: keyPath, key: nil)
        record?.dirty = true
        if let sourcedID = record?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    func applyStrategyKeyedMarkStale<Storage: StateContainer, S: AsyncStrategy, Key: Hashable, Value, Status>(
        keyPath: KeyPath<Storage, AsyncState<S, [Key: Value], Status>>,
        key: Key
    ) {
        let record = recordMatching(keyPath: keyPath, key: AnyHashable(key))
        record?.dirty = true
        if let sourcedID = record?.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
    }

    private func recordMatching<Storage: StateContainer, Value>(
        keyPath: KeyPath<Storage, Value>,
        key: AnyHashable?
    ) -> StrategyRecord? {
        let id = makeValueID(keyPath: keyPath, key: key)
        if let record = strategyRecords[id] {
            return record
        }
        if let match = uniqueRecords.first(where: { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }) {
            strategyRecords[id] = match
            match.addresses.insert(id)
            match.sourcedID = id
            return match
        }
        _ = read(keyPath)
        if let record = strategyRecords[id] {
            return record
        }
        return uniqueRecords.first { record in
            record.key == key && Self.addressMatches(record.handle, keyPath: keyPath)
        }
    }

    private static func addressMatches(_ handle: any AsyncStateHandle, keyPath: AnyKeyPath) -> Bool {
        handle.sourcedKeyPath == keyPath
            || handle.storageValueKeyPath == keyPath
            || handle.dollarKeyPath == keyPath
            || handle.wrapperKeyPath == keyPath
    }

    private func notifyStrategy(_ record: StrategyRecord?) {
        guard let record else { return }
        if let sourcedID = record.sourcedID {
            observation.invalidateValue(at: sourcedID)
        }
        if let statusID = record.statusID {
            observation.invalidateValue(at: statusID)
        }
        // The sourced Address can be learned after a `$`-first read, so a reader that
        // subscribed through the earlier ValueID must still be notified.
        for address in record.addresses {
            observation.invalidateValue(at: address)
        }
    }

    func dropAllRecords() {
        for record in uniqueRecords {
            endRecord(record)
        }
        strategyRecords.removeAll()
    }

    func dropRecords<Storage: StateContainer>(in type: Storage.Type) {
        var kept: [ValueID: StrategyRecord] = [:]
        var ended: Set<ObjectIdentifier> = []
        for (id, record) in strategyRecords {
            if recordBelongs(record, to: type) {
                let token = ObjectIdentifier(record)
                if ended.insert(token).inserted {
                    endRecord(record)
                }
            } else {
                kept[id] = record
            }
        }
        strategyRecords = kept
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
        let strategy = record.handle.resolveStrategy(in: self)
        record.handle.callOnDrop(strategy, key: record.key)
    }
}
